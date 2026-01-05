#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Rails ActionCable Integration for Real-time Streaming
#
# This example demonstrates how to integrate the Claude Agent SDK with Rails
# ActionCable to stream responses to the frontend in real-time.
#
# Usage in a Rails application:
# 1. Create an ActionCable channel (app/channels/chat_channel.rb)
# 2. Create a background job that uses this pattern
# 3. Frontend subscribes to the channel and receives streaming updates

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Simulated ActionCable broadcast (in real Rails, use ActionCable.server.broadcast)
module ChatChannel
  def self.broadcast_to(chat_id, message)
    puts "[ActionCable -> chat_#{chat_id}] #{message.to_json}"
  end

  def self.broadcast_chunk(chat_id, content:, message_id: nil)
    broadcast_to(chat_id, {
      type: 'chunk',
      content: content,
      message_id: message_id
    })
  end

  def self.broadcast_thinking(chat_id, content:, message_id: nil)
    broadcast_to(chat_id, {
      type: 'thinking',
      content: content,
      message_id: message_id
    })
  end

  def self.broadcast_tool_use(chat_id, tool_name:, tool_input:, message_id: nil)
    broadcast_to(chat_id, {
      type: 'tool_use',
      tool_name: tool_name,
      tool_input: tool_input,
      message_id: message_id
    })
  end

  def self.broadcast_complete(chat_id, content:, message_id:, duration_ms: nil, cost_usd: nil)
    broadcast_to(chat_id, {
      type: 'complete',
      content: content,
      message_id: message_id,
      duration_ms: duration_ms,
      cost_usd: cost_usd
    })
  end

  def self.broadcast_error(chat_id, error:, message_id: nil)
    broadcast_to(chat_id, {
      type: 'error',
      error: error,
      message_id: message_id
    })
  end
end

# Helper methods for extracting content from messages
module MessageExtractor
  def self.extract_text(message)
    return '' unless message.content.is_a?(Array)

    message.content
      .select { |block| block.is_a?(ClaudeAgentSDK::TextBlock) }
      .map(&:text)
      .join("\n\n")
  end

  def self.extract_thinking(message)
    return [] unless message.content.is_a?(Array)

    message.content
      .select { |block| block.is_a?(ClaudeAgentSDK::ThinkingBlock) }
      .map(&:thinking)
  end

  def self.extract_tool_uses(message)
    return [] unless message.content.is_a?(Array)

    message.content
      .select { |block| block.is_a?(ClaudeAgentSDK::ToolUseBlock) }
      .map { |block| { name: block.name, input: block.input } }
  end
end

# Simulated chat executor (would be in a Rails job or service)
class ChatExecutor
  def initialize(chat_id:, message_id:)
    @chat_id = chat_id
    @message_id = message_id
  end

  def execute(prompt, session_id: nil, resume_session_id: nil)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: {
        type: 'preset',
        preset: 'claude_code',
        append: custom_system_prompt
      },
      permission_mode: 'bypassPermissions',
      setting_sources: [],
      resume: resume_session_id # Resume existing session if provided
    )

    client = ClaudeAgentSDK::Client.new(options: options)
    result_session_id = nil
    final_content = ''

    begin
      client.connect
      client.query(prompt, session_id: session_id)

      client.receive_response do |message|
        case message
        when ClaudeAgentSDK::AssistantMessage
          # Broadcast thinking blocks (for extended thinking)
          MessageExtractor.extract_thinking(message).each do |thinking|
            ChatChannel.broadcast_thinking(@chat_id,
              content: thinking,
              message_id: @message_id
            )
          end

          # Broadcast tool uses
          MessageExtractor.extract_tool_uses(message).each do |tool|
            ChatChannel.broadcast_tool_use(@chat_id,
              tool_name: tool[:name],
              tool_input: tool[:input],
              message_id: @message_id
            )
          end

          # Broadcast text content
          text = MessageExtractor.extract_text(message)
          unless text.empty?
            ChatChannel.broadcast_chunk(@chat_id,
              content: text,
              message_id: @message_id
            )
          end

        when ClaudeAgentSDK::SystemMessage
          # Handle system events (e.g., context compaction)
          status = message.data&.dig(:status)
          if status
            ChatChannel.broadcast_to(@chat_id, {
              type: 'system',
              status: status
            })
          end

        when ClaudeAgentSDK::ResultMessage
          result_session_id = message.session_id
          final_content = message.result || ''

          ChatChannel.broadcast_complete(@chat_id,
            content: final_content,
            message_id: @message_id,
            duration_ms: message.duration_ms,
            cost_usd: message.total_cost_usd
          )
        end
      end

      { session_id: result_session_id, content: final_content }

    rescue ClaudeAgentSDK::CLINotFoundError => e
      ChatChannel.broadcast_error(@chat_id,
        error: 'Claude CLI not installed',
        message_id: @message_id
      )
      raise

    rescue ClaudeAgentSDK::ProcessError => e
      ChatChannel.broadcast_error(@chat_id,
        error: "Process error: #{e.message}",
        message_id: @message_id
      )
      raise

    ensure
      client.disconnect
    end
  end

  private

  def custom_system_prompt
    <<~PROMPT
      You are a helpful assistant integrated into a Rails application.

      Current time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}

      Guidelines:
      - Provide clear, concise responses
      - Use markdown formatting for code blocks
      - Be helpful and professional
    PROMPT
  end
end

# Demo execution
if __FILE__ == $PROGRAM_NAME
  Async do
    puts "=== Rails ActionCable Integration Example ===\n\n"

    chat_id = 'chat_123'
    message_id = 'msg_456'

    executor = ChatExecutor.new(chat_id: chat_id, message_id: message_id)

    puts "Sending query to Claude with ActionCable streaming...\n\n"

    result = executor.execute(
      "What are the benefits of using ActionCable in Rails? Be concise."
    )

    puts "\n=== Execution Complete ==="
    puts "Session ID: #{result[:session_id]}"
    puts "Final content length: #{result[:content].length} characters"
  end.wait
end
