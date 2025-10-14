#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'

# Example 1: Simple query
puts "=== Example 1: Simple Query ==="
ClaudeAgentSDK.query(prompt: "What is 2 + 2?") do |message|
  if message.is_a?(ClaudeAgentSDK::AssistantMessage)
    message.content.each do |block|
      puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  elsif message.is_a?(ClaudeAgentSDK::ResultMessage)
    puts "\nCost: $#{message.total_cost_usd}" if message.total_cost_usd
    puts "Turns: #{message.num_turns}"
  end
end

# Example 2: Query with options
puts "\n=== Example 2: Query with Options ==="
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  system_prompt: "You are a helpful assistant. Keep responses brief.",
  max_turns: 1
)

ClaudeAgentSDK.query(prompt: "Tell me a joke", options: options) do |message|
  if message.is_a?(ClaudeAgentSDK::AssistantMessage)
    message.content.each do |block|
      puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  end
end

# Example 3: Using tools
puts "\n=== Example 3: Using Tools ==="
tool_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  allowed_tools: ['Read', 'Write', 'Bash'],
  permission_mode: 'acceptEdits'
)

ClaudeAgentSDK.query(
  prompt: "Create a hello.rb file that prints 'Hello from Claude Agent SDK!'",
  options: tool_options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    message.content.each do |block|
      case block
      when ClaudeAgentSDK::TextBlock
        puts "Claude: #{block.text}"
      when ClaudeAgentSDK::ToolUseBlock
        puts "Using tool: #{block.name}"
      end
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\nCompleted in #{message.num_turns} turns"
  end
end
