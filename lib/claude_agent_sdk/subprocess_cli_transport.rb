# frozen_string_literal: true

require 'json'
require 'open3'
require 'timeout'
require_relative 'transport'
require_relative 'errors'
require_relative 'version'
require_relative 'command_builder'
require_relative 'cli_installer'

module ClaudeAgentSDK
  # Subprocess transport using Claude Code CLI
  class SubprocessCLITransport < Transport
    # @api private
    DEFAULT_MAX_BUFFER_SIZE = 1024 * 1024 # 1MB buffer limit
    # @api private
    MINIMUM_CLAUDE_CODE_VERSION = '2.0.0'
    # @api private
    SKIP_VERSION_CHECK_ENV_VAR = 'CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'
    # @api private
    CLI_PATH_ENV_VAR = 'CLAUDE_CLI_PATH'
    # @api private
    VERSION_CHECK_TIMEOUT_SECONDS = 2 # mirrors Python's anyio.fail_after(2)
    # @api private
    RECENT_STDERR_LINES_LIMIT = 20
    # After stdout EOF the child has closed (or lost) its last stdout handle,
    # so it is normally already exiting; a CLI still running this long
    # afterwards is wedged and gets the same TERM -> KILL ladder as #close.
    #
    # @api private
    EOF_EXIT_GRACE_SECONDS = 5
    # @api private
    EOF_TERM_GRACE_SECONDS = 2

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
    #
    # @api private
    ACTIVE_PROCESSES = Set.new
    # @api private
    ACTIVE_PROCESSES_MUTEX = Mutex.new

    class << self
      # Public readers (the test suite uses `described_class.active_processes`);
      # they return the shared constants so subclasses observe the same objects.
      #
      # @api private
      def active_processes
        ACTIVE_PROCESSES
      end

      # @api private
      def active_processes_mutex
        ACTIVE_PROCESSES_MUTEX
      end

      # +wait_thr+ is the Process::Waiter returned by Open3.popen3.
      #
      # @api private
      def register_active_process(wait_thr)
        return unless wait_thr

        active_processes_mutex.synchronize { active_processes.add(wait_thr) }
      end

      # @api private
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
      #
      # @api private
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
      # Writers holding a live @stdin snapshot (inside #write's IO call),
      # keyed by Fiber.current, valued by that fiber's Fiber.scheduler (nil
      # for a plain thread). Inserted in #write's snapshot critical section,
      # so once stdin is detached under @stdin_mutex the registry holds
      # exactly the writers that can still touch the IO; deletes and reads
      # are single GVL-atomic Hash calls and take no lock (a lock in #write's
      # ensure could suspend a writer mid-unwind). Consulted when stdin is
      # closed: closing the fd neither wakes a fiber parked in IO#write nor
      # lets a reactor-side IO#close return while a plain thread is parked
      # there — see #wake_parked_fiber_writers / #close_stdin_io.
      @inflight_writers = {}
    end

    # Probe order (first hit wins):
    #   1. CLAUDE_CLI_PATH — explicit operator override, no discovery at all.
    #   2. A project-local vendored binary (CLIInstaller). Deliberately ahead
    #      of PATH: the point of a pinned, vendored CLI is that it beats
    #      whatever version happens to be installed globally on the host.
    #   3. `which claude`.
    #   4. Well-known install locations.
    #
    # @api private
    def find_cli
      env_path = ENV.fetch(CLI_PATH_ENV_VAR, nil).to_s
      unless env_path.empty?
        # Absolutize against the CURRENT working directory, which is where the
        # checks below resolve a relative path — the CLI is later spawned with
        # `chdir: options.cwd`, where the same relative path would name a
        # different file (or nothing at all). Returning the absolute form makes
        # what we validated and what we execute the same file.
        env_path = File.expand_path(env_path)
        # File.file? as well as executable?: executable? is true for
        # directories, so a directory in CLAUDE_CLI_PATH would otherwise pass
        # here and fail much later with an opaque spawn error.
        return env_path if File.file?(env_path) && File.executable?(env_path)
      end

      vendored = begin
        CLIInstaller.installed_path
      rescue StandardError
        # e.g. Dir.pwd raising because the cwd was removed — fall through.
        nil
      end
      return vendored if vendored

      # Try which command first (using Open3 for thread safety)
      cli = nil
      begin
        stdout, _status = Open3.capture2('which', 'claude')
        cli = stdout.strip
      rescue StandardError
        # which command failed, try common locations
      end
      return cli if cli && !cli.empty? && File.executable?(cli)

      # Try common locations. The home-relative ones are skipped when no
      # usable home exists (see #home_dir), so a HOME-less container still
      # reaches the actionable CLINotFoundError below.
      home = home_dir
      under_home = ->(rel) { File.join(home, rel) if home }
      locations = [
        under_home.call('.claude/local/claude'), # Claude Code default install location
        under_home.call('.npm-global/bin/claude'),
        '/usr/local/bin/claude',
        under_home.call('.local/bin/claude'),
        under_home.call('node_modules/.bin/claude'),
        under_home.call('.yarn/bin/claude')
      ].compact

      locations.each do |path|
        # Same test as the CLAUDE_CLI_PATH branch: a non-executable file here
        # would otherwise be accepted and fail at spawn with a raw EACCES
        # instead of CLINotFoundError's install instructions.
        return path if File.file?(path) && File.executable?(path)
      end

      raise CLINotFoundError.new(
        "Claude Code not found. Install with:\n  " \
        "npm install -g @anthropic-ai/claude-code\n" \
        "\nIf already installed locally, try:\n  " \
        'export PATH="$HOME/node_modules/.bin:$PATH"' \
        "\n\nOr provide the path via ClaudeAgentOptions:\n  " \
        "ClaudeAgentOptions.new(cli_path: '/path/to/claude')" \
        "\n\nFor hermetic deploys (Docker/CI), vendor a pinned CLI into the project:\n  " \
        "ClaudeAgentSDK::CLIInstaller.install_pinned  # installs #{CLIInstaller::PINNED_CLI_VERSION}" \
        "\n\nOr point the SDK at an existing binary:\n  " \
        "export #{CLI_PATH_ENV_VAR}=/path/to/claude"
      )
    end

    # Inject W3C trace context (TRACEPARENT/TRACESTATE, plus BAGGAGE) into the
    # subprocess env when an OTel span is active. Guard via defined? +
    # respond_to?, not require: an active span implies the constant is loaded,
    # and requiring here would break against the test mock / optional gem
    # group. Gate on the carrier's traceparent key (the W3C propagator writes
    # it only for a valid span context) so a baggage-only carrier or a noop
    # propagator preserves inherited env.
    #
    # @api private
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

    # @api private
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
      # ENTRYPOINT defaults to sdk-rb regardless of inherited process env
      # (the old ||= let an inherited 'cli' win and mis-attribute telemetry);
      # options.env may still override it. VERSION is merged last: always
      # set by the SDK, never overridable (Python merge-order parity).
      process_env = ENV.to_h
                       .merge('CLAUDECODE' => nil, 'CLAUDE_CODE_ENTRYPOINT' => 'sdk-rb')
                       .merge(custom_env)
                       .merge('CLAUDE_AGENT_SDK_VERSION' => VERSION)
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
        # :uid mirrors Python's anyio.open_process(user=...): String username
        # or Integer uid (Unix; requires privileges — typically root). The
        # .compact is mandatory: uid: nil raises TypeError on every connect.
        # On Windows spawn raises for :uid, wrapped below into
        # CLIConnectionError — fail-loud instead of the old silent ignore.
        opts = { chdir: @cwd&.to_s, uid: @options.user }.compact

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
      rescue StandardError, NotImplementedError => e
        # NotImplementedError < ScriptError, not StandardError (the trap this
        # repo keeps hitting): spawn raises it for :uid on platforms without
        # setuid (Windows), and it must wrap like every other spawn failure.
        error = CLIConnectionError.new("Failed to start Claude Code: #{e}")
        @exit_error = error
        raise error
      end
    end

    # @api private
    def handle_stderr
      return unless @stderr

      @stderr.each_line("\n", @max_buffer_size + 1) do |line|
        # Scrubbed at read time like stdout frames and the version probe: the
        # CLI (or a tool it runs) can emit invalid UTF-8 on stderr, and an
        # invalid string handed to the callback or kept for ProcessError#stderr
        # raises later in the user's encoding work (JSON logging/exporters).
        line = line.scrub unless line.valid_encoding?
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

    # @api private
    def drain_stderr_with_accumulation
      return unless @stderr

      @stderr.each_line("\n", @max_buffer_size + 1) do |line|
        line = line.scrub unless line.valid_encoding? # see #handle_stderr
        line_str = line.chomp
        next if line_str.empty?

        record_bounded_stderr(line_str)
      end
    end

    def close
      @ready = false
      return unless @process

      process = @process
      process_teardown_complete = false
      begin
        teardown_process
        process_teardown_complete = true
      ensure
        # The graceful escalation in teardown_process suspends (task sleep,
        # thread join), so a cancellation (Async::Stop) delivered mid-close
        # used to skip TERM/KILL entirely and leak a live CLI child until
        # interpreter exit (the at_exit reaper fires only then, TERM only).
        # Nothing here may suspend: a synchronous TERM plus a plain
        # background thread for the KILL escalation. On this path the
        # process stays in the at_exit registry until the fallback confirms
        # it was reaped; the normal path deregisters in teardown_process.
        force_terminate_in_background(process) unless process_teardown_complete

        # Snapshot-then-nil BEFORE the best-effort pipe close below: once the
        # references are cleared, even a close that somehow failed leaves the
        # IOs unreachable from this (still-referenced) transport, so GC can
        # finalize them — "wait for GC" alone would never fire while the
        # transport keeps pointing at them, and with @process nil a repeat
        # #close returns immediately, so a cancelled close used to leak the
        # pipe descriptors for the life of the object.
        #
        # @stdin is cleared WITHOUT its mutex (taking it could suspend
        # mid-cancellation): the ivar swap is atomic, and #write takes its
        # snapshot under the mutex, so a concurrent writer sees either nil
        # (raises not-ready — @ready is already false) or the old IO, whose
        # in-flight write then fails with IOError and is converted to
        # CLIConnectionError — the documented shutdown behavior either way.
        stdin_io = @stdin
        stdout_io = @stdout
        stderr_io = @stderr
        @process = nil
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @stderr_task = nil
        @exit_error = nil

        unless process_teardown_complete
          # Cancellation can land before teardown_process reached the pipe
          # closes. stdout/stderr are read ends (close never blocks); stdin's
          # implicit flush is a no-op in practice because #write flushes
          # after every write. A fiber writer still parked on it is woken
          # first — a scheduler hand-off (like close_now's child-task stops)
          # that resumes this fiber one reactor tick later; a second
          # cancellation landing there only skips the closes below, which
          # GC then finishes (termination already ran above). A plain
          # thread parked there makes close_stdin_io use a detached thread
          # (wait: false), so the close itself never blocks. Best-effort:
          # an IO that is already closed or fails to close is left to GC,
          # which the nil-ing above enables.
          if stdin_io
            begin
              wake_parked_fiber_writers
              close_stdin_io(stdin_io, wait: false)
            rescue StandardError
              nil
            end
          end
          [stdout_io, stderr_io].each do |io|
            io&.close
          rescue StandardError
            nil
          end
        end
      end
    end

    # Pre-existing #close body: stop the stderr drain, close pipes, wait for
    # graceful exit after stdin EOF, escalate TERM → KILL on timeout. Runs on
    # the reactor and suspends at several points; #close's ensure covers the
    # cancellation-abandoned case.
    #
    # @api private
    def teardown_process
      cleanup_errors = []

      # Kill stderr thread
      if @stderr_task&.alive?
        begin
          @stderr_task.kill
          @stderr_task.join(1)
        rescue StandardError => e
          raise if e.is_a?(Async::TimeoutError)

          cleanup_errors << "stderr thread: #{e.message}"
        end
      end

      begin
        shutdown_stdin
      rescue StandardError => e
        raise if e.is_a?(Async::TimeoutError)

        cleanup_errors << "stdin: #{e.message}"
      end

      begin
        @stdout&.close
      rescue IOError
        # Already closed, ignore
      rescue StandardError => e
        raise if e.is_a?(Async::TimeoutError)

        cleanup_errors << "stdout: #{e.message}"
      end

      begin
        @stderr&.close
      rescue IOError
        # Already closed, ignore
      rescue StandardError => e
        raise if e.is_a?(Async::TimeoutError)

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
            raise if e.is_a?(Async::TimeoutError)

            cleanup_errors << "force kill: #{e.message}"
          end
        rescue Errno::ESRCH
          # Process already dead
        end
      rescue Errno::ESRCH
        # Process already dead, ignore
      rescue StandardError => e
        # An outer reactor deadline is cancellation, not a cleanup warning.
        # Let close's ensure retain ownership and start fallback termination.
        raise if e.is_a?(Async::TimeoutError)

        cleanup_errors << "process termination: #{e.message}"
      end

      # Log any cleanup errors (non-fatal)
      warn "Claude SDK: Cleanup warnings: #{cleanup_errors.join(', ')}" if cleanup_errors.any?

      self.class.deregister_active_process(@process)
    end

    # Last-resort termination when #close was interrupted before the graceful
    # escalation finished. Contains no suspension points, so it is safe
    # inside an ensure during fiber cancellation: synchronous SIGTERM now,
    # then a plain (non-reactor) thread escalates to SIGKILL after a grace
    # period. Open3's Process::Waiter thread keeps reaping, so no zombie is
    # left either way. The alive? guard also makes the delayed KILL
    # pid-reuse-safe: while the waiter thread reports alive (not yet reaped),
    # the pid cannot have been recycled.
    #
    # @api private
    def force_terminate_in_background(process, grace_seconds: 2)
      return unless process

      unless process.alive?
        self.class.deregister_active_process(process)
        return
      end

      pid = process.pid
      begin
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        # The child exited before TERM; its waiter may still be reaping.
      rescue StandardError
        return # EPERM etc.: retain the live child in the at_exit registry.
      end

      Thread.new do
        begin
          unless process.join(grace_seconds)
            begin
              Process.kill('KILL', pid) if process.alive?
            rescue Errno::ESRCH
              # Still wait for the waiter when exit raced the signal.
            end
            process.join(grace_seconds)
          end
        rescue StandardError
          nil # best-effort; retain ownership if termination/reaping failed
        ensure
          self.class.deregister_active_process(process) unless process.alive?
        end
      end
    end

    # Wait for the spawned process to exit, up to +timeout_seconds+. Polls
    # process.alive? rather than using stdlib Timeout.timeout, which raises
    # across threads via Thread#raise and corrupts Async fiber-scheduler state
    # (close is always called inside an Async task). Yields to the current
    # Async task when one is active so the reactor keeps running.
    #
    # @api private
    def wait_process_with_timeout(timeout_seconds, process = @process)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      task = defined?(Async::Task) ? Async::Task.current? : nil
      while process.alive?
        raise Timeout::Error if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        task ? task.sleep(0.05) : sleep(0.05)
      end
      process.value
    end

    # Polls (via #wait_process_with_timeout) instead of
    # Process::Waiter#join(timeout): under a Fiber scheduler Ruby 3.2's
    # Thread#join ignores its timeout and never returns for a live thread
    # (probed on 3.2.0; 3.3/3.4 honor it).
    #
    # @api private
    def process_exited_within?(process, seconds)
      wait_process_with_timeout(seconds, process)
      true
    rescue Timeout::Error
      false
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
      # A fiber parked here is NOT woken by that close, though (the async
      # selector never learns the fd went away), so close wakes it with the
      # same IOError via the registry below — see #wake_parked_fiber_writers.
      writer = Fiber.current
      stdin = @stdin_mutex.synchronize do
        raise CLIConnectionError, 'ProcessTransport is not ready for writing' unless @ready && @stdin

        # Registered in the same critical section as the snapshot, so a
        # stdin detach (which nils @stdin under this lock) sees every writer
        # that still holds the IO.
        @inflight_writers[writer] = Fiber.scheduler
        @stdin
      end

      begin
        stdin.write(data)
        stdin.flush
      rescue StandardError => e
        @ready = false
        @exit_error = CLIConnectionError.new("Failed to write to process stdin: #{e}")
        raise @exit_error
      rescue Exception => e # rubocop:disable Lint/RescueException -- cancellation is not a StandardError and must keep its class
        # Cancellation (Async::Stop, InlineCancellation, a private deadline
        # class) delivered while parked inside IO#write on a full pipe: the
        # bytes already written stay on the pipe and nothing distinguishes
        # an aborted frame from a complete one, so the next well-formed
        # frame would be appended to a partial one and desync the protocol
        # for the rest of the session. Poison the transport and re-raise the
        # ORIGINAL exception: query.rb rescues Async::Stop by class, and
        # cancellation semantics depend on it propagating unchanged.
        # Recovery is a new session. Plain stores, like the StandardError
        # branch above — no lock, so nothing here can suspend mid-unwind.
        # (A writer already queued on IO#write's internal lock still
        # appends its frame after the partial one; the session is dead
        # either way, and every later write fails fast on @exit_error.)
        @ready = false
        @exit_error ||= CLIConnectionError.new(
          "stdin write interrupted by #{exception_class_name(e)}: possible partial frame"
        )
        raise
      ensure
        @inflight_writers.delete(writer)
      end
    end

    def end_input
      # Same path as #close's stdin step: detach under @stdin_mutex (the
      # transport's documented locking protocol; Python's end_input takes
      # _write_lock too), then wake and close outside it.
      shutdown_stdin
    rescue StandardError
      # Ignore
    end

    def read_messages(&)
      return enum_for(:read_messages) unless block_given?

      raise CLIConnectionError, 'Not connected' unless @process && @stdout

      json_buffer = ''
      # True only when stdout reached EOF on its own. When the loop is cut
      # short by close() (IOError) a partial trailing frame is expected and
      # is not reported.
      clean_eof = false

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
          # stdout is UTF-8-tagged but the CLI can emit invalid bytes (echoed
          # binary/latin-1 output). strip/lstrip below raise on invalid
          # encoding, which would abort the whole stream and drop buffered
          # valid frames — scrub the one bad line instead (the version-probe
          # path guards the same way).
          line = line.scrub unless line.valid_encoding?

          # Position-aware whitespace handling: a chunk of an over-limit line
          # must keep its interior whitespace — a blanket per-chunk strip
          # deleted spaces inside JSON strings straddling the chunk boundary
          # and could let a just-over-cap line PARSE with bytes silently
          # missing instead of raising. Only safe edges are trimmed: full
          # single-chunk lines strip both ends (the common path, original
          # behavior); a truncated line-initial chunk keeps its tail; a
          # continuation chunk keeps its head and only drops the newline.
          ends_line = line.end_with?("\n")
          if json_buffer.empty?
            chunk = ends_line ? line.strip : line.lstrip
            next if chunk.empty?

            # When no partial JSON is buffered, the line must start with `{`
            # to be a valid stream-json message. Stray stderr-like text
            # (e.g., debug warnings the CLI occasionally writes to stdout)
            # would otherwise be appended into json_buffer, poisoning every
            # subsequent parse until the buffer overflows. Matches the Python
            # SDK's `if not json_buffer and not json_line.startswith("{")`.
            next unless chunk.start_with?('{')
          else
            chunk = ends_line ? line.chomp : line
          end

          json_buffer += chunk

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
            # Continue accumulating (multi-line JSON, or a truncated chunk
            # awaiting the rest of its line)
            next
          end
        end
        clean_eof = true
      rescue IOError
        # Stream closed
      rescue StopIteration
        # Client disconnected
      end

      # Check process completion. @process may already be nil (close() ran
      # concurrently and reset it) or already waited on (Errno::ECHILD on
      # double-wait). Both are non-fatal — the message loop just exits.
      # Snapshot: a concurrent close() nils @process mid-wait.
      process = @process
      returncode = nil
      termsig = nil
      forced_exit = false
      unreaped = false
      begin
        # Bounded wait. The unbounded #value parked the read loop forever
        # behind a CLI that closed stdout and then hung — no 'end' ever
        # reached query()/receive_response. Past the grace period escalate
        # like #close (TERM, then KILL) and report it as an error below: a
        # child that outlives its stdout is wedged, whatever its exit code.
        # The poll parks only this task (task.sleep) on a reactor.
        if process && !process_exited_within?(process, EOF_EXIT_GRACE_SECONDS)
          forced_exit = true
          begin
            Process.kill('TERM', process.pid)
            unless process_exited_within?(process, EOF_TERM_GRACE_SECONDS)
              Process.kill('KILL', process.pid)
              # Even KILL can't reap a child stuck in uninterruptible kernel
              # I/O; bound this last wait too rather than block on #value.
              unreaped = !process_exited_within?(process, EOF_TERM_GRACE_SECONDS)
            end
          rescue Errno::ESRCH
            # Exited between the check and the signal; value below is final.
          end
        end
        status = process&.value unless unreaped
        # exitstatus is nil when the child died from a signal (OOM-kill
        # SIGKILL, SIGSEGV, ...) — that end-of-stream is a TRUNCATED response,
        # not a clean success. Python surfaces it as a negative returncode.
        returncode = status&.exitstatus
        termsig = status.termsig if status&.signaled?
      rescue Errno::ECHILD
        # Process was already reaped (e.g., by close()); no exit status to surface.
        returncode = nil
      end

      # The child has exited and been reaped; drop it from the parent-exit
      # registry now rather than waiting for #close, which a caller may never
      # reach (e.g. a Client abandoned without #disconnect, or direct transport
      # use). Idempotent — #close's own deregister becomes a harmless no-op, and
      # #close still sees @process (left set here) for its termination logic.
      # A child that could not be reaped even after KILL stays registered:
      # the at-exit safety net still owns it.
      self.class.deregister_active_process(@process) unless unreaped

      if forced_exit || termsig || (returncode && returncode != 0)
        # Wait briefly for stderr thread to finish draining
        @stderr_task&.join(1)

        stderr_text = @recent_stderr_mutex.synchronize { @recent_stderr.last(10).join("\n") }
        stderr_text = 'No stderr output captured' if stderr_text.empty?

        message =
          if unreaped
            "Command did not exit within #{EOF_EXIT_GRACE_SECONDS}s of closing stdout, and could not be " \
              'reaped even after SIGKILL'
          elsif forced_exit
            "Command did not exit within #{EOF_EXIT_GRACE_SECONDS}s of closing stdout; terminated by the SDK" +
              (termsig ? " with signal #{termsig}" : '')
          elsif termsig
            "Command terminated by signal #{termsig}"
          else
            "Command failed with exit code #{returncode}"
          end

        @exit_error = ProcessError.new(
          message,
          # Negative-signal exit_code mirrors Python's subprocess returncode.
          exit_code: termsig ? -termsig : returncode,
          stderr: stderr_text
        )
        raise @exit_error
      end

      # A clean exit with a newline-less partial frame still buffered: the
      # CLI (or whatever sits between it and us) cut a message short. The
      # in-loop parse never sees it complete, so it used to be dropped
      # silently — a missing ResultMessage with no error. Report it like
      # the over-cap path does; a bare whitespace tail is not a frame, and
      # once a concurrent #close has reset the transport (process nil) the
      # stream was torn down deliberately and a cut-off tail is expected.
      return unless clean_eof && process && !json_buffer.strip.empty?

      raise CLIJSONDecodeError.new(
        json_buffer,
        StandardError.new(
          "stdout ended mid-frame: #{json_buffer.bytesize} bytes buffered without a terminating newline"
        )
      )
    end

    # @api private
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

    # Detach stdin under the same lock that guards #write's readiness
    # check-and-snapshot — a concurrent writer (reactor fiber, or callback
    # on a FiberBoundary thread) either sees nil (raises not-ready) or is
    # already registered with its own snapshot — then wake and close
    # OUTSIDE the lock: waking hands control to the writer, whose unwinding
    # must not find the lock held, and the close may join a helper thread.
    # Detach before waking, so no writer can start after the wake. Caller
    # must NOT hold @stdin_mutex (non-reentrant). Raises what IO#close
    # raises, except IOError (already closed).
    def shutdown_stdin
      stdin_io = @stdin_mutex.synchronize do
        io = @stdin
        @stdin = nil
        io
      end
      return unless stdin_io

      wake_parked_fiber_writers
      close_stdin_io(stdin_io)
    end

    # Raise IOError into writer fibers of THIS thread's scheduler that are
    # parked inside the stdin IO call (a full pipe: the CLI stopped
    # reading). Closing the fd does not wake them — the async selector never
    # learns the fd went away, so the writer stayed parked forever (Ruby
    # 3.2/3.3/3.4, probed) and on Ruby 3.2 a close from another thread even
    # delivered the IOError into the scheduler loop itself. The injected
    # IOError is exactly what a plain-thread writer gets from the close, so
    # both unwind through #write's StandardError branch into
    # CLIConnectionError — the documented shutdown behavior. (Not
    # Task#stop: that would cancel the writer's whole task, which may be
    # the caller's own.) Scheduler#raise is the hand-off Task#stop and
    # task timeouts use: the writer runs its unwinding now and this fiber
    # resumes on the next reactor tick. Residual: a writer on another
    # thread's reactor — or any fiber writer when stdin is closed off-reactor
    # (e.g. Query's schedulerless fallback close) — cannot be reached from
    # here: it stays parked on 3.3/3.4, and on 3.2 the close crashes its
    # reactor with that IOError. The SDK's own writers share close's reactor.
    def wake_parked_fiber_writers
      scheduler = Fiber.scheduler
      return unless scheduler

      # to_a: one GVL-atomic snapshot — iterating the live Hash would let a
      # concurrent insert raise in the writer. Newest first: a later writer
      # is queued on IO#write's internal lock behind an earlier one, and
      # waking the lock holder first makes its unlock hand the lock to the
      # queued writer (scheduler.unblock) — a stale wakeup that would then
      # cut that writer's NEXT suspension short. Woken first, the queued
      # writer leaves the lock's wait queue in its own unwinding. Re-check
      # registration before each raise: a writer that already unwound must
      # not be interrupted wherever it is now.
      @inflight_writers.to_a.reverse_each do |fiber, owner|
        next unless @inflight_writers.key?(fiber)
        next unless owner.equal?(scheduler) && !fiber.equal?(Fiber.current) && fiber.alive?

        scheduler.raise(fiber, IOError, 'stdin closed while a write was in progress')
      rescue FiberError
        # Finished (or resumed) meanwhile — nothing to wake.
      end
    end

    # Close the stdin write end without stalling the reactor. On Ruby 3.3+
    # IO#close waits for threads blocked on the fd; called from a scheduler
    # fiber that wait is a scheduler sleep the blocked thread's wakeup never
    # resumes, so a FiberBoundary worker parked in #write on a full pipe
    # hung close — and the whole reactor — forever (probed on 3.3.9 and
    # 3.4.5; 3.2 does not wait). A plain helper thread has no scheduler:
    # its close interrupts the parked writer (IOError "stream closed in
    # another thread") and returns. Used only on a reactor with a
    # plain-thread writer still registered; everything else closes inline.
    # +wait+ false detaches the helper for #close's cancellation ensure,
    # which must not block. Raises what IO#close raises, except IOError
    # (already closed); a helper's own failure is dropped (best-effort).
    def close_stdin_io(io, wait: true)
      if Fiber.scheduler && @inflight_writers.value?(nil)
        helper = Thread.new do
          io.close
        rescue StandardError
          nil
        end
        helper.join if wait
      else
        io.close
      end
    rescue IOError
      # Already closed, ignore
    end

    # An anonymous per-invocation cancellation class (FiberBoundary's
    # cooperative timeouts, Query's private deadline) has no name; report
    # its nearest named ancestor instead of "#<Class:0x...>".
    def exception_class_name(error)
      error.class.name || error.class.ancestors.find(&:name).name
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

    # The (parent's) home directory for the well-known install probes, or nil
    # when none is usable — see Sessions.home_dir, the one definition.
    def home_dir
      Sessions.home_dir
    end
  end
end

# Terminate any CLI subprocess still live when the parent Ruby process exits.
# Registered once at require time (require is idempotent). Best-effort: the
# handler swallows all errors so it never interferes with interpreter shutdown.
at_exit { ClaudeAgentSDK::SubprocessCLITransport.kill_active_processes }
