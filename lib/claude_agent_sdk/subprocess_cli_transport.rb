# frozen_string_literal: true

require 'json'
require 'open3'
require 'set'
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
    SKIP_VERSION_CHECK_ENV_VAR = 'CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'
    VERSION_CHECK_TIMEOUT_SECONDS = 2 # mirrors Python's anyio.fail_after(2)
    RECENT_STDERR_LINES_LIMIT = 20

    # Track live CLI subprocesses so we can terminate them when the parent Ruby
    # process exits. Mirrors the Python (PR #916, a `set[Process]`) and
    # TypeScript SDKs' parent-exit cleanup, preventing orphaned `claude`
    # processes from leaking when callers crash or exit before reaching #close.
    # A Set keyed by object identity (like Python's set) keeps the hot path
    # off `#pid` — only #kill_active_processes touches `#pid`/`#alive?`, at exit.
    # Guarded by a mutex because #close can run on a FiberBoundary worker thread
    # while #connect runs on the reactor fiber.
    # Stored in CONSTANTS (not class instance variables) so the registry is a
    # single shared instance across this class and any subclass: constants
    # resolve through the ancestor chain, whereas class ivars are NOT inherited
    # — a `SubprocessCLITransport` subclass instance calling
    # `self.class.register_active_process` would otherwise reach a nil mutex and
    # raise mid-#connect, orphaning the just-spawned child. The base-class
    # at_exit handler must be able to see every subprocess, a subclass's too.
    ACTIVE_PROCESSES = Set.new
    ACTIVE_PROCESSES_MUTEX = Mutex.new

    class << self
      # Public readers (the test suite uses `described_class.active_processes`);
      # they return the shared constants so subclasses observe the same objects.
      def active_processes
        ACTIVE_PROCESSES
      end

      def active_processes_mutex
        ACTIVE_PROCESSES_MUTEX
      end

      # +wait_thr+ is the Process::Waiter returned by Open3.popen3.
      def register_active_process(wait_thr)
        return unless wait_thr

        active_processes_mutex.synchronize { active_processes.add(wait_thr) }
      end

      def deregister_active_process(wait_thr)
        return unless wait_thr

        active_processes_mutex.synchronize { active_processes.delete(wait_thr) }
      end

      # Best-effort SIGTERM to every still-running child. Registered with
      # at_exit at the bottom of this file. Never reaps (a blocking wait could
      # hang interpreter shutdown) — the OS reparents and reaps orphans.
      #
      # Deliberately does NOT take active_processes_mutex: at interpreter
      # shutdown Ruby runs at_exit handlers *before* terminating other threads,
      # and Mutex is unfair, so blocking here while a still-live worker churns
      # register/deregister can starve this handler and hang the process. A
      # lock-free read is safe — a torn snapshot at worst misses or repeats a
      # SIGTERM, both harmless. The outer rescue guarantees the handler never
      # raises (e.g. ThreadError if reached from a trap context, or a
      # concurrent-modification error from the unlocked read), honoring the
      # "never interrupt interpreter shutdown" contract.
      def kill_active_processes
        active_processes.to_a.each do |wait_thr|
          next unless wait_thr.alive?

          Process.kill('TERM', wait_thr.pid)
        rescue StandardError
          # Process already gone (Errno::ESRCH), not permitted, or invalid pid.
        end
        active_processes.clear
      rescue StandardError
        # Never let cleanup interfere with interpreter shutdown.
      end
    end

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
      # Serializes stdin access across the reactor fiber (transport writes
      # from inside Async) and user-callback threads spawned via FiberBoundary
      # (tool handlers / hooks calling Client#query). Without this lock,
      # close can nil @stdin between write's readiness check and the actual
      # @stdin.write call, producing NoMethodError on nil.
      @stdin_mutex = Mutex.new
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

    # Inject W3C trace context (TRACEPARENT/TRACESTATE, plus BAGGAGE) into the
    # subprocess env when an OTel span is active. Guard via defined? +
    # respond_to?, not require: an active span implies the constant is loaded,
    # and requiring here would break against the test mock / optional gem
    # group. Gate on the carrier's traceparent key (the W3C propagator writes
    # it only for a valid span context) so a baggage-only carrier or a noop
    # propagator preserves inherited env.
    def inject_otel_trace_context(process_env, custom_env)
      return unless defined?(OpenTelemetry) && OpenTelemetry.respond_to?(:propagation)

      carrier = {}
      OpenTelemetry.propagation.inject(carrier)
      return unless carrier.key?('traceparent')

      # Active span: scrub stale inherited W3C context (CI/k8s ambient env)
      # before writing fresh values, so an inherited TRACESTATE is never
      # paired with a new TRACEPARENT. nil actively unsets (spawn overlay
      # semantics — see the CLAUDECODE note in #connect; Python pops from a
      # complete env dict instead). Explicit options.env keys always win.
      %w[TRACEPARENT TRACESTATE].each do |key|
        process_env[key] = nil unless custom_env.key?(key)
      end
      carrier.each do |key, value|
        env_key = key.upcase
        process_env[env_key] = value unless custom_env.key?(env_key)
      end
    rescue StandardError, ScriptError
      # Best-effort tracing must never break connect() (Python: except
      # Exception). ScriptError too: NotImplementedError < ScriptError.
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
      # Propagate the active OTel trace context to the CLI so its spans parent
      # under the caller's distributed trace (Python SDK #821 parity). No-op
      # when opentelemetry is not loaded or there is no active span.
      inject_otel_trace_context(process_env, custom_env)
      process_env['CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING'] = 'true' if @options.enable_file_checkpointing
      process_env['PWD'] = @cwd.to_s if @cwd

      # Determine stderr handling
      should_pipe_stderr = @options.stderr || @options.debug_stderr || @options.extra_args.key?('debug-to-stderr')

      begin
        # Start process using Open3
        opts = { chdir: @cwd&.to_s }.compact

        @stdin, @stdout, @stderr, @process = Open3.popen3(process_env, *cmd, opts)
        # The CLI emits UTF-8 regardless of the parent locale. popen3 pipes
        # default to Encoding.default_external (US-ASCII under LANG=C/LC_ALL=C
        # — minimal Docker images, systemd, CI), which makes String#strip on
        # multibyte CLI output raise Encoding::CompatibilityError and kill the
        # read loop (its rescue only catches IOError). Mirrors the Python
        # SDK's TextReceiveStream(stdout), which always decodes UTF-8.
        @stdout&.set_encoding(Encoding::UTF_8)
        @stderr&.set_encoding(Encoding::UTF_8)
        self.class.register_active_process(@process)

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

      @stderr.each_line("\n", @max_buffer_size + 1) do |line|
        line_str = line.chomp
        next if line_str.empty?

        record_bounded_stderr(line_str)

        # Per-line isolation: a callback that raises (e.g. user's logger
        # transiently failing) must not poison the rest of the stderr stream.
        # Without this, the first exception terminates the each_line loop and
        # the SDK silently stops capturing stderr for the lifetime of the
        # process. Matches Python SDK v0.2.82 (PR #932).
        begin
          @options.stderr&.call(line_str)
        rescue StandardError
          # Drop the callback error; the line is already in the recent-stderr
          # ring buffer, which is what ProcessError surfaces on non-zero exit.
        end

        # Write to debug_stderr file/IO if provided, also isolated.
        begin
          if @options.debug_stderr
            if @options.debug_stderr.respond_to?(:puts)
              @options.debug_stderr.puts(line_str)
            elsif @options.debug_stderr.is_a?(String)
              File.open(@options.debug_stderr, 'a') { |f| f.puts(line_str) }
            end
          end
        rescue StandardError
          # Drop debug_stderr write errors so they never interrupt the loop.
        end
      end
    rescue StandardError
      # Stream-level error (pipe closed mid-read); the loop naturally ends here.
    end

    def drain_stderr_with_accumulation
      return unless @stderr

      @stderr.each_line("\n", @max_buffer_size + 1) do |line|
        line_str = line.chomp
        next if line_str.empty?

        record_bounded_stderr(line_str)
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

      # Close stdin under the same lock that guards write — otherwise a
      # concurrent writer (callbacks running on FiberBoundary threads) can
      # see @stdin nilled mid-write and hit NoMethodError on nil.
      @stdin_mutex.synchronize do
        begin
          @stdin&.close
        rescue IOError
          # Already closed, ignore
        rescue StandardError => e
          cleanup_errors << "stdin: #{e.message}"
        end
        @stdin = nil
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

      self.class.deregister_active_process(@process)
      @process = nil
      @stdout = nil
      # @stdin already nilled under the mutex above.
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
      raise CLIConnectionError, "Cannot write to terminated process" if @process && !@process.alive?
      raise CLIConnectionError, "Cannot write to process that exited with error: #{@exit_error}" if @exit_error

      # Snapshot @stdin under the lock so close() nilling it concurrently is
      # safe, but do the actual blocking IO *outside* the lock. Holding the
      # mutex across @stdin.write would let a full pipe buffer block the
      # writer indefinitely and block close() (which also needs the lock)
      # from killing the subprocess — a hang on disconnect.
      #
      # If close() runs while we are inside the IO call, it will close the
      # underlying stream and Ruby raises IOError("stream closed in another
      # thread") inside @stdin.write — the rescue below converts that into a
      # standard CLIConnectionError so callers see a clean shutdown error.
      stdin = @stdin_mutex.synchronize do
        raise CLIConnectionError, 'ProcessTransport is not ready for writing' unless @ready && @stdin

        @stdin
      end

      begin
        stdin.write(data)
        stdin.flush
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
        # The limit bounds per-read allocation: a line longer than
        # max_buffer_size+1 arrives as bounded chunks that the existing
        # accumulation + cap machinery below handles (mirrors Python, where
        # TextReceiveStream yields <=64KB chunks and the cap fires
        # incrementally). +1 so an exactly-max line plus "\n" arrives whole.
        # With UTF-8 external encoding Ruby extends a few bytes past the
        # limit rather than splitting a multibyte char. Without the limit,
        # an oversized line was fully allocated BEFORE the 1MB cap could
        # fire — unbounded memory on hostile/buggy stdout.
        @stdout.each_line("\n", @max_buffer_size + 1) do |line|
          line_str = line.strip
          next if line_str.empty?

          json_lines = line_str.split("\n")

          json_lines.each do |json_line|
            json_line = json_line.strip
            next if json_line.empty?

            # When no partial JSON is buffered, the next line must start with
            # `{` to be a valid stream-json message. Stray stderr-like text
            # (e.g., debug warnings the CLI occasionally writes to stdout)
            # would otherwise be appended into json_buffer, poisoning every
            # subsequent parse until the buffer overflows. Matches the Python
            # SDK's `if not json_buffer and not json_line.startswith("{")` guard.
            next if json_buffer.empty? && !json_line.start_with?('{')

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

      # Check process completion. @process may already be nil (close() ran
      # concurrently and reset it) or already waited on (Errno::ECHILD on
      # double-wait). Both are non-fatal — the message loop just exits.
      returncode = nil
      begin
        status = @process&.value
        returncode = status&.exitstatus
      rescue Errno::ECHILD
        # Process was already reaped (e.g., by close()); no exit status to surface.
        returncode = nil
      end

      # The child has exited and been reaped; drop it from the parent-exit
      # registry now rather than waiting for #close, which a caller may never
      # reach (e.g. a Client abandoned without #disconnect, or direct transport
      # use). Idempotent — #close's own deregister becomes a harmless no-op, and
      # #close still sees @process (left set here) for its termination logic.
      self.class.deregister_active_process(@process)

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
      # Mirrors Python's os.environ.get truthiness: any non-empty value skips,
      # including '0'/'false'/' '; unset or empty string runs the check.
      skip = ENV.fetch(SKIP_VERSION_CHECK_ENV_VAR, nil)
      return if skip && !skip.empty?

      begin
        output = capture_cli_version_output
        # Residual divergence from Python (anchored re.match over the first
        # stdout chunk): this searches anywhere in stdout+stderr, so leading
        # noise (a shim's own version line) could be mistaken for the CLI
        # version. Pre-existing shape; the check is best-effort only.
        if match = output.match(/([0-9]+\.[0-9]+\.[0-9]+)/)
          version = match[1]
          version_parts = version.split('.').map(&:to_i)
          min_parts = MINIMUM_CLAUDE_CODE_VERSION.split('.').map(&:to_i)

          # Array has no #< — the old `version_parts < min_parts` raised
          # NoMethodError into the blanket rescue, so the warning never fired.
          if (version_parts <=> min_parts).negative?
            warning = "Warning: Claude Code version #{version} at #{@cli_path} is unsupported in the Agent SDK. " \
                      "Minimum required version is #{MINIMUM_CLAUDE_CODE_VERSION}. " \
                      "Some features may not work correctly."
            warn warning
          end
        end
      rescue StandardError
        # Ignore version check errors — including Timeout::Error from the
        # probe deadline, mirroring Python's `except Exception: pass`.
      end
    end

    def ready?
      @ready
    end

    private

    # Run `claude -v` with a hard deadline. Arg-vector popen3 — no shell, same
    # injection-safety as capture3. Raises Timeout::Error past
    # VERSION_CHECK_TIMEOUT_SECONDS (swallowed by check_claude_version's
    # blanket rescue, mirroring Python's `except Exception: pass` around
    # anyio.fail_after(2)). Monotonic-deadline poll instead of stdlib
    # Timeout.timeout for the same reason as wait_process_with_timeout:
    # Thread#raise corrupts Async fiber-scheduler state, and connect runs
    # inside the reactor. Divergence: Python takes a single stdout chunk; we
    # read both pipes to EOF (pre-existing capture3 shape), so the deadline
    # also bounds CLI exit. ensure always reaps the probe (mirrors Python's
    # finally: terminate(); wait()).
    def capture_cli_version_output
      stdin, stdout, stderr, wait_thr = Open3.popen3(@cli_path.to_s, '-v')
      stdin.close
      drainer = Thread.new { [stdout.read, stderr.read] }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + VERSION_CHECK_TIMEOUT_SECONDS
      task = defined?(Async::Task) ? Async::Task.current? : nil
      until drainer.join(0)
        raise Timeout::Error if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        task ? task.sleep(0.05) : sleep(0.05)
      end
      out, err = drainer.value
      (out.to_s + err.to_s).force_encoding(Encoding::UTF_8).scrub.strip
    ensure
      if wait_thr&.alive?
        begin
          Process.kill('TERM', wait_thr.pid)
          Process.kill('KILL', wait_thr.pid) if !wait_thr.join(0.5) && wait_thr.alive?
        rescue StandardError
          # ESRCH etc. — probe already gone
        end
      end
      drainer&.kill if drainer&.alive?
      [stdout, stderr].each do |io|
        io&.close
      rescue StandardError
        # already closed
      end
    end

    # Append a stderr line to the recent-stderr ring, dropping the oldest
    # entry once the buffer exceeds RECENT_STDERR_LINES_LIMIT. Used to surface the
    # last few lines in ProcessError when the CLI exits non-zero.
    def record_bounded_stderr(line)
      @recent_stderr_mutex.synchronize do
        @recent_stderr << line
        @recent_stderr.shift if @recent_stderr.size > RECENT_STDERR_LINES_LIMIT
      end
    end
  end
end

# Terminate any CLI subprocess still live when the parent Ruby process exits.
# Registered once at require time (require is idempotent). Best-effort: the
# handler swallows all errors so it never interferes with interpreter shutdown.
at_exit { ClaudeAgentSDK::SubprocessCLITransport.kill_active_processes }
