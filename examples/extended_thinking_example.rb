#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'

# Example: Using max_thinking_tokens for extended thinking
# This feature allows Claude to use extended thinking for complex reasoning tasks.
# Extended thinking gives Claude more "thinking time" before responding.

puts "=== Extended Thinking Example ==="
puts "Demonstrating max_thinking_tokens for complex reasoning\n\n"

# Example 1: Math problem with extended thinking
puts "--- Example 1: Complex Math Problem ---"
puts "Enabling extended thinking for complex calculations\n"

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  max_thinking_tokens: 10000,  # Allow up to 10,000 tokens for thinking
  max_turns: 1
)

ClaudeAgentSDK.query(
  prompt: "Solve this step by step: If a train travels at 60 mph for 2.5 hours, " \
          "then at 80 mph for 1.75 hours, what is the total distance traveled? " \
          "Show your reasoning.",
  options: options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    message.content.each do |block|
      case block
      when ClaudeAgentSDK::ThinkingBlock
        puts "[Thinking...]"
        # The actual thinking content can be accessed if needed
        puts "  (#{block.thinking.length} chars of reasoning)"
      when ClaudeAgentSDK::TextBlock
        puts "\nClaude: #{block.text}"
      end
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\n--- Result ---"
    puts "Cost: $#{message.total_cost_usd}" if message.total_cost_usd
    puts "Turns: #{message.num_turns}"
  end
end

puts "\n" + "=" * 50 + "\n"

# Example 2: Logic puzzle with extended thinking
puts "\n--- Example 2: Logic Puzzle ---"
puts "Using extended thinking for a logic puzzle\n"

logic_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  max_thinking_tokens: 15000,  # More thinking for complex logic
  max_turns: 1
)

ClaudeAgentSDK.query(
  prompt: "Solve this logic puzzle: Three friends - Alice, Bob, and Carol - " \
          "have different favorite colors (red, blue, green) and different pets " \
          "(dog, cat, bird). Alice doesn't like red. The person with the cat likes blue. " \
          "Carol has a bird. Bob doesn't have a dog. Who has what color and pet?",
  options: logic_options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    thinking_shown = false
    message.content.each do |block|
      case block
      when ClaudeAgentSDK::ThinkingBlock
        unless thinking_shown
          puts "[Extended thinking enabled - Claude is reasoning through the puzzle...]"
          thinking_shown = true
        end
      when ClaudeAgentSDK::TextBlock
        puts "\nSolution:\n#{block.text}"
      end
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\n--- Result ---"
    puts "Cost: $#{message.total_cost_usd}" if message.total_cost_usd
  end
end

puts "\n" + "=" * 50 + "\n"

# Example 3: Code analysis with extended thinking
puts "\n--- Example 3: Code Analysis ---"
puts "Using extended thinking for code analysis\n"

code_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  max_thinking_tokens: 8000,
  max_turns: 1
)

code_snippet = <<~CODE
  def mystery(arr)
    return arr if arr.length <= 1
    pivot = arr[arr.length / 2]
    left = arr.select { |x| x < pivot }
    middle = arr.select { |x| x == pivot }
    right = arr.select { |x| x > pivot }
    mystery(left) + middle + mystery(right)
  end
CODE

ClaudeAgentSDK.query(
  prompt: "Analyze this Ruby code and explain what algorithm it implements, " \
          "its time complexity, and any potential improvements:\n\n#{code_snippet}",
  options: code_options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    message.content.each do |block|
      case block
      when ClaudeAgentSDK::ThinkingBlock
        puts "[Analyzing code with extended thinking...]"
      when ClaudeAgentSDK::TextBlock
        puts "\nAnalysis:\n#{block.text}"
      end
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\n--- Result ---"
    puts "Cost: $#{message.total_cost_usd}" if message.total_cost_usd
  end
end
