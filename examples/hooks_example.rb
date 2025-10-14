#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Using hooks to control tool execution
Async do
  # Define a hook that blocks dangerous bash commands
  bash_hook = lambda do |input, tool_use_id, context|
    tool_name = input[:tool_name]
    tool_input = input[:tool_input]

    return {} unless tool_name == 'Bash'

    command = tool_input[:command] || ''
    block_patterns = ['rm -rf', 'foo.sh']

    block_patterns.each do |pattern|
      if command.include?(pattern)
        return {
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            permissionDecision: 'deny',
            permissionDecisionReason: "Command contains forbidden pattern: #{pattern}"
          }
        }
      end
    end

    {} # Allow if no patterns match
  end

  # Create options with hook
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    allowed_tools: ['Bash'],
    hooks: {
      'PreToolUse' => [
        ClaudeAgentSDK::HookMatcher.new(
          matcher: 'Bash',
          hooks: [bash_hook]
        )
      ]
    }
  )

  client = ClaudeAgentSDK::Client.new(options: options)

  begin
    puts "Connecting with hook-enabled client..."
    client.connect
    puts "Connected!\n"

    # Test 1: Command with forbidden pattern (will be blocked)
    puts "=== Test 1: Forbidden Command ==="
    puts "Asking Claude to run: ./foo.sh --help"
    client.query("Run the bash command: ./foo.sh --help")

    client.receive_response do |msg|
      if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
        msg.content.each do |block|
          case block
          when ClaudeAgentSDK::TextBlock
            puts "Claude: #{block.text}"
          when ClaudeAgentSDK::ToolUseBlock
            puts "Tool attempted: #{block.name}"
          end
        end
      elsif msg.is_a?(ClaudeAgentSDK::SystemMessage)
        puts "System: #{msg.subtype} - #{msg.data[:message]}" if msg.data[:message]
      end
    end

    puts "\n#{'=' * 50}\n"

    # Test 2: Safe command (should work)
    puts "=== Test 2: Safe Command ==="
    puts "Asking Claude to run: echo 'Hello from hooks example!'"
    client.query("Run the bash command: echo 'Hello from hooks example!'")

    client.receive_response do |msg|
      if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
        msg.content.each do |block|
          case block
          when ClaudeAgentSDK::TextBlock
            puts "Claude: #{block.text}"
          when ClaudeAgentSDK::ToolUseBlock
            puts "Tool used: #{block.name}"
          end
        end
      elsif msg.is_a?(ClaudeAgentSDK::ResultMessage)
        puts "\nCompleted successfully!"
      end
    end

  ensure
    puts "\nDisconnecting..."
    client.disconnect
    puts "Done!"
  end
end.wait
