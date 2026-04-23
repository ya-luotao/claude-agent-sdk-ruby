# frozen_string_literal: true

require 'json'
require 'open3'
require 'timeout'
require_relative 'transport'
require_relative 'errors'
require_relative 'version'
require_relative 'command_builder'

module ClaudeAgentSDK
  # Subprocess transport using Claude Code CLI
  class SubprocessCLITransport < Transport
    DEFAULT_MAX_BUFFER_SIZE = 1024 * 1024 # 1MB buffer limit
    MINIMUM_CLAUDE_CODE_VERSION = '2.0.0'

    def initialize(options_or_prompt = nil, options = nil)
      # Support both new single-arg form and legacy two-arg form
      @options = options.nil? ? options_or_prompt : options
      @cli_path = @options.cli_path || find_cli
      @cwd = @options.cwd
      @process = nil
      @stdin = nil
      @stdout = nil
      @stderr = nil
      @ready = false
      @exit_error = nil
      @max_buffer_size = @options.max_buffer_size || DEFAULT_MAX_BUFFER_SIZE
      @stderr_task = nil
      @recent_stderr = []
      @recent_stderr_mutex = Mutex.new
    end

    def find_cli
      # Try which command first (using Open3 for thread safety)
      cli = nil
      begin
        stdout, _status = Open3.capture2('which', 'claude')
        cli = stdout.strip
      rescue StandardError
        # which command failed, try common locations
      end
      return cli if cli && !cli.empty? && File.executable?(cli)

      # Try common locations
      locations = [
        File.join(Dir.home, '.claude/local/claude'),  # Claude Code default install location
        File.join(Dir.home, '.npm-global/bin/claude'),
        '/usr/local/bin/claude',
        File.join(Dir.home, '.local/bin/claude'),
        File.join(Dir.home, 'node_modules/.bin/claude'),
        File.join(Dir.home, '.yarn/bin/claude')
      ]

      locations.each do |path|
        return path if File.exist?(path) && File.file?(path)
      end

      raise CLINotFoundError.new(
        "Claude Code not found. Install with:\n" \
        "  npm install -g @anthropic-ai/claude-code\n" \
        "\nIf already installed locally, try:\n" \
        '  export PATH="$HOME/node_modules/.bin:$PATH"' \
        "\n\nOr provide the path via ClaudeAgentOptions:\n" \
        "  ClaudeAgentOptions.new(cli_path: '/path/to/claude')"
      )
    end

    def build_command
      CommandBuilder.new(@cli_path, @options).build
    end

    def connect
      return if @process

      check_claude_version

      cmd = build_command

      # Build environment
      # Convert symbol keys to strings for spawn compatibility
      custom_env = @options.env.transform_keys { |k| k.to_s }
      # Explicitly unset CLAUDECODE to prevent "nested session" detection when the SDK
      # launches Claude Code from within an existing Claude Code terminal.
      # NOTE: Must set to nil (not just omit the key) — Ruby's spawn only overlays
      # the env hash on top of the parent environment; a nil value actively unsets.
      process_env = ENV.to_h.merge('CLAUDECODE' => nil, 'CLAUDE_AGENT_SDK_VERSION' => VERSION).merge(custom_env)
      process_env['CLAUDE_CODE_ENTRYPOINT'] ||= 'sdk-rb'
      process_env['CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING'] = 'true' if @options.enable_file_checkpointing
      process_env['PWD'] = @cwd.to_s if @cwd

      # Determine stderr handling
      should_pipe_stderr = @options.stderr || @options.debug_stderr || @options.extra_args.key?('debug-to-stderr')

      begin
        # Start process using Open3
        opts = { chdir: @cwd&.to_s }.compact

        @stdin, @stdout, @stderr, @process = Open3.popen3(process_env, *cmd, opts)

        # Always drain stderr to prevent pipe buffer deadlock.
        # Without this, --verbose output fills the OS pipe buffer (~64KB),
        # the subprocess blocks on write, and all pipes stall → EPIPE.
        if @stderr
          if should_pipe_stderr # rubocop:disable Style/ConditionalAssignment
            @stderr_task = Thread.new do
              handle_stderr
            rescue StandardError
              # Ignore errors during stderr reading
            end
          else
            # Silently drain stderr so the subprocess never blocks,
            # but still accumulate recent lines for error reporting.
            @stderr_task = Thread.new do
              drain_stderr_with_accumulation
            rescue StandardError
              # Ignore — process may have already exited
            end
          end
        end

        # Always keep stdin open — streaming mode uses it for the control protocol
        @ready = true
      rescue Errno::ENOENT => e
        # Check if error is from cwd or CLI
        if @cwd && !File.directory?(@cwd.to_s)
          error = CLIConnectionError.new("Working directory does not exist: #{@cwd}")
          @exit_error = error
          raise error
        end
        error = CLINotFoundError.new("Claude Code not found at: #{@cli_path}")
        @exit_error = error
        raise error
      rescue StandardError => e
        error = CLIConnectionError.new("Failed to start Claude Code: #{e}")
        @exit_error = error
        raise error
      end
    end

    def handle_stderr
      return unless @stderr

      @stderr.each_line do |line|
        line_str = line.chomp
        next if line_str.empty?

        # Accumulate recent lines for inclusion in ProcessError
        @recent_stderr_mutex.synchronize do
          @recent_stderr << line_str
          @recent_stderr.shift if @recent_stderr.size > 20
        end

        # Call stderr callback if provided
        @options.stderr&.call(line_str)

        # Write to debug_stderr file/IO if provided
        if @options.debug_stderr
          if @options.debug_stderr.respond_to?(:puts)
            @options.debug_stderr.puts(line_str)
          elsif @options.debug_stderr.is_a?(String)
            File.open(@options.debug_stderr, 'a') { |f| f.puts(line_str) }
          end
        end
      end
    rescue StandardError
      # Ignore errors during stderr reading
    end

    def drain_stderr_with_accumulation
      return unless @stderr

      @stderr.each_line do |line|
        line_str = line.chomp
        next if line_str.empty?

        @recent_stderr_mutex.synchronize do
          @recent_stderr << line_str
          @recent_stderr.shift if @recent_stderr.size > 20
        end
      end
    end

    def close
      @ready = false
      return unless @process

      cleanup_errors = []

      # Kill stderr thread
      if @stderr_task&.alive?
        begin
          @stderr_task.kill
          @stderr_task.join(1)
        rescue StandardError => e
          cleanup_errors << "stderr thread: #{e.message}"
        end
      end

      # Close streams
      begin
        @stdin&.close
      rescue IOError
        # Already closed, ignore
      rescue StandardError => e
        cleanup_errors << "stdin: #{e.message}"
      end

      begin
        @stdout&.close
      rescue IOError
        # Already closed, ignore
      rescue StandardError => e
        cleanup_errors << "stdout: #{e.message}"
      end

      begin
        @stderr&.close
      rescue IOError
        # Already closed, ignore
      rescue StandardError => e
        cleanup_errors << "stderr: #{e.message}"
      end

      # Wait for graceful shutdown after stdin EOF, then terminate if needed.
      # The subprocess needs time to flush its session file after receiving
      # EOF on stdin. Without this grace period, SIGTERM can interrupt the
      # write and cause the last assistant message to be lost.
      begin
        wait_process_with_timeout(5) if @process.alive?
      rescue Timeout::Error
        # Graceful shutdown timed out — send SIGTERM
        begin
          Process.kill('TERM', @process.pid)
          wait_process_with_timeout(2)
        rescue Timeout::Error
          # SIGTERM didn't work — force kill
          begin
            Process.kill('KILL', @process.pid)
            @process.value
          rescue StandardError => e
            cleanup_errors << "force kill: #{e.message}"
          end
        rescue Errno::ESRCH
          # Process already dead
        end
      rescue Errno::ESRCH
        # Process already dead, ignore
      rescue StandardError => e
        cleanup_errors << "process termination: #{e.message}"
      end

      # Log any cleanup errors (non-fatal)
      if cleanup_errors.any?
        warn "Claude SDK: Cleanup warnings: #{cleanup_errors.join(', ')}"
      end

      @process = nil
      @stdout = nil
      @stdin = nil
      @stderr = nil
      @stderr_task = nil
      @exit_error = nil
    end

    # Wait for the spawned process to exit, up to +timeout_seconds+. Polls
    # @process.alive? rather than using stdlib Timeout.timeout, which raises
    # across threads via Thread#raise and corrupts Async fiber-scheduler state
    # (close is always called inside an Async task). Yields to the current
    # Async task when one is active so the reactor keeps running.
    def wait_process_with_timeout(timeout_seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      task = defined?(Async::Task) ? Async::Task.current? : nil
      while @process.alive?
        raise Timeout::Error if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        task ? task.sleep(0.05) : sleep(0.05)
      end
      @process.value
    end

    def write(data)
      raise CLIConnectionError, 'ProcessTransport is not ready for writing' unless @ready && @stdin
      raise CLIConnectionError, "Cannot write to terminated process" if @process && !@process.alive?

      raise CLIConnectionError, "Cannot write to process that exited with error: #{@exit_error}" if @exit_error

      begin
        @stdin.write(data)
        @stdin.flush
      rescue StandardError => e
        @ready = false
        @exit_error = CLIConnectionError.new("Failed to write to process stdin: #{e}")
        raise @exit_error
      end
    end

    def end_input
      return unless @stdin

      begin
        @stdin.close
      rescue StandardError
        # Ignore
      end
      @stdin = nil
    end

    def read_messages(&block)
      return enum_for(:read_messages) unless block_given?

      raise CLIConnectionError, 'Not connected' unless @process && @stdout

      json_buffer = ''

      begin
        @stdout.each_line do |line|
          line_str = line.strip
          next if line_str.empty?

          json_lines = line_str.split("\n")

          json_lines.each do |json_line|
            json_line = json_line.strip
            next if json_line.empty?

            json_buffer += json_line

            if json_buffer.bytesize > @max_buffer_size
              buffer_length = json_buffer.bytesize
              json_buffer = ''
              raise CLIJSONDecodeError.new(
                "JSON message exceeded maximum buffer size",
                StandardError.new("Buffer size #{buffer_length} exceeds limit #{@max_buffer_size}")
              )
            end

            begin
              data = JSON.parse(json_buffer, symbolize_names: true)
              json_buffer = ''
              yield data
            rescue JSON::ParserError
              # Continue accumulating
              next
            end
          end
        end
      rescue IOError
        # Stream closed
      rescue StopIteration
        # Client disconnected
      end

      # Check process completion
      status = @process.value
      returncode = status.exitstatus

      if returncode && returncode != 0
        # Wait briefly for stderr thread to finish draining
        @stderr_task&.join(1)

        stderr_text = @recent_stderr_mutex.synchronize { @recent_stderr.last(10).join("\n") }
        stderr_text = 'No stderr output captured' if stderr_text.empty?

        @exit_error = ProcessError.new(
          "Command failed with exit code #{returncode}",
          exit_code: returncode,
          stderr: stderr_text
        )
        raise @exit_error
      end
    end

    def check_claude_version
      begin
        stdout, stderr, = Open3.capture3(@cli_path.to_s, '-v')
        output = (stdout.to_s + stderr.to_s).strip
        if match = output.match(/([0-9]+\.[0-9]+\.[0-9]+)/)
          version = match[1]
          version_parts = version.split('.').map(&:to_i)
          min_parts = MINIMUM_CLAUDE_CODE_VERSION.split('.').map(&:to_i)

          if version_parts < min_parts
            warning = "Warning: Claude Code version #{version} is unsupported in the Agent SDK. " \
                      "Minimum required version is #{MINIMUM_CLAUDE_CODE_VERSION}. " \
                      "Some features may not work correctly."
            warn warning
          end
        end
      rescue StandardError
        # Ignore version check errors
      end
    end

    def ready?
      @ready
    end
  end
end
