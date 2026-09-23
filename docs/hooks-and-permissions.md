# Hooks & Permission Callbacks

## Hooks

A **hook** is a Ruby proc/lambda that the Claude Code *application* (*not* Claude) invokes at specific points of the Claude agent loop. Hooks provide deterministic processing and automated feedback for Claude. Read more in [Claude Code Hooks Reference](https://docs.anthropic.com/en/docs/claude-code/hooks).

### Supported Events

All hook input objects include common fields like `session_id`, `transcript_path`, `cwd`, and `permission_mode`.

- `PreToolUse` → `PreToolUseHookInput` (`tool_name`, `tool_input`, `tool_use_id`)
- `PostToolUse` → `PostToolUseHookInput` (`tool_name`, `tool_input`, `tool_response`, `tool_use_id`)
- `PostToolUseFailure` → `PostToolUseFailureHookInput` (`tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt`)
- `UserPromptSubmit` → `UserPromptSubmitHookInput` (`prompt`)
- `Stop` → `StopHookInput` (`stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons`)
- `SubagentStop` → `SubagentStopHookInput` (`stop_hook_active`, `agent_id`, `agent_transcript_path`, `agent_type`, `last_assistant_message`, `background_tasks`, `session_crons`)
- `PreCompact` → `PreCompactHookInput` (`trigger`, `custom_instructions`)
- `Notification` → `NotificationHookInput` (`message`, `title`, `notification_type`)
- `SubagentStart` → `SubagentStartHookInput` (`agent_id`, `agent_type`)
- `PermissionRequest` → `PermissionRequestHookInput` (`tool_name`, `tool_input`, `permission_suggestions`)

`tool_input` (and the `input` a [permission callback](#permission-callbacks) receives) is the CLI's Hash passed through unchanged, so its keys are Symbols spelled as on the wire: `tool_input[:command]`, `input[:file_path]`. See [Hash keys](types.md#hash-keys).

All 27 hook events have typed input classes. See [`ClaudeAgentSDK::HOOK_EVENTS`](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/lib/claude_agent_sdk/types.rb) and [examples/lifecycle_hooks_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/lifecycle_hooks_example.rb).

`background_tasks` and `session_crons` are optional arrays of raw CLI hashes.
`nil` means the CLI did not provide a snapshot; `[]` means it provided an empty
one. Nested keys are passed through unchanged (Symbols on the live transport).
Both snapshots belong to the **parent session**, even on `SubagentStop`; they
are not a complete list of foreground and background agents. A task disappearing
from a background snapshot does not establish its terminal status, and a
SubagentStop hook can itself keep the subagent running. See [subagent capabilities](subagents.md).

### Example: Blocking Dangerous Commands

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  bash_hook = lambda do |input, _tool_use_id, _context|
    return {} unless input.respond_to?(:tool_name) && input.tool_name == 'Bash'

    tool_input = input.tool_input || {}
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

### Hook cancellation

Dispatched hooks receive `HookContext#request_id` and `HookContext#signal`, using
the same [cooperative cancellation API](#permission-request-cancellation) as
permission callbacks. The request ID identifies this invocation, not the hook's
registered callback ID or the tool invocation.

CLI cancellation, EOF, disconnect, callback failure, and `HookMatcher#timeout`
invalidate the signal. Successful hook completion does not. A default `:thread`
hook waiting on external work must poll `signal.cancelled?` or use a bounded
wait; timeout does not forcibly stop its thread. Late hook output is discarded.
Inline hooks may unwind before the signal is marked cancelled on timeout, so
always clean up in `ensure`, regardless of the signal's value there. Do not
swallow cancellation exceptions. Observe the signal; `cancel` is SDK-internal.

## Permission Callbacks

A **permission callback** is a Ruby proc/lambda that allows you to programmatically control tool execution. This gives you fine-grained control over what tools Claude can use and with what inputs.

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  permission_callback = lambda do |tool_name, input, context|
    return ClaudeAgentSDK::PermissionResultAllow.new if tool_name == 'Read'

    if tool_name == 'Write'
      file_path = input[:file_path]
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

### Permission request cancellation

Dispatched `can_use_tool` callbacks receive `context.request_id` (the control
request ID, distinct from `tool_use_id`) and `context.signal`, a
`ClaudeAgentSDK::CancellationSignal`:

- `signal.cancelled?` checks whether the request is no longer actionable.
- `signal.wait(timeout: seconds)` waits for cancellation, returning `true` on
  cancellation or `false` on timeout. Omit the timeout to wait indefinitely.
  Multiple waiters and callers arriving after cancellation all observe it.
- The SDK signals cancellation on a CLI `control_cancel_request`, disconnect,
  EOF/transport failure, or an unsuccessful callback dispatch. Normal allow/deny
  completion does not cancel the signal. Stop waiting once the callback returns.

The signal is safe on worker threads and Async fibers. Cancellation is
cooperative: default `:thread` callbacks are **not** forcibly terminated. Poll
the signal while waiting for an application's decision and remove the pending
request in `ensure`. Inline callbacks may instead unwind via `Async::Stop`;
let it propagate. The SDK never sends a late callback decision as an allow
response after it has observed cancellation.

For example, if the host has registered a separate `Thread::Queue` for this
request and its decision handler pushes a `PermissionResultAllow` or
`PermissionResultDeny` into it:

```ruby
begin
  loop do
    break ClaudeAgentSDK::PermissionResultDeny.new(message: 'Request cancelled') if context.signal.cancelled?
    decision = decision_queue.pop(timeout: 0.1)
    break decision if decision
  end
ensure
  # Unregister context.request_id from the host's pending decisions here.
end
```

Do not use an unbounded blocking `gets`/queue wait for a human decision without
observing cancellation, or auto-approve when the decision service disconnects.
Hooks have the same signal API; see [hook cancellation](#hook-cancellation).

### Shadowing: when `can_use_tool` never runs

`can_use_tool` is only consulted when the CLI's permission ladder lands on
"ask". Anything that auto-approves a tool call earlier means the callback
never fires for it — a security callback can silently become dead code:

- `permission_mode: 'bypassPermissions'` auto-approves everything (except
  explicit deny rules), fully shadowing the callback.
- An `allowed_tools` entry that allows a whole tool — `'Write'`, `'Write()'`,
  `'Write(*)'`, or the bare `Skill` implied by `skills: 'all'` — shadows the
  callback for that tool. A real specifier like `'Bash(ls:*)'` only
  auto-approves matching invocations.
- Allow rules in settings files shadow the callback the same way, but are not
  visible to the SDK at construction time.

The SDK emits an advisory warning to stderr from `query()` / `Client#connect`
when it can see the shadowing (once per distinct message per process). It
never raises — shadowing can be intentional, e.g. a callback used solely for
tools outside `allowed_tools`. To gate every tool call including
auto-approved ones, use a `PreToolUse` hook instead (note that a `PreToolUse`
hook returning an allow decision also skips this callback).

## When a callback raises

An exception raised inside a hook or a `can_use_tool` callback fails that
control request: the CLI receives an error response carrying the exception
message, and the session carries on with later requests. The request's
cancellation signal is invalidated, as for any other callback failure.

`exit`, `Interrupt` and other signal exceptions are never swallowed. If one
is raised while a callback runs (by the callback itself, or a real Ctrl-C /
`SIGTERM` arriving while an `:inline` callback runs on the main thread), the
CLI first gets the same error response, naming the exception class
(`"SystemExit: exit"`, `"Interrupt"`), and then the exception propagates as
Ruby normally would: `exit 3` ends the process with status 3, and Ctrl-C
interrupts it. This holds in both `:thread` and `:inline` scheduling, and also
when a `:thread` hook calls `exit` after its `HookMatcher#timeout` has already
expired. A `callback_wrapper` sees the exception wrapped in an internal
`StandardError` whose `#cause` is the original, so ensure-based wrappers (such
as `Rails.application.executor.wrap`) still clean up. The original is raised
again after the wrapper returns, even if the wrapper swallows the error.
Cancellation (`control_cancel_request`, `HookMatcher#timeout`, disconnect)
still propagates as before.
