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
    # Called with the user's prompt text (not echoed back by CLI in streaming
    # mode): the verbatim string for String prompts (query() / Client#query),
    # and once per `type: 'user'` message for Enumerator/streaming input with
    # extracted text (string content, or newline-joined non-empty top-level
    # text blocks). User messages with no extractable text (tool_result-only,
    # image-only, empty text) are skipped; only Hash or JSON-string stream
    # items are inspected. In streaming mode, ordering relative to on_message
    # is not guaranteed.
    # @param prompt [String] The user's prompt string
    def on_user_prompt(prompt); end

    # Called for every parsed message (typed object from MessageParser).
    # @param message [Object] A typed message (AssistantMessage, ResultMessage, etc.)
    def on_message(message); end

    # Called once per error that surfaces from query() or from
    # Client#query/#receive_messages/#receive_response/#connect (after
    # argument/configuration validation — usage errors such as 'Not
    # connected' or invalid options do not notify) — including errors raised
    # by the user's own message block — before on_close where both fire. query() fires on_close even for connect-phase failures (its
    # ensure always runs); a Client#connect failure before the handshake
    # completes fires on_error WITHOUT on_close (the session never opened).
    # Not notified (by design): errors raised by control-request methods
    # (interrupt, set_model, …) — the same error also reaches the message
    # stream where it is notified once; errors during query()'s own teardown;
    # and input-stream errors swallowed by streaming input (warn only,
    # matching the Python SDK).
    # @param error [StandardError] The error that occurred
    def on_error(error); end

    # Called when the query or client disconnects. Use this to flush buffers.
    # In Client mode call disconnect (ideally in an ensure block) so on_close
    # runs and instrumentation (e.g. OTel spans) is flushed/exported.
    def on_close; end
  end
end
