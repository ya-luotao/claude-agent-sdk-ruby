#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'
require 'json'

# Example: Using typed hook inputs and outputs
# This demonstrates the new hook system with typed input/output classes:
# - PreToolUseHookInput, PostToolUseHookInput
# - PreToolUseHookSpecificOutput, PostToolUseHookSpecificOutput
# - UserPromptSubmitHookInput, UserPromptSubmitHookSpecificOutput
# - SyncHookJSONOutput for controlling hook behavior

puts "=== Advanced Hooks Example ==="
puts "Demonstrating typed hook inputs and outputs\n\n"

Async do
  # Example 1: PreToolUse hook with typed output
  puts "--- Example 1: PreToolUse Hook with Input Modification ---"

  pre_tool_hook = lambda do |input, _tool_use_id, _context|
    puts "PreToolUse hook triggered:"
    puts "  Tool: #{input.tool_name}"
    puts "  Session: #{input.session_id}"

    # Example: Modify Bash commands to add safety prefix
    if input.tool_name == 'Bash'
      tool_input = input.tool_input || {}
      original_command = tool_input[:command] || tool_input['command'] || ''

      # Check for dangerous patterns
      if original_command.match?(/rm\s+-rf|sudo\s+rm/)
        # Create typed deny output
        output = ClaudeAgentSDK::PreToolUseHookSpecificOutput.new(
          permission_decision: 'deny',
          permission_decision_reason: 'Destructive commands are not allowed'
        )
        return output.to_h
      end

      # Modify command to be safer (example: add echo prefix for demo)
      if original_command.start_with?('echo')
        # Allow echo commands as-is
        output = ClaudeAgentSDK::PreToolUseHookSpecificOutput.new(
          permission_decision: 'allow'
        )
        return output.to_h
      end
    end

    # Default: allow
    {}
  end

  # Example 2: PostToolUse hook with context addition
  post_tool_hook = lambda do |input, _tool_use_id, _context|
    puts "PostToolUse hook triggered:"
    puts "  Tool: #{input.tool_name}"
    puts "  Response length: #{input.tool_response&.to_s&.length || 0} chars"

    # Add context after tool execution
    output = ClaudeAgentSDK::PostToolUseHookSpecificOutput.new(
      additional_context: "Tool '#{input.tool_name}' executed at #{Time.now}"
    )

    # Wrap in SyncHookJSONOutput for full control
    sync_output = ClaudeAgentSDK::SyncHookJSONOutput.new(
      continue: true,
      suppress_output: false,
      hook_specific_output: output
    )

    sync_output.to_h
  end

  # Example 3: UserPromptSubmit hook
  prompt_hook = lambda do |input, _tool_use_id, _context|
    puts "UserPromptSubmit hook triggered:"
    prompt = input.prompt.to_s
    puts "  Prompt preview: #{prompt[0..50]}..."

    # Add context to the prompt
    output = ClaudeAgentSDK::UserPromptSubmitHookSpecificOutput.new(
      additional_context: "User is working in: #{input.cwd}"
    )

    { hookSpecificOutput: output.to_h }
  end

  # Configure hooks with timeout
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    allowed_tools: ['Bash'],
    hooks: {
      'PreToolUse' => [
        ClaudeAgentSDK::HookMatcher.new(
          matcher: 'Bash',
          hooks: [pre_tool_hook],
          timeout: 5  # 5 second timeout for hook execution
        )
      ],
      'PostToolUse' => [
        ClaudeAgentSDK::HookMatcher.new(
          matcher: 'Bash',
          hooks: [post_tool_hook],
          timeout: 5
        )
      ],
      'UserPromptSubmit' => [
        ClaudeAgentSDK::HookMatcher.new(
          hooks: [prompt_hook]
        )
      ]
    }
  )

  client = ClaudeAgentSDK::Client.new(options: options)

  begin
    puts "\nConnecting with advanced hooks..."
    client.connect
    puts "Connected!\n"

    # Test 1: Safe command
    puts "\n=== Test 1: Safe Echo Command ==="
    client.query("Run the command: echo 'Hello from advanced hooks!'")

    client.receive_response do |msg|
      case msg
      when ClaudeAgentSDK::AssistantMessage
        msg.content.each do |block|
          case block
          when ClaudeAgentSDK::TextBlock
            puts "Claude: #{block.text}"
          when ClaudeAgentSDK::ToolUseBlock
            puts "Tool: #{block.name}"
          end
        end
      when ClaudeAgentSDK::ResultMessage
        puts "\nCompleted in #{msg.num_turns} turns"
      end
    end

    puts "\n" + "-" * 40

    # Test 2: Blocked command
    puts "\n=== Test 2: Blocked Dangerous Command ==="
    client.query("Run the command: rm -rf /tmp/test")

    client.receive_response do |msg|
      case msg
      when ClaudeAgentSDK::AssistantMessage
        msg.content.each do |block|
          puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      when ClaudeAgentSDK::SystemMessage
        puts "System: #{msg.subtype}"
        puts "  #{msg.data[:message]}" if msg.data[:message]
      when ClaudeAgentSDK::ResultMessage
        puts "\nCompleted"
      end
    end

  ensure
    puts "\nDisconnecting..."
    client.disconnect
    puts "Done!"
  end
end.wait

puts "\n" + "=" * 50 + "\n"

# Example 4: Using HookContext with signal
puts "\n--- Example 4: Hook with Context Signal ---"
puts "HookContext provides access to abort signals for long-running hooks\n"

hook_with_context = lambda do |input, tool_use_id, context|
  # HookContext provides a cooperative cancellation signal.
  # In a real scenario, you might check context.signal periodically
  # during long-running operations to allow graceful cancellation

  puts "Hook context signal available: #{!context.signal.nil?}"

  # Return allow decision
  ClaudeAgentSDK::PreToolUseHookSpecificOutput.new(
    permission_decision: 'allow'
  ).to_h
end

puts "Hook with context signal defined (for demonstration)"
puts "In production, use context.signal to support cooperative cancellation"
