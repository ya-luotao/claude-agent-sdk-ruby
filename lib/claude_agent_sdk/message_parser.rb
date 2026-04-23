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

      content = message_data[:content]
      raise MessageParseError.new("Missing content in user message", data: data) unless content

      if content.is_a?(Array)
        content_blocks = content.map { |block| parse_content_block(block) }
        UserMessage.new(content: content_blocks, uuid: uuid, parent_tool_use_id: parent_tool_use_id,
                        tool_use_result: tool_use_result)
      else
        UserMessage.new(content: content, uuid: uuid, parent_tool_use_id: parent_tool_use_id,
                        tool_use_result: tool_use_result)
      end
    end

    def self.parse_assistant_message(data)
      content = data.dig(:message, :content)
      raise MessageParseError.new("Missing content in assistant message", data: data) unless content

      content_blocks = content.map { |block| parse_content_block(block) }
      AssistantMessage.new(
        content: content_blocks,
        model: data.dig(:message, :model),
        parent_tool_use_id: data[:parent_tool_use_id],
        error: data[:error], # authentication_failed, billing_error, rate_limit, invalid_request, server_error, unknown
        usage: data.dig(:message, :usage),
        message_id: data.dig(:message, :id),
        stop_reason: data.dig(:message, :stop_reason),
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
      'hook_started' => HookStartedMessage,
      'hook_progress' => HookProgressMessage,
      'hook_response' => HookResponseMessage,
      'session_state_changed' => SessionStateChangedMessage,
      'files_persisted' => FilesPersistedMessage,
      'elicitation_complete' => ElicitationCompleteMessage,
      'task_started' => TaskStartedMessage,
      'task_progress' => TaskProgressMessage,
      'task_notification' => TaskNotificationMessage
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
      else
        # Forward-compatible: preserve unrecognized content block types (e.g., "document", "image")
        # so newer CLI versions don't crash older SDK versions.
        UnknownBlock.new(type: get.call(:type), data: block)
      end
    end
  end
end
