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
  # invoked block (see `Client#receive_response`).
  module FiberBoundary
    module_function

    # Run the given block on a plain thread when a Fiber scheduler is active.
    # Returns the block's value. Exceptions propagate to the caller.
    def invoke(&block)
      return block.call unless Fiber.scheduler

      thread = Thread.new(&block)
      thread.report_on_exception = false
      thread.value
    end
  end
end
