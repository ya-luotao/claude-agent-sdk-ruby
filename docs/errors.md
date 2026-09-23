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

See [examples/error_handling_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/error_handling_example.rb).

## Exception Handling

```ruby
require 'claude_agent_sdk'

begin
  ClaudeAgentSDK.query(prompt: "Hello") { |message| puts message }
rescue ClaudeAgentSDK::ControlRequestTimeoutError
  puts "Control protocol timed out — consider increasing the timeout"
rescue ClaudeAgentSDK::CLINotFoundError
  puts "Please install Claude Code"
rescue ClaudeAgentSDK::ResultError => e
  # More specific than ProcessError — must be rescued first.
  case e.terminal_reason
  when 'api_error' then puts "API failed (HTTP #{e.api_error_status}): #{e.result}"
  else puts "Run failed (#{e.subtype}): #{e.errors.join('; ')}"
  end
rescue ClaudeAgentSDK::ProcessError => e
  puts "Process failed with exit code: #{e.exit_code}"
rescue ClaudeAgentSDK::CLIJSONDecodeError => e
  puts "Failed to parse response: #{e}"
end
```

## Terminal Error Results

When a run fails, the CLI emits a `result` message with `is_error: true` (which
you still receive as a `ResultMessage`) and *then* exits non-zero on purpose,
for shell-script consumers. That trailing process failure carries nothing
beyond "exit code 1", so the SDK replaces it with a `ResultError` carrying the
payload the CLI already reported — you can branch on *why* the run failed
without matching on strings:

```ruby
begin
  ClaudeAgentSDK.query(prompt: "...") { |m| handle(m) }
rescue ClaudeAgentSDK::ResultError => e
  retry_later    if e.terminal_reason == 'api_error'   # overloaded / timeout
  widen_budget   if e.subtype == 'error_max_turns'
  raise
end
```

`ResultError` subclasses `ProcessError`, so existing `rescue ProcessError`
handlers keep working unchanged — but rescue `ResultError` **first** if you
want the structured fields.

The exception message prefers, in order: the CLI's `errors[]`, then `result`,
then a non-`success` `subtype`, then the HTTP status. A run that ends on an API
failure arrives as `subtype: "success"` with `is_error: true` and the prose in
`result`, which is why `subtype` alone is not used as the message.

A refused resume (a nonexistent session, or a `resume_drops_turn` guard
failure) reaches you the same way — including on a control request such as the
initial handshake that was still in flight when the CLI exited. Match on
`Resume rejected by --resume-drops-turn:` in the message and treat it as
deterministic: clear the fork target and resume plainly rather than retrying.

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

# Raised by the local-disk session APIs when CLAUDE_CONFIG_DIR is unset and
# no usable home directory exists for the default ~/.claude
class ConfigDirError < ClaudeSDKError; end

# Raised when the Claude Code process fails
class ProcessError < ClaudeSDKError
  attr_reader :exit_code,  # Integer | nil
              :stderr      # String | nil
end

# Raised when the CLI exits after reporting a terminal error result.
# Subclasses ProcessError, so existing `rescue ProcessError` keeps working.
class ResultError < ProcessError
  attr_reader :subtype,          # String | nil ('error_max_turns', 'error_during_execution', ...)
              :errors,           # Array<String> - error strings from the CLI (may be empty)
              :result,           # String | nil - result text; holds the "API Error: ..." prose
              :api_error_status, # Integer | nil - HTTP status of the failing API call
              :terminal_reason,  # String | nil - why the run ended ('api_error', 'max_turns', ...)
              :session_id,       # String | nil
              :data,             # Hash - raw `result` payload as emitted by the CLI
              :original_error    # ProcessError | nil - the bare exit error this replaced
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
| `CLIConnectionError` | Connection issues — including every write after a stdin write was cancelled mid-frame (the connection is unusable from then on — reconnect), and `ClaudeAgentSDK.ask` when the stream ends without a `ResultMessage` |
| `ControlRequestTimeoutError` | Control protocol timeout (configurable via env var) |
| `CLINotFoundError` | Claude Code not installed |
| `ConfigDirError` | A local-disk session API (`list_sessions`, `get_session_*`, `rename_session`, ...) could not locate the Claude config directory: `CLAUDE_CONFIG_DIR` is unset and there is no usable home directory (`HOME` unset with no passwd entry, as under `docker --user` in a minimal image, or an empty/relative `HOME`). Set `CLAUDE_CONFIG_DIR` |
| `ProcessError` | Process failed (includes `exit_code` and `stderr`) — also raised when the CLI is still running 5s after closing stdout and the SDK had to terminate it |
| `ResultError` | Run ended on a terminal error result (subclasses `ProcessError`; adds `subtype`, `errors`, `api_error_status`, `terminal_reason`, ...) — rescue it first |
| `CLIJSONDecodeError` | JSON parsing issues — including stdout ending mid-frame (a truncated final message; `line` holds the partial frame) |
| `MessageParseError` | Message parsing issues |

See [lib/claude_agent_sdk/errors.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/lib/claude_agent_sdk/errors.rb) for all error types.
