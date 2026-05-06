#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Custom Transport that runs `claude` inside an E2B sandbox VM.
#
# Demonstrates how to plug a remote execution backend into ClaudeAgentSDK::Client
# by implementing the 6-method Transport interface against E2B's `commands` API.
#
# How it works
# ------------
# The default SubprocessCLITransport spawns the `claude` CLI on the local host
# via Open3.popen3 and pipes JSON-lines over stdin/stdout. This transport does
# the same thing, but the CLI runs inside an E2B Firecracker microVM:
#
#   ClaudeAgentSDK::Client (host)
#       │  JSON-lines (control_request, user, assistant, ...)
#       ▼
#   E2BCliTransport (host)
#       │  send_stdin / commands.run(background:) / CommandHandle#each
#       ▼
#   E2B envd RPC (HTTP/2 to e2b.app)
#       │
#       ▼
#   /usr/local/bin/claude (in-VM subprocess)
#
# The wire protocol is identical — only the I/O layer is different. CommandBuilder
# from the SDK builds the same argv used by SubprocessCLITransport; we shell-escape
# it and hand it to E2B's `/bin/bash -l -c` execution path.
#
# Prerequisites
# -------------
#   gem install e2b
#   E2B_API_KEY=<your-key>
#   ANTHROPIC_API_KEY=<your-key>   # or CLAUDE_CODE_OAUTH_TOKEN
#
# The sandbox template must have `claude` on $PATH. Either use a custom template
# that bakes it in, or `npm install -g @anthropic-ai/claude-code` once at the
# start of the run (slower; the template approach is preferred for production).
#
# Run with: ruby examples/e2b_transport_example.rb
#
# Production hardening (intentionally NOT in this example)
# --------------------------------------------------------
# A production transport would typically add: an inactivity watchdog (kill the
# stream when the in-VM CLI silently exits), a keepalive heartbeat (poke envd
# on a separate connection so CDN/proxy idle-timeouts don't cut the streaming
# RPC), stream reconnect via commands.connect(pid) on transient SSL/EOF errors,
# and structured logging. See heymoney/voyager's e2b_cli_transport.rb for a
# fully battle-tested version (~900 lines). This example stays minimal to keep
# the Transport interface readable.

require 'bundler/setup'
require 'shellwords'
require 'claude_agent_sdk'
require 'e2b'

