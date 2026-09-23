# frozen_string_literal: true

module ClaudeAgentSDK
  # Cooperative cancellation of a permission or hook request. Safe to observe from
  # worker threads and Async fibers. Cancellation does not kill user threads.
  class CancellationSignal
    def initialize
      @queue = Thread::Queue.new
    end

    def cancelled?
      @queue.closed?
    end

    # Wait for cancellation, returning true when cancelled, false on timeout.
    # Level-triggered: late callers and multiple waiters all observe cancellation.
    # @param timeout [Numeric, nil] Seconds; nil waits without a deadline
    def wait(timeout: nil) # rubocop:disable Naming/PredicateMethod -- blocking wait, not a state predicate
      @queue.pop(timeout: timeout)
      cancelled?
    end

    # Called by the SDK when the request is no longer actionable.
    # @api private
    def cancel
      @queue.close
    end
  end
end
