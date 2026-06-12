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
    # without a scheduler — so the bound is enforced in plain synchronous code
    # too; JoinTimeout is raised when it expires.
    def invoke(timeout: nil, &block)
      return block.call if timeout.nil? && !Fiber.scheduler

      thread = Thread.new(&block)
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
    # Without a scheduler the block runs in place and `break` unwinds
    # natively, never reaching the translation.
    def invoke_iteration(block, *args)
      invoke do
        block.call(*args)
        nil
      rescue LocalJumpError => e
        raise unless e.reason == :break

        Break.new(e.exit_value)
      end
    end
  end
end
