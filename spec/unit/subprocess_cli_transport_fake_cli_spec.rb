# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# SubprocessCLITransport against a real child process (FakeClaude,
# spec/support/fake_claude.rb): what #connect hands the child, what it raises
# when the spawn fails, and how #close and the read loop treat a child that
# finishes, lingers or fails. The other transport specs enter #connect with
# Open3.popen3 stubbed, or plant a process in @process; here nothing is
# stubbed, and what the child saw is read from the child's own log.
RSpec.describe ClaudeAgentSDK::SubprocessCLITransport do
  around do |example|
    Dir.mktmpdir('fake-claude') do |dir|
      @dir = File.realpath(dir)
      @cli = FakeClaude.install(@dir)
      @log = File.join(@dir, 'fake-claude.jsonl')
      example.run
    end
  end

  def transport_for(scenario: 'conversation', cli_path: @cli, cwd: @dir, env: {}, **options)
    described_class.new(
      ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: cli_path, cwd: cwd, env: FakeClaude.env(scenario: scenario, log: @log).merge(env), **options
      )
    )
  end

  # Runs the block on a thread of its own and fails the example if it is
  # still running after +seconds+. The regressions these examples guard
  # against leave the SDK waiting for a child forever, and that has to be a
  # failure here, not a suite that never ends. Generous on purpose: nothing
  # healthy comes near it.
  def bounded(seconds = 60)
    worker = Thread.new do
      Thread.current.report_on_exception = false # the error is re-raised below, by #value
      yield
    end
    return worker.value if worker.join(seconds)

    # The child is what the SDK is stuck on: take it away, then report.
    FakeClaude.pids(@log).each { |pid| kill_fake_claude(pid) }
    worker.kill unless worker.join(10)
    raise "still running after #{seconds}s (the fake CLI was killed to end the example)"
  end

  # KILLs +pid+ only while it still is the fake CLI: a pid outlives its
  # process as a number that the system hands out again.
  def kill_fake_claude(pid)
    command, = Open3.capture2('ps', '-o', 'command=', '-p', pid.to_s)
    Process.kill('KILL', pid) if command.include?('fake_claude.rb')
  rescue Errno::ESRCH
    nil
  end

  # The first exchange of every session, and proof that the child is up and
  # reading: the `initialize` request the SDK sends, and the child's answer.
  def handshake(transport)
    request = { type: 'control_request', request_id: 'req_1_0a1b2c3d',
                request: { subtype: 'initialize', hooks: nil, agents: nil } }
    transport.write("#{JSON.generate(request)}\n")
    answer = transport.read_messages { |frame| break frame }
    expect(answer).to include(type: 'control_response')
    expect(answer.dig(:response, :request_id)).to eq('req_1_0a1b2c3d')
  end

  def events
    FakeClaude.events(@log)
  end

  describe '#connect' do
    it 'starts the child in cwd with the inherited environment, except CLAUDECODE' do
      previous = %w[CLAUDECODE FAKE_CLAUDE_INHERITED].to_h { |name| [name, ENV.fetch(name, nil)] }
      ENV['CLAUDECODE'] = '1' # what a shell inside Claude Code has; the CLI refuses to nest under it
      ENV['FAKE_CLAUDE_INHERITED'] = 'yes'
      transport = transport_for(env: { 'FAKE_CLAUDE_FROM_OPTIONS' => 'yes' })

      bounded do
        transport.connect
        handshake(transport)
        transport.close
      end

      start = events.first
      expect(start).to include('event' => 'start', 'cwd' => @dir)
      # Inherited and option-supplied variables both arrive, so the missing
      # one below was removed, not lost with everything else.
      expect(start.fetch('env_names')).to include('FAKE_CLAUDE_INHERITED', 'FAKE_CLAUDE_FROM_OPTIONS')
      expect(start.fetch('env_names')).not_to include('CLAUDECODE')
      expect(start.dig('env', 'CLAUDE_AGENT_SDK_VERSION')).to eq(ClaudeAgentSDK::VERSION)
      expect(start.dig('env', 'PWD')).to eq(@dir)
    ensure
      transport&.close
      previous&.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    end

    it 'raises CLINotFoundError when the executable does not exist' do
      missing = File.join(@dir, 'no-such-claude')
      transport = transport_for(cli_path: missing)

      expect { bounded { transport.connect } }
        .to raise_error(ClaudeAgentSDK::CLINotFoundError, /#{Regexp.escape(missing)}/)
      expect(transport).not_to be_ready
    ensure
      transport&.close
    end

    it 'raises a CLIConnectionError naming the directory when cwd does not exist' do
      gone = File.join(@dir, 'gone')
      transport = transport_for(cwd: gone)

      expect { bounded { transport.connect } }.to raise_error(ClaudeAgentSDK::CLIConnectionError) do |error|
        # The executable is there: this must not be reported as a missing CLI.
        expect(error).not_to be_a(ClaudeAgentSDK::CLINotFoundError)
        expect(error.message).to include(gone)
      end
      expect(events).to be_empty # the child was never started
    ensure
      transport&.close
    end
  end

  describe '#close' do
    # The grace period after stdin EOF exists for this child: the CLI flushes
    # its session file before it exits, and a SIGTERM in that window loses
    # the last message. A child that ignores TERM cannot tell a grace period
    # from none; one that needs a moment can.
    it 'lets a child that needs a moment after stdin EOF finish on its own, unsignalled' do
      transport = transport_for(scenario: 'slow_exit')

      bounded do
        transport.connect
        handshake(transport)
        transport.close
      end

      expect(events.map { |event| event['event'] }).to eq(%w[start stdin eof flushed exit])
      expect(events.last).to include('status' => 0)
    ensure
      transport&.close
    end

    it 'kills a child that ignores stdin EOF and SIGTERM' do
      transport = transport_for(scenario: 'wedged')

      # Real time: the ladder waits 5s for the exit and 2s after TERM before
      # KILL. If the escalation regresses, #close waits for a child that
      # never dies and the bound ends the example.
      bounded do
        transport.connect
        handshake(transport)
        transport.close
      end

      # It saw EOF, was asked with TERM, and never logged an exit of its own...
      expect(events.map { |event| event['event'] }).to eq(%w[start stdin eof signal])
      expect(events.last).to include('name' => 'TERM')
      # ...and it is gone, reaped, all the same.
      expect { Process.kill(0, events.first.fetch('pid')) }.to raise_error(Errno::ESRCH)
    ensure
      transport&.close
    end
  end

  describe '#read_messages and #write around a child that has exited' do
    it 'keeps the last 20 stderr lines and puts the last 10 in the ProcessError of a failed child' do
      lines = Thread::Queue.new
      transport = transport_for(scenario: 'stderr_then_fail', env: { 'FAKE_CLAUDE_STDERR_LINES' => '25' },
                                stderr: ->(line) { lines << line })
      written = Array.new(25) { |i| "fake claude: stderr line #{i + 1}" }

      error = bounded do
        transport.connect
        # All 25 have gone through the stderr thread before the child is
        # allowed to exit, so what the error carries below is not a race
        # with that thread.
        expect(Array.new(25) { lines.pop(timeout: 30) }).to eq(written)
        transport.end_input
        begin
          transport.read_messages { |_frame| nil }
          nil
        rescue ClaudeAgentSDK::ProcessError => e
          e
        end
      end

      expect(error).to be_a(ClaudeAgentSDK::ProcessError)
      expect(error.exit_code).to eq(1)
      expect(error.stderr).to eq(written.last(10).join("\n"))
      expect(transport.instance_variable_get(:@recent_stderr)).to eq(written.last(20))
    ensure
      transport&.close
    end

    it 'refuses to write to a child that has exited' do
      transport = transport_for(scenario: 'exit_at_once')

      bounded do
        transport.connect
        transport.read_messages { |_frame| nil } # returns at stdout EOF, once the child is reaped
        expect { transport.write("{}\n") }
          .to raise_error(ClaudeAgentSDK::CLIConnectionError, 'Cannot write to terminated process')
      end
    ensure
      transport&.close
    end
  end

  # The whole stack on the fake: ClaudeAgentSDK.query spawns it, probes its
  # version, initializes, serves the SDK MCP handshake, a hook and a tool
  # call, and closes stdin once the child reports idle.
  describe 'a query() run end to end' do
    it 'serves hooks and an SDK MCP server over the control channel, then lets the child exit on its own' do
      hook_inputs = []
      hook = lambda do |input, _tool_use_id, _context|
        hook_inputs << input
        {}
      end
      tool_calls = []
      add = ClaudeAgentSDK.create_tool('add', 'Add two numbers', { a: :number, b: :number }) do |args|
        tool_calls << args
        (args[:a] + args[:b]).to_s
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: @cli, cwd: @dir,
        env: FakeClaude.env(log: @log, tool_call: JSON.generate(server: 'calc', name: 'add', arguments: { a: 2, b: 3 })),
        hooks: { 'PreToolUse' => [ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [hook])] },
        mcp_servers: { 'calc' => ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: [add]) }
      )

      messages = []
      bounded { ClaudeAgentSDK.query(prompt: 'hi', options: options) { |message| messages << message } }

      # What the caller sees.
      expect(messages.map(&:class)).to eq([ClaudeAgentSDK::InitMessage, ClaudeAgentSDK::AssistantMessage,
                                           ClaudeAgentSDK::ResultMessage])
      expect(messages.last.result).to eq('OK')
      expect(hook_inputs.map(&:class)).to eq([ClaudeAgentSDK::PreToolUseHookInput])
      expect(hook_inputs.first.tool_input).to eq(command: 'ls', description: 'List files')
      expect(tool_calls).to eq([{ a: 2, b: 3 }])

      # What the child received on its stdin.
      received = events.select { |event| event['event'] == 'stdin' }.map { |event| event.fetch('frame') }
      expect(received.first.dig('request', 'subtype')).to eq('initialize')
      expect(received.first.dig('request', 'hooks', 'PreToolUse')).to eq(
        [{ 'matcher' => 'Bash', 'hookCallbackIds' => ['hook_0'] }]
      )
      expect(received.find { |frame| frame['type'] == 'user' }.dig('message', 'content')).to eq('hi')
      mcp_results = received.filter_map { |frame| frame.dig('response', 'response', 'mcp_response', 'result') }
      expect(mcp_results[0]).to include('protocolVersion' => '2024-11-05', 'capabilities' => { 'tools' => {} })
      expect(mcp_results[2].fetch('tools').map { |tool| tool['name'] }).to eq(['add'])
      expect(mcp_results[3].fetch('content')).to eq([{ 'type' => 'text', 'text' => '5' }])

      # stdin was closed once the child reported idle, and it exited by
      # itself: an EOF, then a clean exit, no signal.
      expect(events.last(2).map { |event| event['event'] }).to eq(%w[eof exit])
      expect(events.last).to include('status' => 0)
    end
  end
end
