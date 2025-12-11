#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Using max_budget_usd for spending control
# This feature allows you to set a spending cap in dollars for your queries.
# Useful for preventing runaway costs in automated systems.

puts "=== Budget Control Example ==="
puts "Demonstrating max_budget_usd spending cap\n\n"

# Example 1: Simple budget-limited query
puts "--- Example 1: Basic Budget Limit ---"
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  max_budget_usd: 0.10,  # Cap spending at $0.10
  max_turns: 3
)

ClaudeAgentSDK.query(
  prompt: "Explain the concept of recursion in programming. Be concise.",
  options: options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    message.content.each do |block|
      puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\n--- Cost Summary ---"
    puts "Total cost: $#{message.total_cost_usd}" if message.total_cost_usd
    puts "Budget limit: $0.10"
    puts "Turns used: #{message.num_turns}"
    puts "Is error: #{message.is_error}"
  end
end

puts "\n" + "=" * 50 + "\n"

# Example 2: Client with persistent budget settings
puts "\n--- Example 2: Client with Budget Control ---"

Async do
  budget_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    max_budget_usd: 0.25,  # Cap at $0.25 per session
    system_prompt: "You are a helpful assistant. Keep responses brief to minimize costs."
  )

  client = ClaudeAgentSDK::Client.new(options: budget_options)

  begin
    puts "Connecting with budget-controlled client..."
    puts "Budget limit: $0.25"
    client.connect
    puts "Connected!\n"

    total_spent = 0.0

    # First query
    puts "\n--- Query 1 ---"
    client.query("What is the capital of France?")

    client.receive_response do |msg|
      case msg
      when ClaudeAgentSDK::AssistantMessage
        msg.content.each do |block|
          puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      when ClaudeAgentSDK::ResultMessage
        cost = msg.total_cost_usd || 0
        total_spent += cost
        puts "\nQuery cost: $#{cost}"
        puts "Running total: $#{total_spent.round(4)}"
      end
    end

    # Second query
    puts "\n--- Query 2 ---"
    client.query("What is the capital of Germany?")

    client.receive_response do |msg|
      case msg
      when ClaudeAgentSDK::AssistantMessage
        msg.content.each do |block|
          puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      when ClaudeAgentSDK::ResultMessage
        cost = msg.total_cost_usd || 0
        total_spent += cost
        puts "\nQuery cost: $#{cost}"
        puts "Running total: $#{total_spent.round(4)}"
      end
    end

    puts "\n--- Session Summary ---"
    puts "Total spent: $#{total_spent.round(4)}"
    puts "Budget remaining: $#{(0.25 - total_spent).round(4)}"

  ensure
    puts "\nDisconnecting..."
    client.disconnect
    puts "Done!"
  end
end.wait

puts "\n" + "=" * 50 + "\n"

# Example 3: Very low budget for demonstration
puts "\n--- Example 3: Very Low Budget ---"
puts "Setting a very low budget to see how the system handles it"

low_budget_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  max_budget_usd: 0.001,  # Very low: $0.001
  max_turns: 1
)

ClaudeAgentSDK.query(
  prompt: "Say hello.",
  options: low_budget_options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    if message.error
      puts "Error type: #{message.error}"
    end
    message.content.each do |block|
      puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\nCost: $#{message.total_cost_usd}" if message.total_cost_usd
    puts "Is error: #{message.is_error}"
  end
end
