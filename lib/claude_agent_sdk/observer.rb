# frozen_string_literal: true

module ClaudeAgentSDK
  # Base module for message observers.
  #
  # Include this module and override the methods you care about.
  # All methods have no-op defaults so observers only need to implement
  # the callbacks relevant to their use case.
  #
  # Observers are registered via ClaudeAgentOptions#observers and are called
  # for every parsed message in both query() and Client#receive_messages.
  # Observer errors are rescued so they never crash the main message pipeline.
  #
  # @example Custom logging observer
  #   class LoggingObserver
  #     include ClaudeAgentSDK::Observer
  #
  #     def on_message(message)
  #       puts "[#{message.class.name}] received"
  #     end
  #   end
  module Observer
    # Called with the user's prompt text (not echoed back by CLI in streaming mode).
    # @param prompt [String] The user's prompt string
    def on_user_prompt(prompt); end

    # Called for every parsed message (typed object from MessageParser).
    # @param message [Object] A typed message (AssistantMessage, ResultMessage, etc.)
    def on_message(message); end

    # Called when a transport or parse error occurs.
    # @param error [Exception] The error that occurred
    def on_error(error); end

    # Called when the query or client disconnects. Use this to flush buffers.
    def on_close; end
  end
end
