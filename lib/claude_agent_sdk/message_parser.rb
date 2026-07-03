# frozen_string_literal: true

require_relative 'types'
require_relative 'errors'

module ClaudeAgentSDK
  # Parse message from CLI output into typed Message objects
  class MessageParser
    def self.parse(data)
      raise MessageParseError.new("Invalid message data type", data: data) unless data.is_a?(Hash)

      message_type = data[:type]
      raise MessageParseError.new("Message missing 'type' field", data: data) unless message_type

      case message_type
      when 'user'
        parse_user_message(data)
      when 'assistant'
        parse_assistant_message(data)
      when 'system'
        parse_system_message(data)
      when 'result'
        parse_result_message(data)
      when 'stream_event'
        parse_stream_event(data)
      when 'rate_limit_event'
        parse_rate_limit_event(data)
      when 'tool_progress'
        parse_tool_progress_message(data)
      when 'auth_status'
        parse_auth_status_message(data)
      when 'tool_use_summary'
        parse_tool_use_summary_message(data)
      when 'prompt_suggestion'
        parse_prompt_suggestion_message(data)
      end
      # Forward-compatible: returns nil for unrecognized message types so
      # newer CLI versions don't crash older SDK versions.
    rescue KeyError => e
      raise MessageParseError.new("Missing required field: #{e.message}", data: data)
    end

    def self.parse_user_message(data)
      parent_tool_use_id = data[:parent_tool_use_id]
      uuid = data[:uuid] # UUID for rewind support
      tool_use_result = data[:tool_use_result]
      message_data = data[:message]
      raise MessageParseError.new("Missing message field in user message", data: data) unless message_data
      # A non-Hash message (malformed CLI output) raised a raw TypeError from
      # message_data[:content] instead of the documented MessageParseError.
      raise MessageParseError.new("Invalid message field in user message (expected Hash, got #{message_data.class})", data: data) unless message_data.is_a?(Hash)

      content = message_data[:content]
      raise MessageParseError.new("Missing content in user message", data: data) unless content

      if content.is_a?(Array)
        content_blocks = parse_content_blocks(content, data)
        UserMessage.new(content: content_blocks, uuid: uuid, parent_tool_use_id: parent_tool_use_id,
                        tool_use_result: tool_use_result)
      else
        UserMessage.new(content: content, uuid: uuid, parent_tool_use_id: parent_tool_use_id,
                        tool_use_result: tool_use_result)
      end
    end

    def self.parse_assistant_message(data)
      message_data = data[:message]
      # A non-Hash message (malformed CLI output) raised a raw TypeError from
      # dig instead of the documented MessageParseError.
      raise MessageParseError.new("Invalid message field in assistant message (expected Hash, got #{message_data.class})", data: data) unless message_data.is_a?(Hash)

      content = message_data[:content]
      raise MessageParseError.new("Missing content in assistant message", data: data) unless content
      raise MessageParseError.new("Invalid assistant content (expected Array, got #{content.class})", data: data) unless content.is_a?(Array)

      content_blocks = parse_content_blocks(content, data)
      AssistantMessage.new(
        content: content_blocks,
        # model is required, like Python — fetch raises KeyError when absent,
        # which parse's rescue wraps into MessageParseError, instead of
        # silently constructing model: nil.
        model: message_data.fetch(:model),
        parent_tool_use_id: data[:parent_tool_use_id],
        error: data[:error], # authentication_failed, billing_error, rate_limit, invalid_request, server_error, unknown
        usage: message_data[:usage],
        message_id: message_data[:id],
        stop_reason: message_data[:stop_reason],
        session_id: data[:session_id],
        uuid: data[:uuid]
      )
    end

    # Typed SystemMessage subclasses inherit from `Type` and accept the raw
    # CLI hash directly — camelCase and snake_case keys are normalized by the
    # base class, and the full hash is captured as `#data`.
    SYSTEM_MESSAGE_CLASSES = {
      'init' => InitMessage,
      'compact_boundary' => CompactBoundaryMessage,
      'status' => StatusMessage,
      'api_retry' => APIRetryMessage,
      'local_command_output' => LocalCommandOutputMessage,
      'mirror_error' => MirrorErrorMessage,
      'hook_started' => HookStartedMessage,
      'hook_progress' => HookProgressMessage,
      'hook_response' => HookResponseMessage,
      'session_state_changed' => SessionStateChangedMessage,
      'files_persisted' => FilesPersistedMessage,
      'elicitation_complete' => ElicitationCompleteMessage,
      'task_started' => TaskStartedMessage,
      'task_progress' => TaskProgressMessage,
      'task_notification' => TaskNotificationMessage,
      # task_updated carries `status` inside `patch` (not at the top level) and
      # defaults task_id to "" — it derives those defensively in its own
      # constructor (see TaskUpdatedMessage), so it dispatches through the table
      # like every other system subtype. `data` is always symbol-keyed here:
      # `parse` rejects any message lacking a `:type` symbol key, so a
      # string-keyed hash never reaches these classes.
      'task_updated' => TaskUpdatedMessage
    }.freeze

    def self.parse_system_message(data)
      klass = SYSTEM_MESSAGE_CLASSES[data[:subtype]] || SystemMessage
      klass.new(data)
    end

    def self.parse_result_message(data)
      ResultMessage.new(data)
    end

    def self.parse_stream_event(data)
      StreamEvent.new(data)
    end

    def self.parse_rate_limit_event(data)
      RateLimitEvent.new(data.merge(raw_data: data))
    end

    def self.parse_tool_progress_message(data)
      ToolProgressMessage.new(data)
    end

    def self.parse_auth_status_message(data)
      AuthStatusMessage.new(data)
    end

    def self.parse_tool_use_summary_message(data)
      ToolUseSummaryMessage.new(data)
    end

    def self.parse_prompt_suggestion_message(data)
      PromptSuggestionMessage.new(data)
    end

    # Maps a content Array to typed blocks, guarding each element. A non-Hash
    # block (e.g. a bare String or nil from a malformed CLI message) raises a
    # descriptive MessageParseError carrying the full message rather than an
    # opaque TypeError/NoMethodError from `block[:type]` deep in parsing.
    def self.parse_content_blocks(content, data)
      content.map do |block|
        raise MessageParseError.new("Invalid content block (expected Hash, got #{block.class})", data: data) unless block.is_a?(Hash)

        parse_content_block(block)
      end
    end

    # Accepts blocks with either symbol or string keys — live CLI messages
    # arrive symbol-keyed (parsed via `symbolize_names: true`), session
    # transcripts arrive string-keyed (parsed via `symbolize_names: false`).
    # Uses a nil-aware fallback so `is_error: false` survives.
    def self.parse_content_block(block)
      get = lambda do |key|
        v = block[key]
        v.nil? ? block[key.to_s] : v
      end
      case get.call(:type)
      when 'text'
        TextBlock.new(text: get.call(:text))
      when 'thinking'
        ThinkingBlock.new(thinking: get.call(:thinking), signature: get.call(:signature))
      when 'tool_use'
        ToolUseBlock.new(id: get.call(:id), name: get.call(:name), input: get.call(:input))
      when 'tool_result'
        ToolResultBlock.new(
          tool_use_id: get.call(:tool_use_id),
          content: get.call(:content),
          is_error: get.call(:is_error)
        )
      when 'server_tool_use'
        ServerToolUseBlock.new(id: get.call(:id), name: get.call(:name), input: get.call(:input))
      when 'advisor_tool_result'
        # The CLI's wire type for server-side tool results is
        # advisor_tool_result (the old 'server_tool_result' branch was dead
        # code — no CLI version emits it; Python parses advisor_tool_result).
        ServerToolResultBlock.new(
          tool_use_id: get.call(:tool_use_id),
          content: get.call(:content),
          is_error: get.call(:is_error)
        )
      else
        # Forward-compatible: preserve unrecognized content block types (e.g., "document", "image")
        # so newer CLI versions don't crash older SDK versions.
        UnknownBlock.new(type: get.call(:type), data: block)
      end
    end
  end
end
