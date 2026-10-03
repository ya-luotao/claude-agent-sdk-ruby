# frozen_string_literal: true

require 'json'

# A stand-in for the `claude` executable: a real child process that speaks
# the CLI's stream-JSON protocol on stdin/stdout. With it the SDK's transport
# is tested through its real #connect — Open3.popen3, the environment handed
# to the child, chdir, the stderr thread, the stdin close and the TERM/KILL
# ladder are all the real thing, and nothing is stubbed.
#
#   cli = FakeClaude.install(dir)        # writes an executable, returns its ABSOLUTE path
#   options = ClaudeAgentSDK::ClaudeAgentOptions.new(
#     cli_path: cli, cwd: dir, env: FakeClaude.env(log: File.join(dir, 'log.jsonl'), scenario: 'slow_exit')
#   )
#   ...
#   FakeClaude.events(File.join(dir, 'log.jsonl'))   # what the child saw and did, in order
#
# This file is two things. Required by spec_helper it only defines the module;
# run as a program (which is what the installed executable does) it is the
# child. The child is plain Ruby started with --disable-gems and loads
# nothing but json, so it starts in milliseconds.
#
# Scenarios (FAKE_CLAUDE_SCENARIO, see .env):
#   conversation      (default) answers control requests and user messages; exits 0 at stdin EOF
#   slow_exit         the same, but after EOF it takes a moment to finish its work before exiting 0
#   wedged            ignores stdin EOF and SIGTERM; only SIGKILL ends it
#   stderr_then_fail  writes FAKE_CLAUDE_STDERR_LINES lines to stderr, waits for EOF, exits 1
#   exit_at_once      exits 0 without reading anything
#
# For the control channel alone, in process, see ScriptedCLI.
module FakeClaude
  # What `-v` prints: a version the SDK accepts without a warning.
  CLI_VERSION = '2.1.286'

  SCENARIOS = %w[conversation slow_exit wedged stderr_then_fail exit_at_once].freeze

  # Writes an executable named `claude` into +dir+ and returns its absolute
  # path, for `cli_path:`. A shell wrapper rather than a shebang line, for two
  # reasons: the interpreter path can be long or contain spaces, and
  # `bundle exec` leaves RUBYOPT=-rbundler/setup in the environment, which
  # would make every start of the child load Bundler.
  def self.install(dir)
    require 'rbconfig'
    require 'shellwords'

    path = File.join(File.realpath(dir), 'claude')
    File.write(path, <<~SH)
      #!/bin/sh
      unset RUBYOPT RUBYLIB
      exec #{Shellwords.escape(RbConfig.ruby)} --disable-gems #{Shellwords.escape(File.expand_path(__FILE__))} "$@"
    SH
    File.chmod(0o755, path)
    path
  end

  # The entries for ClaudeAgentOptions#env that select what the child does.
  # +log+ is a file the child appends one JSON event per line to; +report_env+
  # names environment variables whose values the child records at start
  # (names of all variables are recorded anyway, values of none).
  def self.env(scenario: 'conversation', log: nil, report_env: [], **settings)
    raise ArgumentError, "unknown scenario #{scenario.inspect}" unless SCENARIOS.include?(scenario.to_s)

    env = { 'FAKE_CLAUDE_SCENARIO' => scenario.to_s }
    env['FAKE_CLAUDE_LOG'] = log.to_s if log
    env['FAKE_CLAUDE_REPORT_ENV'] = report_env.join(',') unless report_env.empty?
    settings.each { |name, value| env["FAKE_CLAUDE_#{name.to_s.upcase}"] = value.to_s }
    env
  end

  # The child's log, parsed: [{ 'event' => 'start', ... }, ...]. Complete
  # once the child has exited, which is when specs read it.
  def self.events(log)
    return [] unless File.exist?(log)

    File.readlines(log, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
  end

  # The pids of the children that logged a start to +log+ and may still be
  # running: what a spec kills when its own bound expires.
  def self.pids(log)
    events(log).filter_map { |event| event['pid'] if event['event'] == 'start' }
  end

  # The child process.
  class Child
    SESSION_ID = '11111111-1111-4111-8111-111111111111'
    MODEL = 'claude-haiku-4-5-20251001'

    def initialize(argv, env)
      @argv = argv
      @env = env
      @scenario = env.fetch('FAKE_CLAUDE_SCENARIO', 'conversation')
      @log = env['FAKE_CLAUDE_LOG'] && File.open(env['FAKE_CLAUDE_LOG'], File::WRONLY | File::APPEND | File::CREAT)
      @backlog = []
      @hooks = {}
      @ids = 0
    end

    def run
      if @argv.include?('-v') || @argv.include?('--version')
        puts "#{CLI_VERSION} (Claude Code)"
        return 0
      end

      $stdout.sync = true
      $stderr.sync = true
      log('start', pid: Process.pid, argv: @argv, cwd: Dir.pwd, env_names: @env.keys.sort, env: reported_env)
      status = play
      log('exit', status: status)
      status
    end

    private

    def play
      case @scenario
      when 'exit_at_once' then 0
      when 'slow_exit' then slow_exit
      when 'wedged' then wedged
      when 'stderr_then_fail' then stderr_then_fail
      else
        converse
        0
      end
    end

    # After stdin EOF the real CLI still has work to do (it flushes the
    # session file) before it exits on its own. A SIGTERM that arrives during
    # that work is recorded, and ends the process the way an interrupted CLI
    # ends.
    def slow_exit
      trap('TERM') do
        log('signal', name: 'TERM')
        exit!(143)
      end
      converse
      sleep Float(@env.fetch('FAKE_CLAUDE_FLUSH_SECONDS', '0.2'))
      log('flushed')
      0
    end

    def wedged
      trap('TERM') { log('signal', name: 'TERM') }
      converse
      sleep
    end

    def stderr_then_fail
      Integer(@env.fetch('FAKE_CLAUDE_STDERR_LINES', '25')).times { |i| warn "fake claude: stderr line #{i + 1}" }
      converse
      1
    end

    # The protocol loop: answers every control request, plays one turn per
    # user message, returns at stdin EOF.
    def converse
      while (frame = next_frame)
        case frame['type']
        when 'control_request' then answer_control_request(frame)
        when 'user' then play_turn
        end
      end
      log('eof')
    end

    def answer_control_request(frame)
      return emit_control_response(frame, {}) unless frame.dig('request', 'subtype') == 'initialize'

      @hooks = frame.dig('request', 'hooks') || {}
      # In the order CLI 2.1.286 does it: each SDK MCP server is initialized
      # before the SDK's own `initialize` is answered, and asked for its
      # tools after.
      sdk_servers.each { |name| ask_sdk_server(name, method: 'initialize', params: mcp_client_info, id: 0) }
      emit_control_response(frame, initialize_response)
      sdk_servers.each do |name|
        ask_sdk_server(name, method: 'notifications/initialized')
        ask_sdk_server(name, method: 'tools/list', id: 1)
      end
    end

    # One turn: the frames CLI 2.1.286 emits for a prompt answered with text,
    # plus a PreToolUse hook callback per registered hook and, when
    # FAKE_CLAUDE_TOOL_CALL names one, an SDK MCP tool call.
    def play_turn
      emit_session_state('running')
      emit(init_frame)
      Array(@hooks['PreToolUse']).flat_map { |matcher| matcher['hookCallbackIds'] }.each do |callback_id|
        ask(subtype: 'hook_callback', callback_id: callback_id, tool_use_id: 'toolu_01FakeClaudeBash',
            input: pre_tool_use_input)
      end
      if (call = @env['FAKE_CLAUDE_TOOL_CALL'])
        call = JSON.parse(call)
        ask_sdk_server(call.fetch('server'), method: 'tools/call', id: 2,
                                             params: { name: call.fetch('name'), arguments: call.fetch('arguments') })
      end
      text = @env.fetch('FAKE_CLAUDE_REPLY', 'OK')
      emit(assistant_frame(text))
      emit(result_frame(text))
      emit_session_state('idle')
    end

    # Sends a control request and waits for its response. Frames that arrive
    # in between (the user prompt is written right after `initialize`) are
    # kept, in order, for #next_frame.
    def ask(request)
      id = next_id
      emit(type: 'control_request', request_id: id, request: request)
      loop do
        frame = read_frame
        unless frame
          log('eof')
          exit!(0)
        end
        return frame if frame['type'] == 'control_response' && frame.dig('response', 'request_id') == id

        @backlog << frame
      end
    end

    def ask_sdk_server(name, message)
      ask(subtype: 'mcp_message', server_name: name, message: message.merge(jsonrpc: '2.0'))
    end

    def next_frame
      @backlog.empty? ? read_frame : @backlog.shift
    end

    def read_frame
      line = $stdin.gets or return nil
      frame = JSON.parse(line)
      log('stdin', frame: frame)
      frame
    end

    def emit(frame)
      $stdout.write("#{JSON.generate(frame)}\n")
    end

    def emit_control_response(request_frame, payload)
      emit(type: 'control_response',
           response: { subtype: 'success', request_id: request_frame['request_id'], response: payload })
    end

    # Only for an SDK that asked for them, as the real CLI does.
    def emit_session_state(state)
      return unless @env['CLAUDE_CODE_SDK_READS_SESSION_STATE'] == '1'

      emit(type: 'system', subtype: 'session_state_changed', state: state, sdk_host_only: true, uuid: next_id,
           session_id: SESSION_ID)
    end

    # One line per event, written with a single syswrite: complete on disk
    # the moment it returns, and safe inside a signal handler.
    def log(event, details = {})
      @log&.syswrite("#{JSON.generate({ event: event }.merge(details))}\n")
    end

    def reported_env
      names = %w[CLAUDE_AGENT_SDK_VERSION CLAUDE_CODE_SDK_READS_SESSION_STATE PWD] +
              @env.fetch('FAKE_CLAUDE_REPORT_ENV', '').split(',')
      names.to_h { |name| [name, @env[name]] }
    end

    def next_id
      @ids += 1
      format('00000000-0000-4000-8000-%012d', @ids)
    end

    # The names of the `type: sdk` servers in --mcp-config.
    def sdk_servers
      index = @argv.index('--mcp-config') or return []
      servers = JSON.parse(@argv[index + 1]).fetch('mcpServers', {})
      servers.select { |_, config| config['type'] == 'sdk' }.keys
    rescue JSON::ParserError
      []
    end

    def mcp_client_info
      { protocolVersion: '2025-11-25', capabilities: {},
        clientInfo: { name: 'claude-code', title: 'Claude Code', description: "Anthropic's agentic coding tool",
                      websiteUrl: 'https://claude.com/claude-code', version: CLI_VERSION } }
    end

    def initialize_response
      { commands: [{ name: 'design', description: 'Grant or revoke Claude agent access to your Design projects',
                     argumentHint: 'consent | revoke', builtin: true }],
        agents: [{ name: 'claude', description: "Catch-all for any task that doesn't fit a more specific agent." }],
        output_style: 'default', available_output_styles: %w[default Proactive Concise Explanatory Learning],
        models: [{ value: 'default', resolvedModel: 'claude-opus-5-5', displayName: 'Default (recommended)',
                   description: 'Use the default model', supportsEffort: true,
                   supportedEffortLevels: %w[low medium high xhigh max], supportsAdaptiveThinking: true,
                   supportsFastMode: true, supportsAutoMode: true }],
        account: { tokenSource: 'none', apiProvider: 'firstParty' }, pid: Process.pid,
        current_permission_mode: 'auto', session_state: 'idle' }
    end

    def pre_tool_use_input
      { session_id: SESSION_ID, transcript_path: File.join(Dir.pwd, "#{SESSION_ID}.jsonl"), cwd: Dir.pwd,
        scratchpad_dir: File.join(Dir.pwd, 'scratchpad'), prompt_id: next_id, permission_mode: 'default',
        hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'ls', description: 'List files' },
        tool_use_id: 'toolu_01FakeClaudeBash' }
    end

    def init_frame
      { type: 'system', subtype: 'init', cwd: Dir.pwd, session_id: SESSION_ID, tools: %w[Bash Read],
        mcp_servers: sdk_servers.map { |name| { name: name, status: 'connected' } }, model: MODEL,
        permissionMode: 'default', slash_commands: %w[compact context], apiKeySource: 'none',
        claude_code_version: CLI_VERSION, output_style: 'default', agents: %w[claude general-purpose], skills: [],
        plugins: [], capabilities: %w[interrupt_receipt_v1 msg_lifecycle_v1], uuid: next_id, fast_mode_state: 'off' }
    end

    def assistant_frame(text)
      { type: 'assistant',
        message: { model: MODEL, id: 'msg_01FakeClaude', type: 'message', role: 'assistant',
                   content: [{ type: 'text', text: text }], stop_reason: nil, stop_sequence: nil,
                   usage: { input_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0,
                            output_tokens: 4, service_tier: 'standard' } },
        parent_tool_use_id: nil, session_id: SESSION_ID, uuid: next_id }
    end

    def result_frame(text)
      { type: 'result', subtype: 'success', is_error: false, duration_ms: 1973, duration_api_ms: 1937, num_turns: 1,
        result: text, stop_reason: 'end_turn', session_id: SESSION_ID, total_cost_usd: 0.01533,
        usage: { input_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 38,
                 service_tier: 'standard' },
        modelUsage: { MODEL => { inputTokens: 10, outputTokens: 38, cacheReadInputTokens: 0,
                                 cacheCreationInputTokens: 0, costUSD: 0.01533, contextWindow: 200_000 } },
        permission_denials: [], terminal_reason: 'completed', uuid: next_id }
    end
  end
end

exit(FakeClaude::Child.new(ARGV, ENV.to_h).run) if $PROGRAM_NAME == __FILE__
