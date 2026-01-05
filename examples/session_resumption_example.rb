#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Session Resumption for Multi-turn Conversations
#
# This example demonstrates how to persist and resume Claude sessions
# for continuous multi-turn conversations. This is essential for:
# - Chat applications with ongoing conversations
# - Background jobs that need to continue previous work
# - Interactive agents that maintain context across requests
#
# Key concepts:
# - session_id: Used when creating a new session
# - resume: Used when continuing an existing session
# - The session_id from ResultMessage should be saved for future resumption

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Simple in-memory session store (use Redis/Database in production)
class SessionStore
  @@sessions = {}

  def self.get(key)
    @@sessions[key]
  end

  def self.set(key, value)
    @@sessions[key] = value
  end

  def self.exists?(key)
    @@sessions.key?(key)
  end

  def self.delete(key)
    @@sessions.delete(key)
  end
end

# Conversation manager that handles session persistence
class ConversationManager
  def initialize(conversation_id)
    @conversation_id = conversation_id
    @session_key = "claude_session:#{conversation_id}"
  end

  def send_message(message)
    Async do
      claude_session_id = SessionStore.get(@session_key)

      if claude_session_id
        puts "[Resuming session: #{claude_session_id}]"
        response = resume_conversation(message, claude_session_id)
      else
        puts "[Creating new session]"
        response = start_conversation(message)
      end

      response
    end.wait
  end

  def clear_session
    SessionStore.delete(@session_key)
    puts "[Session cleared for conversation: #{@conversation_id}]"
  end

  def fork_session(message)
    # Create a new branch from current session
    Async do
      claude_session_id = SessionStore.get(@session_key)

      if claude_session_id
        puts "[Forking session: #{claude_session_id}]"
        fork_conversation(message, claude_session_id)
      else
        puts "[No session to fork, starting new]"
        start_conversation(message)
      end
    end.wait
  end

  private

  def start_conversation(message)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: conversation_system_prompt,
      permission_mode: 'bypassPermissions',
      setting_sources: []
    )

    execute_query(options, message, new_session_id: generate_session_id)
  end

  def resume_conversation(message, claude_session_id)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: conversation_system_prompt,
      permission_mode: 'bypassPermissions',
      setting_sources: [],
      resume: claude_session_id  # This resumes the existing session
    )

    # Don't pass session_id when resuming - the resume option handles it
    execute_query(options, message, new_session_id: nil)
  end

  def fork_conversation(message, claude_session_id)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: conversation_system_prompt,
      permission_mode: 'bypassPermissions',
      setting_sources: [],
      resume: claude_session_id,
      fork_session: true  # Creates a new branch instead of continuing
    )

    execute_query(options, message, new_session_id: nil)
  end

  def execute_query(options, message, new_session_id:)
    client = ClaudeAgentSDK::Client.new(options: options)
    response_text = ''
    result_session_id = nil

    begin
      client.connect
      client.query(message, session_id: new_session_id)

      client.receive_response do |msg|
        case msg
        when ClaudeAgentSDK::AssistantMessage
          msg.content.each do |block|
            if block.is_a?(ClaudeAgentSDK::TextBlock)
              response_text += block.text
            end
          end

        when ClaudeAgentSDK::ResultMessage
          result_session_id = msg.session_id
          response_text = msg.result if msg.result

          # Save session for future resumption
          SessionStore.set(@session_key, result_session_id)
          puts "[Session saved: #{result_session_id}]"
        end
      end

      {
        response: response_text,
        session_id: result_session_id
      }

    ensure
      client.disconnect
    end
  end

  def generate_session_id
    "conv_#{@conversation_id}_#{Time.now.to_i}"
  end

  def conversation_system_prompt
    {
      type: 'preset',
      preset: 'claude_code',
      append: <<~PROMPT
        You are having a multi-turn conversation.
        Remember the context from previous messages.
        Keep responses concise and relevant.
      PROMPT
    }
  end
end

# Demo: Multi-turn conversation with session resumption
if __FILE__ == $PROGRAM_NAME
  puts "=== Session Resumption Example ===\n\n"

  conversation = ConversationManager.new('demo_001')

  # Turn 1: Start conversation
  puts "--- Turn 1 ---"
  puts "User: My name is Alice and I love Ruby programming."
  result = conversation.send_message("My name is Alice and I love Ruby programming. Remember this.")
  puts "Claude: #{result[:response]}\n\n"

  # Turn 2: Reference previous context
  puts "--- Turn 2 ---"
  puts "User: What's my name and what do I love?"
  result = conversation.send_message("What's my name and what do I love?")
  puts "Claude: #{result[:response]}\n\n"

  # Turn 3: Continue conversation
  puts "--- Turn 3 ---"
  puts "User: Tell me a Ruby tip related to my interests."
  result = conversation.send_message("Tell me a Ruby tip related to my interests.")
  puts "Claude: #{result[:response]}\n\n"

  # Demo: Fork the conversation
  puts "--- Fork Demo ---"
  puts "Forking conversation to explore alternative..."
  fork_result = conversation.fork_session("Actually, let's talk about Python instead.")
  puts "Claude (forked): #{fork_result[:response]}\n\n"

  # Original conversation continues
  puts "--- Original Continues ---"
  puts "User: Back to Ruby - what's my name again?"
  result = conversation.send_message("What's my name again?")
  puts "Claude: #{result[:response]}\n\n"

  # Clear session demo
  puts "--- Clear Session ---"
  conversation.clear_session

  puts "Starting fresh conversation..."
  result = conversation.send_message("What's my name?")
  puts "Claude (no memory): #{result[:response]}\n"
end
