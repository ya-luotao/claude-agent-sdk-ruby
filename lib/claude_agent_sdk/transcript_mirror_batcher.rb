# frozen_string_literal: true

require 'json'
require 'async'
require 'async/semaphore'
require_relative 'fiber_boundary'
require_relative 'session_store'

module ClaudeAgentSDK
  # Batching layer between `transcript_mirror` stdout frames and a SessionStore.
  #
  # The CLI subprocess emits
  # `{"type":"transcript_mirror","filePath":...,"entries":[...]}` frames
  # interleaved with normal SDK messages. The Query read loop peels these off
  # and hands them to #enqueue, which accumulates them and flushes to
  # SessionStore#append either when a `result` message arrives (explicit
  # #flush) or when the pending buffer exceeds size thresholds (eager
  # background flush). This keeps adapter latency off the hot path during
  # model streaming.
  #
  # At most ONE background drain task is live at a time. Frames arriving
  # while it is busy stay in the pending buffer, and the drainer picks them up
  # as one coalesced append when its current one completes — so a store slower
  # than the frame rate costs buffered entries, never a task (plus detached
  # batch) per frame, and #enqueue never suspends the read loop.
  #
  # Adapter failures are retried (MIRROR_APPEND_MAX_ATTEMPTS total) with short
  # backoff; timeouts are not retried since the in-flight call may still land.
  # Failures never raise — the local-disk transcript is already durable, so the
  # session continues unaffected — and are reported via the +on_error+ callback
  # (which surfaces them as a MirrorErrorMessage). Adapters should dedupe by
  # entry["uuid"] when present, since a retried batch may overlap a prior write.
  #
  # The semaphore serializes appends (FIFO, and every drain detaches its batch
  # immediately before queueing on it, so append order matches enqueue order),
  # but a #send that exceeds send_timeout is abandoned (its worker thread keeps
  # running) and the next drain proceeds, so two #append calls for the SAME
  # key can briefly overlap. SessionStore#append must be thread-safe per key
  # (see that method's contract). For adapters declaring
  # `callback_scheduling -> :inline` the timed-out call is instead cancelled
  # cooperatively (interrupted at its next suspension point, ensure runs) —
  # but only on the adapter's own fiber; work the adapter offloaded may still
  # land, so timeouts are not retried in either mode and the cancelled append
  # may remain permanently HALF-applied in the store. The drop is surfaced
  # (MirrorErrorMessage, batches_dropped?); the local transcript remains the
  # source of truth.
  class TranscriptMirrorBatcher
    # Eager-flush thresholds (exposed for tests).
    MAX_PENDING_ENTRIES = 500
    MAX_PENDING_BYTES = 1 << 20 # 1 MiB
    SEND_TIMEOUT_SECONDS = 60.0

    # Bounded retry for transient adapter failures. The backoff list length is
    # MIRROR_APPEND_MAX_ATTEMPTS - 1 (one delay between each pair of attempts).
    MIRROR_APPEND_MAX_ATTEMPTS = 3
    MIRROR_APPEND_BACKOFF_S = [0.2, 0.8].freeze

    # @param store [SessionStore] the adapter to mirror into
    # @param projects_dir [String, nil] base dir for file_path -> SessionKey
    #   mapping; nil when it could not be resolved (every frame is then
    #   dropped and reported via +on_error+)
    # @param on_error [#call] called as on_error.call(key, message) after a batch
    #   exhausts retries; must not raise
    # @param callback_wrapper [#call, nil] the session's
    #   ClaudeAgentOptions#callback_wrapper, composed around each #append
    #   inside the timeout bound (worker thread in :thread mode, cooperative
    #   timeout in :inline mode) — so e.g. Rails' executor.wrap covers an
    #   AR-backed adapter and checks connections back in per call
    def initialize(store:, projects_dir:, on_error:, send_timeout: SEND_TIMEOUT_SECONDS,
                   max_pending_entries: MAX_PENDING_ENTRIES, max_pending_bytes: MAX_PENDING_BYTES,
                   callback_wrapper: nil)
      @store = store
      @projects_dir = projects_dir
      @on_error = on_error
      @send_timeout = send_timeout
      @callback_wrapper = callback_wrapper
      # Probed ONCE here so an invalid callback_scheduling declaration fails
      # at construction, not mid-session inside a flush.
      @store_scheduling = SessionStores.store_callback_scheduling(store)
      @max_pending_entries = max_pending_entries
      @max_pending_bytes = max_pending_bytes
      @pending = []
      @pending_entries = 0
      @pending_bytes = 0
      # True while the background drain task is live; #enqueue spawns another
      # only once it has exited (see #schedule_background_drain).
      @background_drain_live = false
      # Set when #close starts; from then on anything still in @pending counts
      # as dropped (see #batches_dropped?).
      @closed = false
      # Batches that exhausted retries (or could not be keyed) and never
      # reached the store. Written only under @lock; read cross-thread by
      # #batches_dropped? (a plain Integer read is safe under the GVL).
      @dropped_batches = 0
      # Fiber-aware lock: the critical section blocks on SessionStore#append
      # (a thread hop), so a Thread::Mutex would deadlock the reactor. The
      # semaphore serializes drains so append ordering matches enqueue order.
      @lock = Async::Semaphore.new(1)
    end

    # True when at least one batch of entries never reached the store — the
    # mirror copy is incomplete. Consulted at teardown by the resume-from-store
    # cleanup so the materialized temp dir (which then holds the only copy of
    # the dropped turns) is preserved instead of deleted.
    #
    # Frames still buffered once #close has started count too. Query#close
    # stops the read task (the background drainer's parent) right after
    # #close returns, so a frame the read loop enqueued during the close
    # window — or any below-threshold frame after it — is never appended.
    # The old per-frame drain detached it into a parked task whose
    # cancellation counted it; with coalescing it stays in @pending, so it is
    # accounted here. Evaluated lazily: frames the drainer still manages to
    # deliver before the check are not drops, and nothing past #close has to
    # run for a stranded frame to be counted. (A plain ivar/Array#empty? read
    # is safe cross-thread under the GVL, like @dropped_batches.)
    def batches_dropped?
      @dropped_batches.positive? || (@closed && !@pending.empty?)
    end

    # Buffer a frame; schedule an eager background flush if thresholds are
    # exceeded and no background drain is already live (a live one will pick
    # this frame up). Synchronous and fire-and-forget.
    #
    # +entries+ are deep-stringified because the transport parses CLI output
    # with symbolized keys, but SessionStore entries are opaque JSON blobs that
    # must round-trip through string keys (Postgres JSONB / Redis) and feed
    # fold_session_summary, which reads string keys.
    def enqueue(file_path, entries)
      entries = deep_stringify(Array(entries))
      # An empty frame mirrors nothing (do_flush skips empty keys anyway), so
      # drop it here: otherwise its 2-byte "[]" inflates @pending_bytes and, in
      # eager mode (thresholds 0), schedules a no-op background drain per frame.
      return if entries.empty?

      # Approximate wire size — one stringify per frame (not per entry).
      size = JSON.generate(entries).bytesize
      @pending << { file_path: file_path, entries: entries }
      @pending_entries += entries.length
      @pending_bytes += size
      return unless over_threshold?

      task = Async::Task.current?
      task ? schedule_background_drain(task) : drain
    end

    # Flush all pending entries, serialized after any in-flight eager flush.
    def flush
      drain
    end

    # Final flush before teardown. Never raises. Bounded: it waits behind at
    # most the in-flight append, and frames arriving after it detached are
    # not chased (they count as dropped unless delivered; #batches_dropped?).
    def close
      @closed = true
      flush
    rescue StandardError => e
      warn "Claude SDK: TranscriptMirrorBatcher close flush failed: #{e.message}"
    end

    private

    def over_threshold?
      @pending_entries > @max_pending_entries || @pending_bytes > @max_pending_bytes
    end

    # Fire-and-forget on the reactor. The drainer loops until the buffer is
    # back under the thresholds, so while it is live every later frame is
    # simply buffered and coalesced into its next #drain — live background
    # tasks <= 1 and detached batches <= 1 + one per #flush / #close caller
    # parked on @lock, independent of frame rate and store latency.
    #
    # No lost wakeup: the loop's final over_threshold? check and the ensure
    # clearing the flag run with no suspension point between them, so an
    # #enqueue that saw the flag set is always observed by that check.
    # Every drainer (this one, #flush, #close) keeps detach-then-acquire, so
    # detach order == @lock FIFO order and append ordering holds. #drain
    # never raises.
    def schedule_background_drain(task)
      return if @background_drain_live

      @background_drain_live = true
      task.async do
        drain while over_threshold?
      ensure
        @background_drain_live = false
      end
    rescue StandardError
      # Task#async raises synchronously (e.g. FinishedError) before the block
      # runs; don't let a stuck flag disable background drains for good.
      @background_drain_live = false
      raise
    end

    # Detach the pending buffer, await any prior flush, then send. Detaching
    # before acquiring the lock lets #enqueue keep accumulating into a fresh
    # buffer while a prior flush is in flight. Never raises.
    def drain
      items = @pending
      @pending = []
      @pending_entries = 0
      @pending_bytes = 0

      errors = []
      # Cancellation (Async::Stop — not a StandardError) delivered while
      # waiting on the lock or inside the append's thread join loses the
      # detached items without either rescue firing. Teardown would then read
      # batches_dropped? as false and delete a materialized resume dir holding
      # the only copy of these entries — count the batch as dropped unless the
      # flush path ran to completion (do_flush counts its own failures).
      accounted = items.empty?
      begin
        @lock.acquire do
          # Emptiness is checked INSIDE the lock (matching the Python batcher):
          # an empty #flush/#close still serializes behind any in-flight or
          # queued drain, so they are true barriers — at result-yield and at
          # teardown the store really is up to date, and Query#close can't stop
          # the read task while a detached batch is still being appended.
          next if items.empty?

          begin
            do_flush(items, errors)
          rescue StandardError => e
            # do_flush already guards each append; this guards any remaining path
            # so the "never raises" contract holds against future regressions.
            @dropped_batches += 1
            warn "Claude SDK: TranscriptMirrorBatcher drain failed: #{e.message}"
          end
          accounted = true

          # Report errors BEFORE releasing the lock: flush/close are barriers, so
          # a caller observing flush completion must also observe the error
          # report. Reporting after release let an in-flight eager drain enqueue
          # its MirrorErrorMessage after the read loop's 'end' sentinel — past
          # the point where consumers stop dequeuing, i.e. never delivered. The
          # production on_error (Query#report_mirror_error) is a non-blocking
          # queue push, so holding the lock across it costs nothing.
          errors.each do |key, message|
            @on_error.call(key, message)
          rescue StandardError => e
            warn "Claude SDK: TranscriptMirrorBatcher on_error callback raised: #{e.message}"
          end
        end
      ensure
        @dropped_batches += 1 unless accounted
      end
    end

    def do_flush(items, errors)
      # Coalesce by file_path: one append per unique file per flush instead of
      # one per frame. First-seen file order preserved; entries keep enqueue order.
      by_path = {}
      items.each do |item|
        (by_path[item[:file_path]] ||= []).concat(item[:entries])
      end

      by_path.each do |file_path, entries|
        next if entries.empty? # avoid phantom keys in adapters that touch storage on append([])

        if @projects_dir.nil?
          # No CLAUDE_CONFIG_DIR and no usable home (SessionStores.projects_dir,
          # #120): the frame cannot be mapped to a SessionKey. Unlike a path
          # outside a KNOWN projects dir, this is a host misconfiguration that
          # loses the whole mirror, so it is surfaced as a MirrorErrorMessage.
          @dropped_batches += 1
          message = "cannot mirror #{file_path}: the Claude config directory is unknown (CLAUDE_CONFIG_DIR is " \
                    'unset and the home directory could not be resolved); set CLAUDE_CONFIG_DIR in the ' \
                    'environment or options.env'
          errors << [nil, message]
          warn "Claude SDK: [SessionStore] #{message}"
          next
        end

        key = SessionStores.file_path_to_session_key(file_path, @projects_dir)
        if key.nil?
          @dropped_batches += 1
          warn "Claude SDK: [SessionStore] dropping mirror frame: filePath #{file_path} is not under " \
               "#{@projects_dir} -- subprocess CLAUDE_CONFIG_DIR likely differs from parent (custom env / container?)"
          next
        end

        append_with_retry(file_path, key, entries, errors)
      end
    end

    def append_with_retry(file_path, key, entries, errors)
      last_err = nil
      succeeded = false

      MIRROR_APPEND_MAX_ATTEMPTS.times do |attempt|
        sleep_backoff(MIRROR_APPEND_BACKOFF_S[attempt - 1]) if attempt.positive?
        status, err = invoke_append(key, entries)
        case status
        when :ok
          succeeded = true
          break
        when :timeout
          # Don't retry on timeout — in EITHER mode. Thread mode: the
          # abandoned in-flight call may still land, so a retry would launch
          # a concurrent duplicate. Inline mode: cooperative cancellation
          # interrupts only the adapter's own fiber — work the adapter
          # itself offloaded (descendant tasks, an already-issued remote
          # write) may still land after the cancellation, so a retry races
          # it exactly like the thread case (adversarially demonstrated in
          # review: a dedupe-conforming adapter still persisted duplicates).
          # Uniform no-retry also bounds worst-case lock hold at
          # ~send_timeout. The dropped batch is surfaced (MirrorErrorMessage,
          # batches_dropped?) and the local transcript remains the source of
          # truth.
          last_err = err
          break
        else # :error — retryable
          last_err = err
        end
      end

      return if succeeded

      @dropped_batches += 1
      errors << [key, last_err.to_s]
      warn "Claude SDK: TranscriptMirrorBatcher flush failed for #{file_path}: #{last_err}"
    end

    # Run SessionStore#append (user code) on a plain thread via FiberBoundary,
    # bounded by send_timeout (enforced with or without an active reactor).
    # Returns [:ok, nil] / [:timeout, err] / [:error, err]. On timeout in
    # thread mode the worker thread is left running (cancellation is
    # best-effort; the in-flight call may still land) and not retried. An
    # adapter declaring `callback_scheduling -> :inline` instead runs in
    # place on the reactor under a cooperative timeout (interrupted at its
    # next suspension point, ensure blocks run) — same JoinTimeout contract
    # and same no-retry semantics (see append_with_retry: offloaded work
    # may outlive the cancellation). The session's callback_wrapper composes
    # inside the bound (see FiberBoundary.invoke); a wrapper-raised error is
    # indistinguishable from a store error here — [:error, e], retryable.
    def invoke_append(key, entries)
      FiberBoundary.invoke(timeout: @send_timeout, scheduling: @store_scheduling, wrapper: @callback_wrapper) do
        @store.append(key, entries)
      end
      [:ok, nil]
    rescue FiberBoundary::JoinTimeout
      [:timeout, "append timed out after #{@send_timeout}s"]
    rescue StandardError, NotImplementedError => e
      # NotImplementedError is a ScriptError, not a StandardError: the base
      # SessionStore stubs raise it, and letting it escape here would kill the
      # whole reactor instead of surfacing a MirrorErrorMessage.
      [:error, e]
    end

    # Sleep that yields the reactor when one is active, else a plain sleep.
    def sleep_backoff(seconds)
      task = Async::Task.current?
      task ? task.sleep(seconds) : sleep(seconds)
    end

    def deep_stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
      when Array then obj.map { |elem| deep_stringify(elem) }
      else obj
      end
    end
  end
end
