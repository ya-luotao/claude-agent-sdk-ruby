# frozen_string_literal: true

module ClaudeAgentSDK
  # Internal. Consumers of the SDK should never need this directly.
  #
  # The SDK depends on `async`, which installs a Fiber scheduler whenever an
  # `Async { }` block is active. That scheduler multiplexes fibers onto a
  # single OS thread and intercepts IO so blocking calls yield to siblings.
  #
  # Most mature Ruby libraries are thread-safe but not fiber-safe: they key
  # state (checked-out DB connections, per-thread caches, request stores)
  # on `Thread.current`. When the scheduler interleaves two fibers on one
  # thread, those fibers share one state slot — and interleaved IO on a
  # shared connection silently corrupts wire protocols. This bites every
  # DB driver keyed by thread (pg, mysql2, sqlite3), ActiveRecord's
  # connection pool, and any HTTP/cache client pooled per-thread.
  #
  # The SDK invokes user-supplied callbacks (tool handlers, hooks,
  # permission callbacks, message blocks, observer methods) from inside
  # its reactor. `FiberBoundary.invoke` hops those calls to a plain
  # Ruby thread so user code runs on a fiber-scheduler-free thread and
  # inherits the same thread-keyed state assumptions the rest of the
  # user's app makes.
  #
  # No-op when no scheduler is active, so it's cheap to use unconditionally.
  #
  # OPT-IN INLINE MODE: hosts that are already fiber-isolated (e.g. Rails
  # apps with `IsolatedExecutionState.isolation_level = :fiber` running
  # solid_queue fiber workers) can pass `scheduling: :inline` to run
  # callbacks in place on the reactor fiber instead of hopping. This is the
  # same code path as the no-scheduler case — semantically the already-
  # shipped synchronous path, and Python SDK parity (async callbacks run
  # natively on the event loop there). The mode is plumbed per-call from
  # `ClaudeAgentOptions#callback_scheduling` — never a thread-local (the
  # reactor thread is shared by many fibers, so a set/reset window across
  # suspension points would leak across sessions). The one path a call
  # argument cannot cross (SDK-MCP dispatch through the mcp gem) carries
  # it via a scoped, invalidatable fiber-storage entry instead — see
  # SCHEDULING_KEY / SchedulingScope below.
  #
  # A `timeout:` always forces the thread hop regardless of scheduling —
  # `Thread#join(timeout)` is a hard bound that can abandon a wedged call,
  # which cooperative `with_timeout` cancellation cannot guarantee. The
  # store-adapter call sites (TranscriptMirrorBatcher, SessionResume) rely
  # on this to never stall the reactor on a wedged adapter.
  #
  # The thread hop severs `break`/`return`/`next` from the surrounding method,
  # so SDK loops yielding user callbacks must keep loop control outside the
  # invoked block (see `Client#receive_response`); user-initiated `break` is
  # bridged back to the calling fiber via `.invoke_iteration`.
  #
  # Deliberate carve-out: the STREAMING-INPUT enumerable is the one user-code
  # path iterated ON the reactor (Query#stream_input), matching Python where
  # async input generators run on the event loop. Enumerator#next is
  # fiber-based and cannot be pulled across threads, and a whole-iteration
  # thread bridge would break Async-native producers (Async::Queue#dequeue
  # etc.). Thread::Queue#pop / sleep / socket IO inside the enumerator are
  # scheduler-aware and park only the stream task; CPU-bound or
  # scheduler-opaque work must be moved by the user (a producer Thread
  # feeding a Thread::Queue, or FiberBoundary.invoke inside the enumerator).
  module FiberBoundary
    # Raised by .invoke when a timeout-bounded call exceeds its allotted time.
    # The worker thread is abandoned (cancellation is best-effort; the
    # in-flight call may still complete).
    class JoinTimeout < StandardError; end

    # Cancellation injected into INLINE user callbacks by timeout
    # enforcement (hook timeouts under scheduling: :inline) — user code
    # should let it propagate. Deliberately
    # NOT a StandardError: the exception is raised inside user code at a
    # suspension point, and a callback's ordinary `rescue StandardError`
    # must not be able to swallow the cancellation and convert an expired
    # hook into a success (Async::TimeoutError is a StandardError, so it
    # cannot be injected directly). The SDK translates it back to
    # Async::TimeoutError once control returns from user code.
    # @api private
    class InlineCancellation < Exception; end # rubocop:disable Lint/InheritException

    # Fiber-storage key carrying the dispatching session's callback
    # scheduling mode across the SDK-MCP dispatch path (Query ->
    # MCP::Server -> dynamic tool class). Fiber storage is per-fiber, so
    # concurrent sessions with different modes sharing one SdkMcpServer
    # instance cannot cross-contaminate — unlike mutating the shared
    # server (last-writer-wins, persists past close) or a thread-local
    # (the reactor thread is shared by many fibers).
    # @api private
    SCHEDULING_KEY = :claude_agent_sdk_callback_scheduling

    # The value stored under SCHEDULING_KEY: a
    # closable carrier rather than a bare symbol. Fiber-storage inheritance
    # copies the storage HASH but shares value REFERENCES, so every fiber
    # (and thread) created during a dispatch inherits this same object.
    # Restoring the dispatching fiber's own slot is therefore not enough —
    # a child task spawned inside a handler that outlives the dispatch
    # would keep reading the stale mode forever. Closing the scope in the
    # dispatch's ensure invalidates it for ALL inheritors at once; readers
    # fall back to the server's own default. Benign race on close vs. a
    # concurrent reader: either value is a defensible mode for a call that
    # straddles the dispatch boundary.
    # Also carries the session's callback wrapper — the two travel (and are
    # invalidated) together, so a descendant that outlives the dispatch can
    # neither run with the session's mode nor with its wrapper.
    # @api private
    class SchedulingScope
      attr_reader :mode, :wrapper

      def initialize(mode, wrapper = nil)
        @mode = mode
        @wrapper = wrapper
        @active = true
      end

      def active?
        @active
      end

      def close
        @active = false
      end
    end

    # Sentinel returned by .invoke_iteration when the user block attempted `break`.
    class Break
      attr_reader :value

      def initialize(value)
        @value = value
      end
    end

    module_function

    # Run the given block on a plain thread when a Fiber scheduler is active.
    # Returns the block's value. Exceptions propagate to the caller.
    #
    # With +timeout+ (seconds) the thread hop happens unconditionally — even
    # without a scheduler or with `scheduling: :inline` — so the bound is
    # enforced in plain synchronous code too; JoinTimeout is raised when it
    # expires.
    #
    # With `scheduling: :inline` (and no timeout) the block runs in place on
    # the current fiber, scheduler or not. The caller opts in via
    # `ClaudeAgentOptions#callback_scheduling`.
    #
    # With +wrapper+ (a callable, from `ClaudeAgentOptions#callback_wrapper`)
    # the executed body becomes `wrapper.call(block)` — composed BEFORE the
    # thread hop, so the wrapper runs on the same execution context as the
    # callback: on the worker thread in :thread mode (the whole point —
    # `Rails.application.executor.wrap` must run on the thread that touches
    # ActiveRecord), in place on the reactor fiber in :inline mode. The
    # wrapper must call its argument and return its value; exceptions from
    # the callback propagate through it unchanged, and exceptions raised by
    # the wrapper itself are treated exactly like callback exceptions. The
    # wrapper must not swallow exceptions and must return
    # the invocation's value — a user's `break` in a message block reaches
    # the wrapper as a clean return (invoke_iteration translates it BEFORE
    # the wrapper sees it), never as an exception a rescue/report wrapper
    # could falsely flag. In inline/no-scheduler mode `break` unwinds natively through the
    # wrapper's stack, so ensure-based wrappers (executor.wrap) are safe.
    #
    # The timeout path deliberately ignores the wrapper: it belongs to the
    # store-adapter carve-out (TranscriptMirrorBatcher, SessionResume),
    # which never carries user callbacks.
    def invoke(timeout: nil, scheduling: :thread, wrapper: nil, &block)
      body = wrapper && timeout.nil? ? -> { wrapper.call(block) } : block
      return body.call if timeout.nil? && (scheduling == :inline || !Fiber.scheduler)

      thread = Thread.new(&body)
      thread.report_on_exception = false
      return thread.value if timeout.nil?
      raise JoinTimeout, "timed out after #{timeout}s" unless thread.join(timeout)

      thread.value
    end

    # Invoke a user-supplied iteration block across the boundary. The thread
    # hop severs `break` from the surrounding loop, surfacing as
    # LocalJumpError(reason: :break) on the worker thread; translate it into
    # a Break sentinel so the SDK loop can break on the calling fiber.
    # Returns Break when the user broke, nil when the block completed.
    # Without a scheduler (or with `scheduling: :inline`) the block runs in
    # place and `break` unwinds natively, never reaching the translation.
    # The LocalJumpError -> Break translation lives INSIDE the invocation
    # handed to the +wrapper+: a user's `break` is normal loop control, not
    # an error, so a conforming rescue/report/re-raise wrapper must observe
    # a clean return (the Break sentinel as the invocation's value), never
    # a LocalJumpError it could falsely report or swallow. In inline /
    # no-scheduler mode `break` unwinds natively through the wrapper's
    # stack instead (ensure-based wrappers still run their cleanup).
    def invoke_iteration(block, *args, scheduling: :thread, wrapper: nil)
      invocation = lambda do
        block.call(*args)
        nil
      rescue LocalJumpError => e
        raise unless e.reason == :break

        Break.new(e.exit_value)
      end
      body = wrapper ? -> { wrapper.call(invocation) } : invocation
      invoke(scheduling: scheduling) { body.call }
    end
  end
end