class E2BCliTransport < ClaudeAgentSDK::Transport
  DEFAULT_MAX_BUFFER_SIZE = 10 * 1024 * 1024 # 10MB — single SDK message
  DEFAULT_CLI_PATH = '/usr/local/bin/claude'
  PROCESS_TIMEOUT = 3600 # 1 hour at the sandbox process layer
  REQUEST_TIMEOUT = 3600 # HTTP timeout for the streaming RPC

  # The SDK's default_env injects the host's HOME/PATH/TMPDIR/SHELL/USER so the
  # local subprocess CLI sees a sane shell. Inside an E2B Firecracker VM those
  # paths don't exist (HOME=/Users/luotao etc.), and the CLI hangs at startup
  # when it tries to mkdir $HOME/.claude. Strip these and let `bash -l` set
  # them from the sandbox image's own profile.
  HOST_ENV_BLOCKLIST = %w[
    HOME PATH TMPDIR SHELL USER LANG TERM LOGNAME OLDPWD
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
  ].freeze

  def initialize(options, sandbox:, cli_path: nil)
    @options = options
    @sandbox = sandbox
    @cli_path = cli_path || DEFAULT_CLI_PATH
    @handle = nil
    @pid = nil
    @ready = false
    @exited = false
    @max_buffer_size = @options.max_buffer_size || DEFAULT_MAX_BUFFER_SIZE
    @recent_stderr = []
    @recent_stderr_mutex = Mutex.new
  end

  # Transport interface ------------------------------------------------------

  def connect
    return if @handle

    @handle = @sandbox.commands.run(
      build_command_string,
      background: true,
      cwd: @options.cwd&.to_s,
      envs: build_env,
      stdin: true, # required for send_stdin / close_stdin
      timeout: PROCESS_TIMEOUT,
      request_timeout: REQUEST_TIMEOUT
    )
    @pid = @handle.pid
    @ready = true
  rescue E2B::E2BError => e
    raise ClaudeAgentSDK::CLIConnectionError,
          "Failed to start claude in E2B sandbox: #{e.message}"
  end

  def write(data)
    raise process_error('Claude CLI exited before stdin write') if @exited
    raise ClaudeAgentSDK::CLIConnectionError, 'transport not ready' unless @ready && @pid

    @sandbox.commands.send_stdin(@pid, data)
  rescue E2B::E2BError => e
    @ready = false
    # `process with pid N not found` typically means the CLI crashed at startup;
    # surface accumulated stderr so the SDK can classify the failure.
    raise process_error("write failed: #{e.message}") if e.message.include?('not found')

    raise ClaudeAgentSDK::CLIConnectionError, "Failed to write to E2B stdin: #{e.message}"
  end

  def read_messages(&block)
    return enum_for(:read_messages) unless block_given?
    raise ClaudeAgentSDK::CLIConnectionError, 'Not connected' unless @handle

    json_buffer = +''
    drain_handle_stream(json_buffer, &block)

    # CommandHandle#each returns when the envd RPC stream closes, including on
    # non-zero exit. The actual exit code comes from #wait, which raises
    # CommandExitError if non-zero. Drain it here so a CLI crash surfaces as a
    # real exception instead of read_messages returning silently.
    @exited = true
    @handle.wait
  rescue E2B::CommandExitError => e
    @exited = true
    @recent_stderr_mutex.synchronize { @recent_stderr << e.stderr if e.stderr && !e.stderr.empty? }
    raise ClaudeAgentSDK::ProcessError.new(
      "Claude CLI exited with code #{e.exit_code}",
      exit_code: e.exit_code,
      stderr: recent_stderr_text
    )
  rescue E2B::E2BError => e
    @exited = true
    raise ClaudeAgentSDK::CLIConnectionError, "E2B stream error: #{e.message}"
  end

  def end_input
    return unless @pid

    @sandbox.commands.close_stdin(@pid)
  rescue E2B::E2BError
    # Process may have already exited; idempotent.
  end

  def close
    @ready = false
    return unless @handle

    begin
      @handle.kill
    rescue E2B::E2BError
      # Process may have already exited; idempotent.
    end
    @handle = nil
    @pid = nil
  end

  def ready?
    @ready
  end

  private

  # Build the argv for `claude` and shell-escape it into a single string.
  #
  # E2B runs commands through `/bin/bash -l -c "<string>"`, so we can't pass
  # an argv array directly the way Open3.popen3(*argv) does locally. Reusing
  # the SDK's CommandBuilder ensures the argv is identical to what
  # SubprocessCLITransport would build — including the SDK MCP `:instance`
  # field stripping (CommandBuilder#append_mcp_servers handles that).
  def build_command_string
    argv = ClaudeAgentSDK::CommandBuilder.new(@cli_path, @options).build
    argv.map { |arg| Shellwords.shellescape(arg.to_s) }.join(' ')
  end

  def build_env
    env = {}
    @options.env&.each do |k, v|
      next if HOST_ENV_BLOCKLIST.include?(k.to_s)
      next if v.nil?

      env[k.to_s] = v.to_s
    end

    env['CLAUDECODE'] = '' # prevent nested-session detection
    env['CLAUDE_AGENT_SDK_VERSION'] = ClaudeAgentSDK::VERSION
    env['CLAUDE_CODE_ENTRYPOINT'] ||= 'sdk-rb'
    env['CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING'] = 'true' if @options.enable_file_checkpointing
    env['PWD'] = @options.cwd.to_s if @options.cwd
    env
  end

  def drain_handle_stream(json_buffer)
    @handle.each do |stdout, stderr, _pty|
      if stderr && !stderr.empty?
        record_stderr(stderr)
        next
      end
      next unless stdout && !stdout.empty?

      stdout.each_line do |raw|
        line = raw.strip
        next if line.empty?

        json_buffer << line
        if json_buffer.bytesize > @max_buffer_size
          size = json_buffer.bytesize
          json_buffer.clear
          raise ClaudeAgentSDK::CLIJSONDecodeError.new(
            'JSON message exceeded maximum buffer size',
            StandardError.new("Buffer size #{size} exceeds limit #{@max_buffer_size}")
          )
        end

        begin
          data = JSON.parse(json_buffer, symbolize_names: true)
          json_buffer.clear
          yield data
        rescue JSON::ParserError
          # Keep buffering — JSON line may have been split across reads.
          next
        end
      end
    end
  end

  def record_stderr(text)
    lines = text.split("\n").map(&:strip).reject(&:empty?)
    return if lines.empty?

    @recent_stderr_mutex.synchronize do
      lines.each do |line|
        @recent_stderr << line
        @recent_stderr.shift if @recent_stderr.size > 20
      end
    end
    lines.each { |line| @options.stderr&.call(line) }
  end

  def recent_stderr_text
    text = @recent_stderr_mutex.synchronize { @recent_stderr.last(10).join("\n") }
    text.empty? ? 'No stderr output captured' : text
  end

  def process_error(msg)
    ClaudeAgentSDK::ProcessError.new(msg, exit_code: 1, stderr: recent_stderr_text)
  end
