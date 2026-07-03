# Hooks & Permission Callbacks

## Hooks

A **hook** is a Ruby proc/lambda that the Claude Code *application* (*not* Claude) invokes at specific points of the Claude agent loop. Hooks provide deterministic processing and automated feedback for Claude. Read more in [Claude Code Hooks Reference](https://docs.anthropic.com/en/docs/claude-code/hooks).

### Supported Events

All hook input objects include common fields like `session_id`, `transcript_path`, `cwd`, and `permission_mode`.

- `PreToolUse` → `PreToolUseHookInput` (`tool_name`, `tool_input`, `tool_use_id`)
- `PostToolUse` → `PostToolUseHookInput` (`tool_name`, `tool_input`, `tool_response`, `tool_use_id`)
- `PostToolUseFailure` → `PostToolUseFailureHookInput` (`tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt`)
- `UserPromptSubmit` → `UserPromptSubmitHookInput` (`prompt`)
- `Stop` → `StopHookInput` (`stop_hook_active`)
- `SubagentStop` → `SubagentStopHookInput` (`stop_hook_active`, `agent_id`, `agent_transcript_path`, `agent_type`)
- `PreCompact` → `PreCompactHookInput` (`trigger`, `custom_instructions`)
- `Notification` → `NotificationHookInput` (`message`, `title`, `notification_type`)
- `SubagentStart` → `SubagentStartHookInput` (`agent_id`, `agent_type`)
- `PermissionRequest` → `PermissionRequestHookInput` (`tool_name`, `tool_input`, `permission_suggestions`)

All 27 hook events have typed input classes. See [`ClaudeAgentSDK::HOOK_EVENTS`](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/lib/claude_agent_sdk/types.rb) and [examples/lifecycle_hooks_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/lifecycle_hooks_example.rb).

### Example: Blocking Dangerous Commands

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  bash_hook = lambda do |input, _tool_use_id, _context|
    return {} unless input.respond_to?(:tool_name) && input.tool_name == 'Bash'

    tool_input = input.tool_input || {}
    command = tool_input[:command] || tool_input['command'] || ''
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

    {}
  end

  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    allowed_tools: ['Bash'],
    hooks: {
      'PreToolUse' => [
        ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [bash_hook])
      ]
    }
  )

  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect
  client.query("Run the bash command: ./foo.sh --help")
  client.receive_response { |msg| puts msg }
  client.disconnect
end.wait
```

See [examples/hooks_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/hooks_example.rb), [examples/advanced_hooks_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/advanced_hooks_example.rb), and [examples/lifecycle_hooks_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/lifecycle_hooks_example.rb).

## Permission Callbacks

A **permission callback** is a Ruby proc/lambda that allows you to programmatically control tool execution. This gives you fine-grained control over what tools Claude can use and with what inputs.

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  permission_callback = lambda do |tool_name, input, context|
    return ClaudeAgentSDK::PermissionResultAllow.new if tool_name == 'Read'

    if tool_name == 'Write'
      file_path = input[:file_path] || input['file_path']
      if file_path && file_path.include?('/etc/')
        return ClaudeAgentSDK::PermissionResultDeny.new(
          message: 'Cannot write to sensitive system files',
          interrupt: false
        )
      end
    end

    ClaudeAgentSDK::PermissionResultAllow.new
  end

  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    allowed_tools: ['Read', 'Write', 'Bash'],
    can_use_tool: permission_callback
  )

  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect
  client.query("Create a file called test.txt with content 'Hello'")
  client.receive_response { |msg| puts msg }
  client.disconnect
end.wait
```

See [examples/permission_callback_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/permission_callback_example.rb).
