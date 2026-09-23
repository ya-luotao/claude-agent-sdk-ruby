# Types Reference

See [lib/claude_agent_sdk/types.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/lib/claude_agent_sdk/types.rb) for complete type definitions.

## Hash keys

Where the SDK hands you a plain Hash rather than a typed object, its key form
depends on where the data came from. One rule covers every case:

| Source | Key form | Examples |
|--------|----------|----------|
| The CLI's live stream-JSON, passed through as-is | **Symbols**, spelled exactly as on the wire | `UserMessage#origin`, `ResultMessage#origin`, `AssistantMessage#usage`, `ResultMessage#usage`, `ResultMessage#model_usage`, `ResultMessage#structured_output`, `UserMessage#tool_use_result`, `SystemMessage#data`, hook `tool_input`, the `can_use_tool` `input`, SDK MCP tool and prompt `args`, `Client#mcp_status`, `Client#context_usage` |
| Transcripts read from disk or a `SessionStore` | **Strings**, spelled as in the JSONL | `SessionMessage#message`, `get_subagent_metadata`, `SessionStore` keys and entries, `fold_session_summary` input and output |

"As on the wire" means the SDK does not rewrite key names. Structures the CLI
generates use camelCase (`origin[:fromSession]`, `model_usage` values'
`:inputTokens` / `:costUSD`, `client.mcp_status[:mcpServers]`), while objects
the CLI relays from the API keep their snake_case (`usage[:input_tokens]`).
Nesting follows the same rule all the way down, including keys that are data
rather than field names: `model_usage` is keyed by model-name Symbols
(`result.model_usage.each { |model, u| puts "#{model}: $#{u[:costUSD]}" }`).

The wrong key form reads as `nil` rather than raising, so look up the source
before indexing: `tool_input['command']` on a hook input, or
`meta[:toolUseId]` on subagent metadata, silently returns `nil`. The Python
SDK uses String keys everywhere; do not port its lookups literally.

The Symbol side of the rule relies on the transport parsing each line with
`JSON.parse(line, symbolize_names: true)`. The built-in
`SubprocessCLITransport` does; a [custom transport](client.md#custom-transport)
must too.

## Reading and writing attributes

The SDK's typed objects (messages, content blocks, hook inputs and outputs,
option objects: everything built on `ClaudeAgentSDK::Type`) accept the same
attribute name in several spellings. These accessors are public API:

```ruby
msg.session_id          # the attr_accessor
msg[:session_id]        # Symbol or String, snake_case or camelCase:
msg['session_id']       #   all four read the same attribute
msg[:sessionId]
msg['sessionId']
msg.sessionId           # camelCase reader (also answers respond_to?)
```

`#[]` returns `nil` for a name the type does not define, while a misspelled
method call such as `msg.nope` raises `NoMethodError`.

`#[]=` assigns through the attribute's setter, with the same name
normalization, and returns the assigned value:

```ruby
msg[:result] = 'edited' # same as msg.result = 'edited'
```

- It **changes the object you received**. Messages are not frozen or copied
  on delivery, so a change is visible to anything else holding the same
  object (for example an observer that received it before your block did).
  Copy first if you need the original.
- A name the type does not define is ignored, except on
  `ClaudeAgentOptions`, which raises `ArgumentError` for an unknown key (as its
  constructor and `dup_with` do).
- Discriminator fields (`type` on the MCP server and system-prompt configs,
  `behavior` on `PermissionResultAllow` / `PermissionResultDeny`,
  `hook_event_name` on hook inputs and outputs) are read-only, so
  assigning them has no effect.

Constructors accept the same spellings: `ResultMessage.new('sessionId' => 'abc')`
is equivalent to `ResultMessage.new(session_id: 'abc')`.

`SDKSessionInfo` and `SessionMessage` (returned by the session functions) are
currently plain classes, not `Type`s: use their snake_case accessors
(`info.session_id`); they have no `#[]`, `#[]=` or camelCase readers.

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

`model_usage` is passed through verbatim from the CLI (see [Hash keys](#hash-keys)):
it is keyed by model-name Symbols (`:"claude-sonnet-4-5"`), and each value's
keys are camelCase Symbols (the TypeScript/Python SDKs' `ModelUsage` shape): `inputTokens`,
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
| `McpStatusResponse` | Typed view of the `Client#mcp_status` / `#get_mcp_status` Hash: `McpStatusResponse.parse(client.mcp_status).mcp_servers` is an Array of `McpServerStatus`. The client itself returns the raw Hash (see [client.md](client.md#mcp-status-and-context-usage-return-hashes)) |
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
