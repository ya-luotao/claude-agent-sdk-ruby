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
      else
        raise MessageParseError.new("Unknown message type: #{message_type}", data: data)
      end
    rescue KeyError => e
      raise MessageParseError.new("Missing required field: #{e.message}", data: data)
    end

    def self.parse_user_message(data)
      parent_tool_use_id = data[:parent_tool_use_id]
      message_data = data[:message]
      raise MessageParseError.new("Missing message field in user message", data: data) unless message_data

      content = message_data[:content]
      raise MessageParseError.new("Missing content in user message", data: data) unless content

      if content.is_a?(Array)
        content_blocks = content.map { |block| parse_content_block(block) }
        UserMessage.new(content: content_blocks, parent_tool_use_id: parent_tool_use_id)
      else
        UserMessage.new(content: content, parent_tool_use_id: parent_tool_use_id)
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
        error: data[:error] # authentication_failed, billing_error, rate_limit, invalid_request, server_error, unknown
      )
    end

    def self.parse_system_message(data)
      SystemMessage.new(
        subtype: data[:subtype],
        data: data
      )
    end

    def self.parse_result_message(data)
      ResultMessage.new(
        subtype: data[:subtype],
        duration_ms: data[:duration_ms],
        duration_api_ms: data[:duration_api_ms],
        is_error: data[:is_error],
        num_turns: data[:num_turns],
        session_id: data[:session_id],
        total_cost_usd: data[:total_cost_usd],
        usage: data[:usage],
        result: data[:result],
        structured_output: data[:structured_output] # Structured output when output_format is specified
      )
    end

    def self.parse_stream_event(data)
      StreamEvent.new(
        uuid: data[:uuid],
        session_id: data[:session_id],
        event: data[:event],
        parent_tool_use_id: data[:parent_tool_use_id]
      )
    end

    def self.parse_content_block(block)
      case block[:type]
      when 'text'
        TextBlock.new(text: block[:text])
      when 'thinking'
        ThinkingBlock.new(thinking: block[:thinking], signature: block[:signature])
      when 'tool_use'
        ToolUseBlock.new(id: block[:id], name: block[:name], input: block[:input])
      when 'tool_result'
        ToolResultBlock.new(
          tool_use_id: block[:tool_use_id],
          content: block[:content],
          is_error: block[:is_error]
        )
      else
        raise MessageParseError.new("Unknown content block type: #{block[:type]}")
      end
    end
  end
end
