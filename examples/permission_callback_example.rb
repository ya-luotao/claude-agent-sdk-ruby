#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Using permission callbacks for dynamic tool control
Async do
  # Define a permission callback that validates tool usage
  permission_callback = lambda do |tool_name, input, context|
    puts "\n[Permission Check]"
    puts "  Tool: #{tool_name}"
    puts "  Input: #{input.inspect}"

    # Allow Read operations
    if tool_name == 'Read'
      puts "  Decision: ALLOW (reading is safe)"
      return ClaudeAgentSDK::PermissionResultAllow.new
    end

    # Block Write to sensitive files
    if tool_name == 'Write'
      file_path = input[:file_path] || input['file_path']
      if file_path && (file_path.include?('/etc/') || file_path.include?('passwd'))
        puts "  Decision: DENY (sensitive file)"
        return ClaudeAgentSDK::PermissionResultDeny.new(
          message: 'Cannot write to sensitive system files',
          interrupt: false
        )
      end
      puts "  Decision: ALLOW (safe file write)"
      return ClaudeAgentSDK::PermissionResultAllow.new
    end

    # Block dangerous bash commands
    if tool_name == 'Bash'
      command = input[:command] || input['command'] || ''
      dangerous_patterns = ['rm -rf', 'sudo', '>']

      dangerous_patterns.each do |pattern|
        if command.include?(pattern)
          puts "  Decision: DENY (dangerous pattern: #{pattern})"
          return ClaudeAgentSDK::PermissionResultDeny.new(
            message: "Command contains dangerous pattern: #{pattern}",
            interrupt: false
          )
        end
      end

      puts "  Decision: ALLOW (safe command)"
      return ClaudeAgentSDK::PermissionResultAllow.new
    end

    # Default: allow
    puts "  Decision: ALLOW (default)"
    ClaudeAgentSDK::PermissionResultAllow.new
  end

  # Create options with permission callback
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    allowed_tools: ['Read', 'Write', 'Bash'],
    can_use_tool: permission_callback
  )

  client = ClaudeAgentSDK::Client.new(options: options)

  begin
    puts "Connecting with permission callback..."
    client.connect
    puts "Connected!\n"

    # Test 1: Safe file write (should be allowed)
    puts "\n=== Test 1: Safe File Write ==="
    client.query("Create a file called test_output.txt with the content 'Hello World'")

    client.receive_response do |msg|
      if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
        msg.content.each do |block|
          puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      elsif msg.is_a?(ClaudeAgentSDK::ResultMessage)
        puts "\nTest 1 completed"
      end
    end

    # Test 2: Dangerous file write (should be blocked)
    puts "\n=== Test 2: Dangerous File Write ==="
    client.query("Write to /etc/passwd")

    client.receive_response do |msg|
      if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
        msg.content.each do |block|
          puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      elsif msg.is_a?(ClaudeAgentSDK::ResultMessage)
        puts "\nTest 2 completed"
      end
    end

    # Test 3: Safe bash command (should be allowed)
    puts "\n=== Test 3: Safe Bash Command ==="
    client.query("Run the command: echo 'Permission callbacks work!'")

    client.receive_response do |msg|
      if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
        msg.content.each do |block|
          puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      elsif msg.is_a?(ClaudeAgentSDK::ResultMessage)
        puts "\nTest 3 completed"
      end
    end

  ensure
    puts "\nDisconnecting..."
    client.disconnect
    puts "Done!"
  end
end.wait
