#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Using fallback_model for reliability
# This feature allows you to specify a backup model to use if the primary
# model is unavailable (e.g., due to rate limits or capacity issues).

puts "=== Fallback Model Example ==="
puts "Demonstrating fallback_model for improved reliability\n\n"

# Example 1: Basic fallback configuration
puts "--- Example 1: Primary with Fallback ---"
puts "Primary: claude-sonnet-4-20250514"
puts "Fallback: claude-3-5-haiku-20241022\n"

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  model: 'claude-sonnet-4-20250514',
  fallback_model: 'claude-3-5-haiku-20241022',
  max_turns: 1
)

ClaudeAgentSDK.query(
  prompt: "What model are you? Please identify yourself briefly.",
  options: options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    puts "Model used: #{message.model}"
    message.content.each do |block|
      puts "Response: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\nCost: $#{message.total_cost_usd}" if message.total_cost_usd
  end
end

puts "\n" + "=" * 50 + "\n"

# Example 2: Client with fallback for multi-query session
puts "\n--- Example 2: Session with Fallback Model ---"

Async do
  session_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    model: 'claude-sonnet-4-20250514',
    fallback_model: 'claude-3-5-haiku-20241022',
    system_prompt: "You are a helpful assistant. Always mention which model you are at the start."
  )

  client = ClaudeAgentSDK::Client.new(options: session_options)

  begin
    puts "Connecting with fallback model configuration..."
    client.connect
    puts "Connected!\n"

    queries = [
      "What is 2 + 2?",
      "Name a color.",
      "What is Ruby?"
    ]

    queries.each_with_index do |query, idx|
      puts "\n--- Query #{idx + 1}: #{query} ---"
      client.query(query)

      client.receive_response do |msg|
        case msg
        when ClaudeAgentSDK::AssistantMessage
          puts "Model: #{msg.model}"
          msg.content.each do |block|
            puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
          end
        when ClaudeAgentSDK::ResultMessage
          puts "Cost: $#{msg.total_cost_usd}" if msg.total_cost_usd
        end
      end
    end

  ensure
    puts "\nDisconnecting..."
    client.disconnect
    puts "Done!"
  end
end.wait

puts "\n" + "=" * 50 + "\n"

# Example 3: Different fallback strategies
puts "\n--- Example 3: Fallback Strategy Patterns ---"

# Strategy 1: Fast fallback (use cheaper model as backup)
fast_fallback = ClaudeAgentSDK::ClaudeAgentOptions.new(
  model: 'claude-sonnet-4-20250514',
  fallback_model: 'claude-3-5-haiku-20241022',  # Cheaper, faster
  max_turns: 1
)
puts "Strategy 1: Sonnet -> Haiku (cost optimization)"

# Strategy 2: Quality fallback (use similar-tier model)
quality_fallback = ClaudeAgentSDK::ClaudeAgentOptions.new(
  model: 'claude-opus-4-20250514',
  fallback_model: 'claude-sonnet-4-20250514',  # Still high quality
  max_turns: 1
)
puts "Strategy 2: Opus -> Sonnet (quality preservation)"

# Demonstrate with fast fallback
puts "\nRunning with fast fallback strategy..."
ClaudeAgentSDK.query(
  prompt: "Briefly explain what a fallback model is.",
  options: fast_fallback
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    puts "Model: #{message.model}"
    message.content.each do |block|
      puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\nCompleted successfully"
  end
end
