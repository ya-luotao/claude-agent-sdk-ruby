#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Rails Background Job with Session Resumption
#
# This example demonstrates how to integrate the Claude Agent SDK with Rails
# background jobs (Sidekiq, Solid Queue, etc.) with session persistence for
# multi-turn conversations.
#
# Key features:
# - Session resumption for continuous conversations
# - Error handling with job retries
# - Database persistence of session state
# - MCP server integration

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Simulated ActiveRecord model for chat sessions
class ChatSession
  attr_accessor :id, :claude_session_id, :messages, :created_at, :updated_at

  @@sessions = {}

  def initialize(id:)
    @id = id
    @claude_session_id = nil
    @messages = []
    @created_at = Time.now
    @updated_at = Time.now
    @@sessions[id] = self
  end

  def self.find(id)
    @@sessions[id] || new(id: id)
  end

  def add_message(role:, content:, metadata: {})
    @messages << {
      id: "msg_#{@messages.length + 1}",
      role: role,
      content: content,
      metadata: metadata,
      created_at: Time.now
    }
    @updated_at = Time.now
    @messages.last
  end

  def update!(attributes)
    attributes.each { |k, v| send("#{k}=", v) }
    @updated_at = Time.now
  end

  def save!
    @updated_at = Time.now
    true
  end
end

# Simulated Rails Job class
class ChatAgentJob
  class << self
    attr_accessor :queue_name
  end

  self.queue_name = :claude_agents

  def self.perform_later(session_id, message_content)
    puts "[Job Enqueued] Session: #{session_id}"
    new.perform(session_id, message_content)
  end

  def perform(session_id, message_content)
    puts "[Job Started] Session: #{session_id}"

    session = ChatSession.find(session_id)

    # Add user message to history
    user_message = session.add_message(
      role: 'user',
      content: message_content
    )
    puts "[User Message] #{user_message[:id]}: #{message_content}"

    Async do
      execute_claude_query(session, message_content)
    end.wait

    puts "[Job Completed] Session: #{session_id}"

  rescue ClaudeAgentSDK::CLINotFoundError => e
    handle_cli_not_found(session, e)
    raise # Re-raise to trigger job retry

  rescue ClaudeAgentSDK::ProcessError => e
    handle_process_error(session, e)
    raise

  rescue StandardError => e
    handle_generic_error(session, e)
    raise
  end

  private

  def execute_claude_query(session, message_content)
    options = build_options(session)
    client = ClaudeAgentSDK::Client.new(options: options)

    begin
      client.connect
      puts "[Connected] Resuming: #{session.claude_session_id || 'new session'}"

      # Query without session_id when resuming (uses resume option instead)
      query_session_id = session.claude_session_id ? nil : generate_session_id
      client.query(message_content, session_id: query_session_id)

      process_response(client, session)

    ensure
      client.disconnect
      puts "[Disconnected]"
    end
  end

  def build_options(session)
    options_hash = {
      system_prompt: build_system_prompt,
      permission_mode: 'bypassPermissions',
      setting_sources: [],
      model: 'sonnet', # Use sonnet for faster responses in jobs
      max_turns: 50,   # Limit turns for safety
      cwd: Dir.pwd
    }

    # Resume existing session if available
    if session.claude_session_id
      options_hash[:resume] = session.claude_session_id
    end

    ClaudeAgentSDK::ClaudeAgentOptions.new(**options_hash)
  end

  def build_system_prompt
    {
      type: 'preset',
      preset: 'claude_code',
      append: <<~PROMPT
        You are an AI assistant running in a background job.

        Current time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')}

        Important guidelines:
        - Keep responses concise as they will be stored in a database
        - Use structured output when returning data
        - Report errors clearly so they can be handled programmatically
      PROMPT
    }
  end

  def process_response(client, session)
    assistant_content = []

    client.receive_response do |message|
      case message
      when ClaudeAgentSDK::AssistantMessage
        # Collect text content
        message.content.each do |block|
          case block
          when ClaudeAgentSDK::TextBlock
            assistant_content << block.text
            puts "[Chunk] #{block.text.slice(0, 50)}..."
          when ClaudeAgentSDK::ToolUseBlock
            puts "[Tool Use] #{block.name}"
          end
        end

        # Check for rate limit or other API errors
        if message.error
          puts "[API Error] #{message.error}"
          handle_api_error(session, message.error)
        end

      when ClaudeAgentSDK::ResultMessage
        # Save the session ID for future resumption
        session.update!(claude_session_id: message.session_id)
        puts "[Session Saved] #{message.session_id}"

        # Add assistant response to history
        full_content = message.result || assistant_content.join("\n\n")
        session.add_message(
          role: 'assistant',
          content: full_content,
          metadata: {
            duration_ms: message.duration_ms,
            cost_usd: message.total_cost_usd,
            num_turns: message.num_turns,
            claude_session_id: message.session_id
          }
        )

        puts "[Response] #{full_content.slice(0, 100)}..."
        puts "[Stats] Duration: #{message.duration_ms}ms, Cost: $#{message.total_cost_usd}"
      end
    end
  end

  def generate_session_id
    "job_#{Time.now.to_i}_#{rand(10000)}"
  end

  def handle_api_error(session, error_type)
    case error_type
    when 'rate_limit'
      puts "[Rate Limited] Will retry with exponential backoff"
      # In real Rails job, use retry_on with wait time
    when 'billing_error'
      puts "[Billing Error] Check API credits"
    when 'authentication_failed'
      puts "[Auth Error] Check API key configuration"
    end
  end

  def handle_cli_not_found(session, error)
    session.add_message(
      role: 'system',
      content: 'Error: Claude CLI not installed on server',
      metadata: { error: error.message }
    )
    puts "[Error] CLI not found: #{error.message}"
  end

  def handle_process_error(session, error)
    session.add_message(
      role: 'system',
      content: "Error: Process failed - #{error.message}",
      metadata: { error: error.message }
    )
    puts "[Error] Process error: #{error.message}"
  end

  def handle_generic_error(session, error)
    session.add_message(
      role: 'system',
      content: "Error: #{error.message}",
      metadata: { error: error.class.name, backtrace: error.backtrace&.first(5) }
    )
    puts "[Error] #{error.class}: #{error.message}"
  end
end

# Demo execution showing multi-turn conversation with session resumption
if __FILE__ == $PROGRAM_NAME
  puts "=== Rails Background Job with Session Resumption ===\n\n"

  session_id = 'session_demo_001'

  # First message - creates new session
  puts "--- Turn 1: Initial Query ---"
  ChatAgentJob.perform_later(session_id, "What is 2 + 2? Just give me the number.")

  puts "\n--- Turn 2: Follow-up Query (resumes session) ---"
  ChatAgentJob.perform_later(session_id, "Now multiply that by 3")

  puts "\n--- Turn 3: Another Follow-up ---"
  ChatAgentJob.perform_later(session_id, "What was my first question?")

  # Show session history
  session = ChatSession.find(session_id)
  puts "\n=== Session History ==="
  puts "Session ID: #{session.id}"
  puts "Claude Session: #{session.claude_session_id}"
  puts "Messages: #{session.messages.length}"
  session.messages.each do |msg|
    puts "  [#{msg[:role]}] #{msg[:content].slice(0, 60)}..."
  end
end
