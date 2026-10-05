# frozen_string_literal: true

require_relative 'fiber_boundary'

module ClaudeAgentSDK
  # The three things every dispatch of a session's user code needs — its
  # resolved observers, where callbacks run (callback_scheduling) and the
  # middleware around them (callback_wrapper) — bound once, so that no call
  # site threads them by hand. A context holder, nothing deeper: each method
  # is the module function it names, called with the triple.
  #
  # @api private
  class Dispatch
    # For what takes the pair as its own arguments (Query, the transcript
    # mirror batcher).
    attr_reader :scheduling, :wrapper

    def initialize(observers, scheduling:, wrapper:)
      @observers = observers
      @scheduling = scheduling
      @wrapper = wrapper
    end

    # The same scheduling and wrapper around other observers. Client captures
    # the pair when it is constructed and resolves its observers on each
    # connect.
    def with_observers(observers)
      self.class.new(observers, scheduling: @scheduling, wrapper: @wrapper)
    end

    # See ClaudeAgentSDK.notify_observers.
    def notify(method, *)
      ClaudeAgentSDK.notify_observers(@observers, method, *, scheduling: @scheduling, wrapper: @wrapper)
    end

    # See ClaudeAgentSDK.observing_prompt_stream.
    def observing_stream(prompt)
      ClaudeAgentSDK.observing_prompt_stream(prompt, @observers, scheduling: @scheduling, wrapper: @wrapper)
    end

    # See FiberBoundary.invoke_iteration.
    def invoke_iteration(block, message)
      FiberBoundary.invoke_iteration(block, message, scheduling: @scheduling, wrapper: @wrapper)
    end
  end
end
