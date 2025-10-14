#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Calculator MCP Server
#
# This example demonstrates how to create an in-process MCP server with
# calculator tools using the Claude Agent SDK for Ruby.
#
# Unlike external MCP servers that require separate processes, this server
# runs directly within your Ruby application, providing better performance
# and simpler deployment.

# Define calculator tools

add_tool = ClaudeAgentSDK.create_tool('add', 'Add two numbers', { a: :number, b: :number }) do |args|
  result = args[:a] + args[:b]
  { content: [{ type: 'text', text: "#{args[:a]} + #{args[:b]} = #{result}" }] }
end

subtract_tool = ClaudeAgentSDK.create_tool('subtract', 'Subtract one number from another', { a: :number, b: :number }) do |args|
  result = args[:a] - args[:b]
  { content: [{ type: 'text', text: "#{args[:a]} - #{args[:b]} = #{result}" }] }
end

multiply_tool = ClaudeAgentSDK.create_tool('multiply', 'Multiply two numbers', { a: :number, b: :number }) do |args|
  result = args[:a] * args[:b]
  { content: [{ type: 'text', text: "#{args[:a]} × #{args[:b]} = #{result}" }] }
end

divide_tool = ClaudeAgentSDK.create_tool('divide', 'Divide one number by another', { a: :number, b: :number }) do |args|
  if args[:b] == 0
    { content: [{ type: 'text', text: 'Error: Division by zero is not allowed' }], is_error: true }
  else
    result = args[:a] / args[:b]
    { content: [{ type: 'text', text: "#{args[:a]} ÷ #{args[:b]} = #{result}" }] }
  end
end

sqrt_tool = ClaudeAgentSDK.create_tool('sqrt', 'Calculate square root', { n: :number }) do |args|
  n = args[:n]
  if n < 0
    { content: [{ type: 'text', text: "Error: Cannot calculate square root of negative number #{n}" }], is_error: true }
  else
    result = Math.sqrt(n)
    { content: [{ type: 'text', text: "√#{n} = #{result}" }] }
  end
end

power_tool = ClaudeAgentSDK.create_tool('power', 'Raise a number to a power', { base: :number, exponent: :number }) do |args|
  result = args[:base]**args[:exponent]
  { content: [{ type: 'text', text: "#{args[:base]}^#{args[:exponent]} = #{result}" }] }
end

# Helper to display messages
def display_message(msg)
  case msg
  when ClaudeAgentSDK::UserMessage
    msg.content.each do |block|
      case block
      when ClaudeAgentSDK::TextBlock
        puts "User: #{block.text}"
      when ClaudeAgentSDK::ToolResultBlock
        content_preview = block.content.to_s[0...100]
        puts "Tool Result: #{content_preview}..."
      end
    end
  when ClaudeAgentSDK::AssistantMessage
    msg.content.each do |block|
      case block
      when ClaudeAgentSDK::TextBlock
        puts "Claude: #{block.text}"
      when ClaudeAgentSDK::ToolUseBlock
        puts "Using tool: #{block.name}"
        puts "  Input: #{block.input}" if block.input
      end
    end
  when ClaudeAgentSDK::ResultMessage
    puts "Result ended"
    puts "Cost: $#{format('%.6f', msg.total_cost_usd)}" if msg.total_cost_usd
  end
end

# Main example
Async do
  # Create the calculator server with all tools
  calculator = ClaudeAgentSDK.create_sdk_mcp_server(
    name: 'calculator',
    version: '2.0.0',
    tools: [
      add_tool,
      subtract_tool,
      multiply_tool,
      divide_tool,
      sqrt_tool,
      power_tool
    ]
  )

  # Configure Claude to use the calculator server with allowed tools
  # Pre-approve all calculator MCP tools so they can be used without permission prompts
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    mcp_servers: { calc: calculator },
    allowed_tools: [
      'mcp__calc__add',
      'mcp__calc__subtract',
      'mcp__calc__multiply',
      'mcp__calc__divide',
      'mcp__calc__sqrt',
      'mcp__calc__power'
    ]
  )

  # Example prompts to demonstrate calculator usage
  prompts = [
    'List your tools',
    'Calculate 15 + 27',
    'What is 100 divided by 7?',
    'Calculate the square root of 144',
    'What is 2 raised to the power of 8?',
    'Calculate (12 + 8) * 3 - 10' # Complex calculation
  ]

  prompts.each do |prompt|
    puts "\n#{'=' * 50}"
    puts "Prompt: #{prompt}"
    puts '=' * 50

    client = ClaudeAgentSDK::Client.new(options: options)
    begin
      client.connect

      client.query(prompt)

      client.receive_response do |message|
        display_message(message)
      end
    ensure
      client.disconnect
    end
  end
end.wait
