# Error Handling

## AssistantMessage Errors

`AssistantMessage` includes an `error` field for API-level errors:

```ruby
ClaudeAgentSDK.query(prompt: "Hello") do |message|
  if message.is_a?(ClaudeAgentSDK::AssistantMessage) && message.error
    case message.error
    when 'rate_limit'            then puts "Rate limited - retry after delay"
    when 'authentication_failed' then puts "Check your API key"
    when 'billing_error'         then puts "Check your billing status"
    when 'invalid_request'       then puts "Invalid request format"
    when 'server_error'          then puts "Server error - retry later"
    end
  end
end
```

See [examples/error_handling_example.rb](../examples/error_handling_example.rb).

## Exception Handling

```ruby
require 'claude_agent_sdk'

begin
  ClaudeAgentSDK.query(prompt: "Hello") { |message| puts message }
rescue ClaudeAgentSDK::ControlRequestTimeoutError
  puts "Control protocol timed out — consider increasing the timeout"
rescue ClaudeAgentSDK::CLINotFoundError
  puts "Please install Claude Code"
rescue ClaudeAgentSDK::ProcessError => e
  puts "Process failed with exit code: #{e.exit_code}"
rescue ClaudeAgentSDK::CLIJSONDecodeError => e
  puts "Failed to parse response: #{e}"
end
```

## Configuring Timeout

The control request timeout defaults to **1200 seconds** (20 minutes) to accommodate long-running agent sessions. Override it via environment variable:

```bash
export CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS=300  # 5 minutes
```

## Error Type Reference

```ruby
# Base exception class for all SDK errors
class ClaudeSDKError < StandardError; end

# Raised when connection to Claude Code fails
class CLIConnectionError < ClaudeSDKError; end

# Raised when the control protocol does not respond in time
class ControlRequestTimeoutError < CLIConnectionError; end

# Raised when Claude Code CLI is not found
class CLINotFoundError < CLIConnectionError
  # @param message [String] Error message (default: "Claude Code not found")
  # @param cli_path [String, nil] Optional path to the CLI that was not found
end

# Raised when the Claude Code process fails
class ProcessError < ClaudeSDKError
  attr_reader :exit_code,  # Integer | nil
              :stderr      # String | nil
end

# Raised when JSON parsing fails
class CLIJSONDecodeError < ClaudeSDKError
  attr_reader :line,           # String - The line that failed to parse
              :original_error  # Exception - The original JSON decode exception
end

# Raised when message parsing fails
class MessageParseError < ClaudeSDKError
  attr_reader :data  # Hash | nil
end
```

| Error | Description |
|-------|-------------|
| `ClaudeSDKError` | Base error for all SDK errors |
| `CLIConnectionError` | Connection issues |
| `ControlRequestTimeoutError` | Control protocol timeout (configurable via env var) |
| `CLINotFoundError` | Claude Code not installed |
| `ProcessError` | Process failed (includes `exit_code` and `stderr`) |
| `CLIJSONDecodeError` | JSON parsing issues |
| `MessageParseError` | Message parsing issues |

See [lib/claude_agent_sdk/errors.rb](../lib/claude_agent_sdk/errors.rb) for all error types.
