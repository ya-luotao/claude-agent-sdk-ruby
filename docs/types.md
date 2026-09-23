# Types Reference

See [lib/claude_agent_sdk/types/](https://github.com/ya-luotao/claude-agent-sdk-ruby/tree/main/lib/claude_agent_sdk/types) for complete type definitions (one file per area; `types.rb` loads them all).

## Message Types

```ruby
# Union type of all possible messages
Message = UserMessage | AssistantMessage | SystemMessage | ResultMessage |
          StreamEvent | RateLimitEvent | ConversationResetMessage
```

### UserMessage

User input message.

```ruby
class UserMessage
  attr_accessor :content,            # String | Array<ContentBlock>
                :uuid,               # String | nil - Unique ID for rewind support
                :parent_tool_use_id, # String | nil
                :tool_use_result,    # Hash | nil - Tool result data when message is a tool response
                :origin              # Hash | nil - message provenance (see Message Origin below)
end
```

### AssistantMessage

Assistant response message with content blocks.

```ruby
class AssistantMessage
  attr_accessor :content,            # Array<ContentBlock>
                :model,              # String
                :parent_tool_use_id, # String | nil
                :error,              # String | nil ('authentication_failed', 'billing_error', 'rate_limit', 'invalid_request', 'server_error', 'unknown')
                :usage               # Hash | nil - Token usage info from the API response
end
```

### SystemMessage

System message with metadata. Task lifecycle events are typed subclasses.

```ruby
class SystemMessage
  attr_accessor :subtype,  # String ('init', 'task_started', 'task_progress', 'task_notification', 'task_updated', etc.)
                :data      # Hash
end

# Typed subclasses (all inherit from SystemMessage, so is_a?(SystemMessage) still works)
class TaskStartedMessage < SystemMessage
  attr_accessor :task_id, :description, :uuid, :session_id, :tool_use_id, :task_type, :workflow_name, :prompt,
                :subagent_type,    # String | nil
                :is_backgrounded,  # true (background) | false (foreground, tool call blocking) | nil (not reported)
                :spawn_depth,      # Integer | nil (1 = top-level subagent)
                :skip_transcript,  # true | false | nil — hide from the inline transcript (a tasks panel may still show it)
                :ambient           # true | false | nil — not activity; exclude from activity indicators
end

class TaskProgressMessage < SystemMessage
  attr_accessor :task_id, :description, :usage, :uuid, :session_id, :tool_use_id, :last_tool_name, :summary,
                :subagent_type     # String | nil
end

class TaskNotificationMessage < SystemMessage
  attr_accessor :task_id, :status, :output_file, :summary, :uuid, :session_id, :tool_use_id, :usage,
                :reason,           # 'worker_restart' | nil
                :resource_links,   # Array<Hash> | nil — raw, symbol keys with wire spelling (:uri, :name, :mimeType, ...)
                :skip_transcript,  # true | false | nil — same meaning as on TaskStartedMessage
                :ambient           # true | false | nil — the SDK never filters on either flag
end

# Background task lifecycle state change. `status` is derived from patch["status"].
# A terminal task can arrive *only* as a TaskUpdatedMessage (no TaskNotificationMessage) —
# e.g. a TaskStop-killed task reports status "killed" here. Clear tracked task IDs on a
# terminal status (see TERMINAL_TASK_STATUSES) from *either* message.
# The other patch readers are derived the same way; nil means "not in this patch".
class TaskUpdatedMessage < SystemMessage
  attr_accessor :task_id, :patch, :status, :uuid, :session_id,
                :description, :error, :end_time, :total_paused_ms,
                :is_backgrounded   # true = moved to the background | false | nil (patch does not mention it)
end

# Full set of live background tasks; REPLACE semantics (swap your set for each payload).
class BackgroundTasksChangedMessage < SystemMessage
  attr_accessor :tasks,            # Array<Hash> — raw { task_id:, task_type:, description:, ambient: }
                :uuid, :session_id
end

# A tool call auto-denied without an interactive prompt. Best-effort advisory, not a
# complete denial feed; ResultMessage#permission_denials is the authoritative record.
class PermissionDeniedMessage < SystemMessage
  attr_accessor :tool_name, :tool_use_id, :message, :uuid, :session_id,
                :agent_id,              # String | nil — subagent id for routing (NOT a permission request_id)
                :decision_reason_type,  # String | nil — open string ('classifier', 'asyncAgent', 'mode', 'rule', ...)
                :decision_reason        # String | nil
end
```

See [subagent capabilities](subagents.md) for the contracts behind these fields.

### ResultMessage

Final result message with cost and usage information.

```ruby
class ResultMessage
  attr_accessor :subtype,            # String
                :duration_ms,        # Integer
                :duration_api_ms,    # Integer
                :is_error,           # Boolean
                :num_turns,          # Integer
                :session_id,         # String
                :stop_reason,        # String | nil ('end_turn', 'max_tokens', 'stop_sequence')
                :total_cost_usd,     # Float | nil
                :usage,              # Hash | nil
                :result,             # String | nil (final text result)
                :structured_output,  # Hash | nil (when using output_format)
                :model_usage,        # Hash | nil — { model_name => usage Hash } (see below)
                :permission_denials, # Array | nil
                :errors,             # Array<String> | nil (present on error subtypes)
                :uuid,               # String | nil
                :fast_mode_state,    # String | nil ('off', 'cooldown', 'on')
                :api_error_status,   # Integer | nil (HTTP status on api_error subtype)
                :terminal_reason,    # String | nil (see below)
                :origin              # Hash | nil - origin of the triggering user message (see below)
end
```

`terminal_reason` says why the query loop ended (`"completed"`, `"max_turns"`,
`"aborted_streaming"`, ...). `"aborted_streaming"` / `"aborted_tools"` mean the
turn was cancelled via `Client#interrupt`. `nil` when the CLI did not report
one (older CLIs, or a result that bypassed the query loop such as a local
slash command).

`model_usage` values are passed through verbatim from the CLI, so their keys
are camelCase (the TypeScript/Python SDKs' `ModelUsage` shape): `inputTokens`,
`outputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`,
`webSearchRequests`, `costUSD`, `contextWindow`, `maxOutputTokens`, plus
optional `canonicalModel` (canonical id used for the pricing lookup, which can
differ from the raw model-string key for provider-specific ids/aliases) and
`provider` (`'firstParty'`, `'bedrock'`, `'vertex'`, ...).

## Message Origin

`UserMessage#origin` and `ResultMessage#origin` carry the provenance of a
user-role turn. In streaming/`Client` mode one connection interleaves the turns
your application sends with turns the session injects on its own — background
task notifications, fired scheduled-task prompts, MCP channel messages,
messages relayed from peer sessions. `origin` tells them apart:

```ruby
if result.origin.nil? || result.origin[:kind] == 'human'
  # a turn this application submitted
elsif result.origin[:kind] == 'task-notification'
  # follow-up turn driven by a background task
end
```

The Hash is passed through from the CLI **verbatim**, so:

- **Keys are Symbols**, and non-`kind` keys keep the CLI's camelCase spelling —
  `origin[:fromSession]`, `origin[:senderTaskId]`, `origin[:verifiedPeerPid]`.
  (The Python SDK's equivalent is string-keyed; do not port `origin["kind"]`
  literally.)
- Keys this SDK version does not model still reach you, so newer CLI origin
  kinds stay visible.
- Anything that is not an object with a String `kind` reads as `nil`.

Only `kind` is always present. Known kinds — treat anything unrecognized as
"not human":

`human`, `channel`, `peer`, `task-notification`, `coordinator`,
`unclassified`, `observer`, `auto-continuation`, `observer-activity`

For `kind == 'task-notification'`, `origin[:subkind]` may be
`scheduled-trigger` (a scheduled task's prompt fired) or `peer-send-message`
(a message from another of your sessions); it is absent for ordinary
background-task notifications.

`nil` means the CLI did not attribute the message. Prompts you send through
`ClaudeAgentSDK.query` or `Client#query` arrive that way unless you stamp
`origin: { kind: 'human' }` on the message Hash yourself — only the `human`
kind is honored from an SDK host. Tool-result messages never carry an origin.

### ConversationResetMessage

Emitted when the session's conversation is replaced without ending the
connection — after `/clear`, or any other flow that discards the transcript
mid-session.

```ruby
class ConversationResetMessage
  attr_accessor :new_conversation_id, # String - id of the fresh conversation
                :uuid,                # String - unique ID of this message
                :session_id           # String - the session that was reset
end
```

A reset clears the conversation history **and zeroes the running totals**
reported on subsequent `ResultMessage` objects (`total_cost_usd`, and the
rest). If you accumulate those across a long-lived session, snapshot them when
this message arrives.

`new_conversation_id` is **not** the `session_id` of subsequent messages — it
is an opaque id for keying an empty transcript in a UI (and for discarding a
cached session title). Read the new session id from the next message.

## Content Block Types

```ruby
# Union type of all content blocks
ContentBlock = TextBlock | ThinkingBlock | ToolUseBlock | ToolResultBlock | UnknownBlock
```

### TextBlock

```ruby
class TextBlock
  attr_accessor :text  # String
end
```

### ThinkingBlock

For models with extended thinking capability.

```ruby
class ThinkingBlock
  attr_accessor :thinking,  # String
                :signature  # String
end
```

### ToolUseBlock

Tool use request block.

```ruby
class ToolUseBlock
  attr_accessor :id,    # String
                :name,  # String
                :input  # Hash
end
```

### ToolResultBlock

Tool execution result block.

```ruby
class ToolResultBlock
  attr_accessor :tool_use_id,  # String
                :content,      # String | Array<Hash> | nil
                :is_error      # Boolean | nil
end
```

### UnknownBlock

Generic content block for types the SDK doesn't explicitly handle (e.g., `document` for PDFs, `image` for inline images). Preserves the raw data for forward compatibility with newer CLI versions.

```ruby
class UnknownBlock
  attr_accessor :type,  # String — the original block type (e.g., "document")
                :data   # Hash — the full raw block hash
end
```

## Configuration Types

| Type | Description |
|------|-------------|
| `Configuration` | Global defaults via `ClaudeAgentSDK.configure` block |
| `ClaudeAgentOptions` | Main configuration for queries and clients |
| `HookMatcher` | Hook configuration with matcher pattern and timeout |
| `PermissionResultAllow` | Permission callback result to allow tool use |
| `PermissionResultDeny` | Permission callback result to deny tool use |
| `AgentDefinition` | Agent definition with description, prompt, tools, model, skills, memory, mcp_servers |
| `ThinkingConfigAdaptive` | Adaptive thinking mode (CLI dynamically adjusts budget) |
| `ThinkingConfigEnabled` | Enabled thinking with explicit `budget_tokens` |
| `ThinkingConfigDisabled` | Disabled thinking |
| `SdkMcpTool` | SDK MCP tool definition with name, description, input_schema, handler, annotations |
| `McpStdioServerConfig` | MCP server config for stdio transport |
| `McpSSEServerConfig` | MCP server config for SSE transport |
| `McpHttpServerConfig` | MCP server config for HTTP transport |
| `SdkPluginConfig` | SDK plugin configuration |
| `McpServerStatus` | Status of a single MCP server connection (with `.parse`) |
| `McpStatusResponse` | Response from `get_mcp_status` containing all server statuses (with `.parse`) |
| `McpServerInfo` | MCP server name and version |
| `McpToolInfo` | MCP tool name, description, and annotations |
| `McpToolAnnotations` | MCP tool annotation hints (`read_only`, `destructive`, `open_world`) |
| `TaskUsage` | Typed usage data (`total_tokens`, `tool_uses`, `duration_ms`) with `from_hash` factory |
| `SDKSessionInfo` | Session metadata from `list_sessions` |
| `SessionMessage` | Single message from `get_session_messages` |
| `SandboxSettings` | Sandbox settings for isolated command execution |
| `SandboxNetworkConfig` | Network configuration for sandbox |
| `SandboxIgnoreViolations` | Configure which sandbox violations to ignore |
| `SystemPromptPreset` | System prompt preset configuration (`preset`, `append`, `exclude_dynamic_sections`, `snapshot`) |
| `SystemPromptCustom` | Custom system prompt configuration — the object form of a String prompt, so `snapshot` can be set alongside it |
| `SystemPromptFile` | System prompt loaded from a file path |
| `ToolsPreset` | Tools preset configuration for base tools selection |

## Constants

| Constant | Description |
|----------|-------------|
| `SDK_BETAS` | Available beta features (e.g., `"context-1m-2025-08-07"`) |
| `PERMISSION_MODES` | Available permission modes |
| `SETTING_SOURCES` | Available setting sources |
| `HOOK_EVENTS` | Available hook events |
| `ASSISTANT_MESSAGE_ERRORS` | Possible error types in AssistantMessage |
| `TASK_NOTIFICATION_STATUSES` | Task lifecycle notification statuses (`completed`, `failed`, `stopped`) |
| `TASK_UPDATED_STATUSES` | `task_updated` patch statuses (`pending`, `running`, `paused`, `completed`, `failed`, `killed`) |
| `TERMINAL_TASK_STATUSES` | Statuses meaning a task has finished — spans both vocabularies (`completed`, `failed`, `stopped`, `killed`); clear active-task tracking on any of these |
| `MCP_SERVER_CONNECTION_STATUSES` | MCP server connection states (`connected`, `failed`, `needs-auth`, `pending`, `disabled`) |
| `EFFORT_LEVELS` | Effort levels (`low`, `medium`, `high`, `xhigh`, `max`) |