end

# ---------------------------------------------------------------------------
# Runner: spin up a sandbox, install claude, run a one-shot query through the
# custom transport, and tear everything down.
# ---------------------------------------------------------------------------

if __FILE__ == $PROGRAM_NAME
  abort 'E2B_API_KEY is required' unless ENV['E2B_API_KEY']
  unless ENV['ANTHROPIC_API_KEY'] || ENV['CLAUDE_CODE_OAUTH_TOKEN']
    abort 'ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN is required'
  end

  require 'async'

  E2B.configure { |c| c.api_key = ENV['E2B_API_KEY'] }

  puts 'Creating E2B sandbox...'
  sandbox = E2B::Sandbox.create(template: 'base', timeout: 600)
  puts "Sandbox: #{sandbox.sandbox_id}"

  begin
    # Bake `claude` into a custom template for production. For this example we
    # install it once at startup; npm pulls ~150MB so expect a 30-60s wait.
    puts 'Installing @anthropic-ai/claude-code in sandbox...'
    install = sandbox.commands.run('npm install -g @anthropic-ai/claude-code', timeout: 240)
    abort "npm install failed: #{install.stderr}" unless install.exit_code.zero?

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: 'You are a concise assistant.',
      max_turns: 1,
      cwd: '/home/user',
      env: {
        'ANTHROPIC_API_KEY' => ENV.fetch('ANTHROPIC_API_KEY', nil),
        'CLAUDE_CODE_OAUTH_TOKEN' => ENV.fetch('CLAUDE_CODE_OAUTH_TOKEN', nil)
      }.compact
    )

    Async do
      client = ClaudeAgentSDK::Client.new(
        options: options,
        transport_class: E2BCliTransport,
        transport_args: { sandbox: sandbox }
      )
      client.connect
      client.query('Print a one-line haiku about Ruby and sandboxes.')
      client.receive_response do |msg|
        case msg
        when ClaudeAgentSDK::AssistantMessage
          msg.content.each do |block|
            puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
          end
        when ClaudeAgentSDK::ResultMessage
          puts "Done — #{msg.num_turns} turns, $#{msg.total_cost_usd}"
        end
      end
      client.disconnect
    end.wait
  ensure
    puts 'Killing sandbox...'
    sandbox.kill
  end
end
