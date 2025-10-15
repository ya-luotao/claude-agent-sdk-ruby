# frozen_string_literal: true

require 'json'

module ClaudeAgentSDK
  # Streaming input helpers for Claude Agent SDK
  module Streaming
    # Create a user message for streaming input
    #
    # @param content [String] The message content
    # @param session_id [String] Session identifier
    # @param parent_tool_use_id [String, nil] Parent tool use ID if responding to a tool
    # @return [String] JSON-encoded message
    def self.user_message(content, session_id: 'default', parent_tool_use_id: nil)
      message = {
        type: 'user',
        message: {
          role: 'user',
          content: content
        },
        parent_tool_use_id: parent_tool_use_id,
        session_id: session_id
      }
      JSON.generate(message) + "\n"
    end

    # Create an Enumerator from an array of messages
    #
    # @param messages [Array<String>] Array of message strings
    # @param session_id [String] Session identifier
    # @return [Enumerator] Enumerator yielding JSON-encoded messages
    #
    # @example
    #   messages = ['Hello', 'What is 2+2?', 'Thanks!']
    #   stream = ClaudeAgentSDK::Streaming.from_array(messages)
    def self.from_array(messages, session_id: 'default')
      Enumerator.new do |yielder|
        messages.each do |content|
          yielder << user_message(content, session_id: session_id)
        end
      end
    end

    # Create an Enumerator from a block
    #
    # @yield Block that yields message strings
    # @param session_id [String] Session identifier
    # @return [Enumerator] Enumerator yielding JSON-encoded messages
    #
    # @example
    #   stream = ClaudeAgentSDK::Streaming.from_block do |yielder|
    #     yielder.yield('First message')
    #     sleep 1
    #     yielder.yield('Second message')
    #   end
    def self.from_block(session_id: 'default', &block)
      Enumerator.new do |yielder|
        collector = Object.new
        def collector.yield(content)
          @content = content
        end
        def collector.content
          @content
        end

        inner_enum = Enumerator.new(&block)
        inner_enum.each do |content|
          yielder << user_message(content, session_id: session_id)
        end
      end
    end
  end
end
