# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe ClaudeAgentSDK::SubprocessCLITransport do
  # The active-process registry is class-level mutable state shared across the
  # whole suite. Several #connect specs register a stubbed Process::Waiter and
  # never call #close, so clear it between examples to keep the at_exit handler
  # (and other specs) from observing leaked test doubles.
  after { described_class.active_processes.clear }

  describe '#build_command' do
    it 'passes a string system_prompt via --system-prompt' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: 'You are a helpful assistant'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt', 'You are a helpful assistant')
    end

    it 'passes a preset system_prompt via --append-system-prompt only (no --system-prompt)' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: { type: 'preset', preset: 'claude_code', append: 'Extra instructions' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--system-prompt')
      expect(cmd).to include('--append-system-prompt', 'Extra instructions')
    end

    it 'supports SystemPromptPreset objects' do
      preset = ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', append: 'Extra')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: preset
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--system-prompt')
      expect(cmd).to include('--append-system-prompt', 'Extra')
    end

    it 'passes empty system prompt when nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--system-prompt')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('')
    end

    it 'always uses --input-format stream-json' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--input-format', 'stream-json')
    end

    it 'omits --setting-sources when setting_sources is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--setting-sources')
    end

    it 'emits --setting-sources joined by commas when set' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        setting_sources: %w[user project]
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--setting-sources', 'user,project')
    end

    it 'does not include --agents in CLI args' do
      agent = ClaudeAgentSDK::AgentDefinition.new(
        description: 'Test agent',
        prompt: 'You are helpful'
      )
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        agents: { test: agent }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--agents')
    end

    it 'passes valid extra_args flags as --flag value' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        extra_args: { 'debug-to-stderr' => nil, 'custom-flag' => 'value' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--debug-to-stderr')
      expect(cmd).to include('--custom-flag', 'value')
    end

    it 'rejects extra_args keys that contain spaces or invalid characters' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        extra_args: { 'permission-mode bypassPermissions' => nil }
      )

      transport = described_class.new('hi', options)

      expect { transport.build_command }.to raise_error(ArgumentError, /Invalid extra_args flag name/)
    end

    it 'rejects extra_args keys that are empty or start with --' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        extra_args: { '--permission-mode' => 'bypassPermissions' }
      )

      transport = described_class.new('hi', options)

      expect { transport.build_command }.to raise_error(ArgumentError, /Invalid extra_args flag name/)
    end

    it 'passes --thinking adaptive for ThinkingConfigAdaptive' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('adaptive')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'passes --max-thinking-tokens for ThinkingConfigEnabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 50_000)
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--max-thinking-tokens')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('50000')
      expect(cmd).not_to include('--thinking')
    end

    it 'passes --thinking disabled for ThinkingConfigDisabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigDisabled.new
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('disabled')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'thinking takes precedence over deprecated max_thinking_tokens' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new,
        max_thinking_tokens: 99_999
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('adaptive')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'falls back to max_thinking_tokens when thinking is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        max_thinking_tokens: 20_000
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--max-thinking-tokens')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('20000')
    end

    it 'passes --effort flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'high'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'high')
    end

    it 'passes --effort max' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'max'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'max')
    end

    it 'passes --effort xhigh' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'xhigh'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'xhigh')
    end

    it 'omits --effort when effort is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: nil
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--effort')
    end

    it 'forwards an Integer effort verbatim' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 8000
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', '8000')
    end

    it 'maps tools preset objects to the CLI default tool set' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        tools: ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code')
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--tools')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('default')
    end

    it 'uses plugin directories instead of --plugins JSON' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        plugins: [ClaudeAgentSDK::SdkPluginConfig.new(path: '/tmp/plugin')]
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--plugin-dir', '/tmp/plugin')
      expect(cmd).not_to include('--plugins')
    end

    it 'merges sandbox settings into settings loaded from a file path' do
      Tempfile.create(['claude-settings', '.json']) do |file|
        file.write(JSON.generate({ permissions: { allow: ['Bash(ls:*)'] } }))
        file.flush

        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          cli_path: '/usr/bin/claude',
          settings: file.path,
          sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
        )

        transport = described_class.new('hi', options)
        cmd = transport.build_command

        idx = cmd.index('--settings')
        expect(idx).not_to be_nil

        merged_settings = JSON.parse(cmd[idx + 1])
        expect(merged_settings).to eq(
          'permissions' => { 'allow' => ['Bash(ls:*)'] },
          'sandbox' => { 'enabled' => true }
        )
      end
    end

    it 'raises when settings file path contains invalid JSON and sandbox is enabled' do
      Tempfile.create(['claude-settings', '.json']) do |file|
        file.write('not valid json {{{')
        file.flush

        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          cli_path: '/usr/bin/claude',
          settings: file.path,
          sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
        )

        transport = described_class.new('hi', options)
        expect { transport.build_command }.to raise_error(JSON::ParserError)
      end
    end

    it 'raises when settings file path does not exist and sandbox is enabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        settings: '/nonexistent/path/settings.json',
        sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
      )

      transport = described_class.new('hi', options)
      expect { transport.build_command }.to raise_error(ClaudeAgentSDK::CLIConnectionError, /Settings file not found/)
    end

    it 'passes --system-prompt-file for SystemPromptFile objects' do
      prompt_file = ClaudeAgentSDK::SystemPromptFile.new(path: '/tmp/prompt.txt')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: prompt_file
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt-file', '/tmp/prompt.txt')
      expect(cmd).not_to include('--system-prompt')
    end

    it 'passes --system-prompt-file for Hash with type: file' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: { type: 'file', path: '/tmp/prompt.txt' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt-file', '/tmp/prompt.txt')
    end

    it 'passes --session-id flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        session_id: '550e8400-e29b-41d4-a716-446655440000'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--session-id', '550e8400-e29b-41d4-a716-446655440000')
    end

    it 'passes --task-budget from TaskBudget object' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: ClaudeAgentSDK::TaskBudget.new(total: 50_000)
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '50000')
    end

    it 'passes --task-budget from Hash with symbol keys' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: { total: 30_000 }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '30000')
    end

    it 'passes --task-budget from Hash with string keys' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: { 'total' => 25_000 }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '25000')
    end

    it 'does not add the deprecated enable-file-checkpointing flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        enable_file_checkpointing: true
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--enable-file-checkpointing')
    end
  end

  describe '#check_claude_version' do
    it 'uses Open3.capture3 to avoid shelling out' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')
      transport = described_class.new('hi', options)

      expect(Open3).to receive(:capture3).with('/usr/bin/claude', '-v')
                                         .and_return(["2.1.22 (Claude Code)\n", '', nil])

      transport.send(:check_claude_version)
    end
  end

  describe '#wait_process_with_timeout' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    it 'returns the process value when the process exits within the timeout' do
      process = double('Process::Waiter', pid: 1234)
      allow(process).to receive(:alive?).and_return(true, false)
      allow(process).to receive(:value).and_return(:exited)

      transport.instance_variable_set(:@process, process)

      expect(transport.send(:wait_process_with_timeout, 1)).to eq(:exited)
    end

    it 'raises Timeout::Error when the process stays alive past the deadline' do
      process = double('Process::Waiter', pid: 1234)
      allow(process).to receive(:alive?).and_return(true)

      transport.instance_variable_set(:@process, process)

      expect { transport.send(:wait_process_with_timeout, 0.1) }.to raise_error(Timeout::Error)
    end
  end

  describe 'environment variable handling' do
    it 'converts symbol keys in env to strings for spawn compatibility' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        env: { SYMBOL_KEY: 'value', 'STRING_KEY' => 'value2', 'CLAUDE_CODE_ENTRYPOINT' => 'sdk-rb' }
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO), instance_double(IO), instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['SYMBOL_KEY']).to eq('value')
      expect(captured_env['STRING_KEY']).to eq('value2')
      expect(captured_env.key?(:SYMBOL_KEY)).to be false
      expect(captured_env['CLAUDE_CODE_ENTRYPOINT']).to eq('sdk-rb')
    end

    it 'preserves a caller-provided CLAUDE_CODE_ENTRYPOINT value' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        env: { 'CLAUDE_CODE_ENTRYPOINT' => 'custom-entrypoint' }
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO), instance_double(IO), instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['CLAUDE_CODE_ENTRYPOINT']).to eq('custom-entrypoint')
    end

    it 'enables SDK file checkpointing via environment variable' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        enable_file_checkpointing: true
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO), instance_double(IO), instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING']).to eq('true')
    end

    it 'does not set FGTS env var even when partial messages are requested' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        include_partial_messages: true
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO), instance_double(IO), instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      # FGTS env var was reverted in Python SDK v0.1.48 due to 400 errors on proxies/Bedrock/Vertex
      expect(captured_env).not_to have_key('CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING')
    end
  end

  describe '#read_messages — non-JSON line robustness' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    # Regression: the CLI occasionally writes non-JSON debug text to stdout
    # (e.g. `[SandboxDebug]` prefixes, ANSI escapes). Without the start-with-{
    # guard those lines would be appended into json_buffer, poisoning every
    # subsequent parse until the 1 MB cap raised CLIJSONDecodeError and
    # killed the entire session.
    it 'skips stdout lines that do not start with { when json_buffer is empty' do
      stdout = StringIO.new(
        "[SandboxDebug] starting up\n" \
        "{\"type\":\"system\",\"subtype\":\"init\"}\n" \
        "stray warning line\n" \
        "{\"type\":\"result\",\"subtype\":\"success\"}\n"
      )
      fake_process = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0))
      transport.instance_variable_set(:@stdout, stdout)
      transport.instance_variable_set(:@process, fake_process)

      messages = []
      transport.read_messages { |m| messages << m }

      expect(messages.map { |m| m[:type] }).to eq(%w[system result])
    end
  end

  describe '#write — close-while-writing does not deadlock' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    # Regression for Codex P2: write previously held @stdin_mutex across the
    # blocking IO call. If a full pipe buffer made @stdin.write block, close()
    # could not acquire the same mutex and disconnect would hang.
    # Now mutex only guards reference snapshot, so close() can always proceed.
    it 'lets close() acquire the lock even while a write is blocked on a full pipe' do
      r, w = IO.pipe
      fake_process = instance_double(Process::Waiter)
      allow(fake_process).to receive(:alive?).and_return(true)
      transport.instance_variable_set(:@stdin, w)
      transport.instance_variable_set(:@process, fake_process)
      transport.instance_variable_set(:@ready, true)

      # Block in @stdin.write by filling the pipe and never reading r.
      writer = Thread.new do
        transport.write('x' * 200_000)
      rescue StandardError
        # write() raises CLIConnectionError once the stream is closed; expected.
      end

      # Give writer a moment to start blocking inside @stdin.write.
      sleep 0.05

      # The mutex must NOT be held by the writer at this point — verify by
      # calling write() from this thread; if the mutex were held, this
      # would itself block. Instead, we use Mutex#try_lock semantics via
      # snapshot under timeout: just call close-like teardown.
      stdin_mutex = transport.instance_variable_get(:@stdin_mutex)
      acquired = false
      Thread.new do
        stdin_mutex.synchronize { acquired = true }
      end.join(1)
      expect(acquired).to be true

      # Cleanup
      w.close
      r.close
      writer.join(1)
    end
  end

  describe '#read_messages — process double-wait handling' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    # Regression: if close() reaped the process while read_messages was
    # winding down, @process.value would raise Errno::ECHILD on the second
    # waitpid and the exception leaked out of read_messages.
    it 'tolerates Errno::ECHILD from @process.value (process already waited)' do
      stdout = StringIO.new("{\"type\":\"system\"}\n")
      waiter = instance_double(Process::Waiter)
      allow(waiter).to receive(:value).and_raise(Errno::ECHILD)
      transport.instance_variable_set(:@stdout, stdout)
      transport.instance_variable_set(:@process, waiter)

      expect { transport.read_messages { |m| m } }.not_to raise_error
    end
  end

  describe 'active-process registry (at_exit cleanup)' do
    it 'registers and deregisters a process by identity' do
      waiter = instance_double(Process::Waiter)

      described_class.register_active_process(waiter)
      expect(described_class.active_processes).to include(waiter)

      described_class.deregister_active_process(waiter)
      expect(described_class.active_processes).not_to include(waiter)
    end

    it 'is a no-op when given nil and dedupes repeated registrations' do
      waiter = instance_double(Process::Waiter)

      described_class.register_active_process(nil)
      described_class.register_active_process(waiter)
      described_class.register_active_process(waiter)

      expect(described_class.active_processes.size).to eq(1)
    end

    it 'kill_active_processes SIGTERMs only live processes, then clears the registry' do
      live = instance_double(Process::Waiter, pid: 4242, alive?: true)
      dead = instance_double(Process::Waiter, pid: 4243, alive?: false)
      described_class.register_active_process(live)
      described_class.register_active_process(dead)

      # A single positive expectation also asserts the dead process is skipped:
      # any kill('TERM', 4243) would surface as an unexpected-arguments failure.
      expect(Process).to receive(:kill).with('TERM', 4242)

      described_class.kill_active_processes
      expect(described_class.active_processes).to be_empty
    end

    it 'swallows errors from a dead pid so interpreter shutdown is never interrupted' do
      stale = instance_double(Process::Waiter, pid: 9999, alive?: true)
      described_class.register_active_process(stale)
      allow(Process).to receive(:kill).with('TERM', 9999).and_raise(Errno::ESRCH)

      expect { described_class.kill_active_processes }.not_to raise_error
      expect(described_class.active_processes).to be_empty
    end

    it 'connect registers the spawned process and close deregisters it' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')
      transport = described_class.new('hi', options)

      # Real StringIOs so the stderr-drain thread (#each_line) and #close work
      # without per-method stubs. alive?: false lets #close skip the wait/kill.
      waiter = instance_double(Process::Waiter, alive?: false)
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3).and_return([StringIO.new, StringIO.new, StringIO.new, waiter])

      transport.connect
      expect(described_class.active_processes).to include(waiter)

      transport.close
      expect(described_class.active_processes).not_to include(waiter)
    end
  end
end
