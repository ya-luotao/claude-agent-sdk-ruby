# Types Reference

See [lib/claude_agent_sdk/types/](https://github.com/ya-luotao/claude-agent-sdk-ruby/tree/main/lib/claude_agent_sdk/types) for complete type definitions (one file per area; `types.rb` loads them all).

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
method call such as `msg.nope` raises `NoMethodError`. These accessors reach a type's
**attributes** only; any other method (`to_h`, `freeze`, ...) counts as undefined —
see [Attributes Only](#attributes-only).

`#[]=` assigns through the attribute's setter, with the same name
normalization, and returns the assigned value:

```ruby
msg[:result] = 'edited' # same as msg.result = 'edited'
```

- It **changes the object you received**. Messages are not frozen or copied
  on delivery, so a change is visible to anything else holding the same
  object (for example an observer that received it before your block did).
  Copy first if you need the original.
- A name the type does not define is ignored on the types the SDK parses from
  CLI output. `ClaudeAgentOptions` raises `ArgumentError` for an unknown key (as
  its constructor and `dup_with` do), and so do the value types you build and
  pass in — see [Unknown Keys](#unknown-keys).
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
          StreamEvent | RateLimitEvent | ConversationResetMessage |
          ToolProgressMessage | AuthStatusMessage | ToolUseSummaryMessage |
          PromptSuggestionMessage
```

This is everything the block of `query()`, `ask`, `Client#receive_messages` and
`Client#receive_response` can receive. `SystemMessage` stands for its typed
subclasses as well (`InitMessage`, `TaskStartedMessage`, ...; see
[System and progress messages](#system-and-progress-messages)): each of them
`is_a?(SystemMessage)`. The other ten classes share nothing but the SDK's
`Type` base class.

A message type this SDK version does not know is skipped before it reaches
your block, and a `system` message with an unknown `subtype` arrives as a plain
`SystemMessage` (`subtype` and `data` set). Give a `case` over messages an
`else` that ignores the rest: a later gem release can add a class to this
list.

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
                :error,              # String | nil - see ASSISTANT_MESSAGE_ERRORS below
                :usage,              # Hash | nil - Token usage info from the API response
                :message_id,         # String | nil - the API message id
                :stop_reason,        # String | nil
                :session_id,         # String | nil
                :uuid                # String | nil - UUID of this message in the transcript
end
```

`error` is passed through from the CLI. The values this SDK version knows are
in `ASSISTANT_MESSAGE_ERRORS`: `authentication_failed`, `billing_error`,
`rate_limit`, `invalid_request`, `server_error`, `max_output_tokens`,
`unknown`. A newer CLI can send others.

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

### System and progress messages

The remaining typed messages. An attribute the CLI did not send reads `nil`
(except `RateLimitEvent#rate_limit_info`, which is then an empty
`RateLimitInfo`). The first twelve are `SystemMessage` subclasses (wire `type`
is `system`), so they also have `subtype` and `data`, the whole frame as a
Symbol-keyed Hash; the last six are message types of their own.

| Class | Wire type | Attributes | Notes |
|-------|-----------|------------|-------|
| `InitMessage` | `system` / `init` | `uuid`, `session_id`, `model`, `cwd`, `tools`, `mcp_servers`, `agents`, `skills`, `plugins`, `slash_commands`, `permission_mode`, `claude_code_version`, `api_key_source`, `betas`, `output_style`, `fast_mode_state` | Start of every turn, with the session as the CLI sees it (so a multi-query `Client` session receives one per query) |
| `CompactBoundaryMessage` | `system` / `compact_boundary` | `uuid`, `session_id`, `compact_metadata` (a `CompactMetadata`: `pre_tokens`, `post_tokens`, `trigger`, `preserved_segment`, `custom_instructions`) | Context compaction completed |
| `StatusMessage` | `system` / `status` | `uuid`, `session_id`, `status`, `permission_mode` | Compacting status, permission mode changes |
| `APIRetryMessage` | `system` / `api_retry` | `uuid`, `session_id`, `attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error` | The CLI is retrying an API request |
| `LocalCommandOutputMessage` | `system` / `local_command_output` | `uuid`, `session_id`, `content` | Output of a local command |
| `HookStartedMessage` | `system` / `hook_started` | `uuid`, `session_id`, `hook_id`, `hook_name`, `hook_event` | Hook lifecycle; `include_hook_events: true` asks the CLI for all of these |
| `HookProgressMessage` | `system` / `hook_progress` | the `HookStartedMessage` attributes, `stdout`, `stderr`, `output` | |
| `HookResponseMessage` | `system` / `hook_response` | the `HookProgressMessage` attributes, `exit_code`, `outcome` (`'success'`, `'error'`, `'cancelled'`) | |
| `SessionStateChangedMessage` | `system` / `session_state_changed` | `uuid`, `session_id`, `state` (`'idle'`, `'running'`, `'requires_action'`) | Reaches your block only with `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1` in `env` |
| `FilesPersistedMessage` | `system` / `files_persisted` | `uuid`, `session_id`, `files`, `failed`, `processed_at` | |
| `ElicitationCompleteMessage` | `system` / `elicitation_complete` | `uuid`, `session_id`, `mcp_server_name`, `elicitation_id` | |
| `MirrorErrorMessage` | `system` / `mirror_error` | `uuid`, `session_id`, `error`, `key` | Produced by the SDK, not the CLI: a `session_store` mirror batch was dropped (see [Sessions](sessions.md#mirroring-to-a-sessionstore)) |
| `ToolProgressMessage` | `tool_progress` | `uuid`, `session_id`, `tool_use_id`, `tool_name`, `parent_tool_use_id`, `elapsed_time_seconds`, `task_id` | Progress of a running tool call |
| `ToolUseSummaryMessage` | `tool_use_summary` | `uuid`, `session_id`, `summary`, `preceding_tool_use_ids` | |
| `AuthStatusMessage` | `auth_status` | `uuid`, `session_id`, `is_authenticating`, `output`, `error` | |
| `PromptSuggestionMessage` | `prompt_suggestion` | `uuid`, `session_id`, `suggestion` | |
| `StreamEvent` | `stream_event` | `uuid`, `session_id`, `event` (the raw API stream event, Symbol keys), `parent_tool_use_id` | Partial message chunks; only with `include_partial_messages: true` |
| `RateLimitEvent` | `rate_limit_event` | `uuid`, `session_id`, `rate_limit_info` (a `RateLimitInfo`: `status`, `resets_at`, `rate_limit_type`, `utilization`, `overage_status`, `overage_resets_at`, `overage_disabled_reason`, `raw`), `data` (the whole event) | Rate limit information changed |

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
                :origin,             # Hash | nil - origin of the triggering user message (see below)
                :deferred_tool_use   # DeferredToolUse | nil (see below)
end
```

`deferred_tool_use` is set when a `PreToolUse` hook answered a tool call with
`permissionDecision: 'defer'`: a `DeferredToolUse` with the `id`, `name` and
`input` of the call that was put off. The session can be resumed later to run
the deferred call.

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
ContentBlock = TextBlock | ThinkingBlock | ToolUseBlock | ToolResultBlock |
               ServerToolUseBlock | ServerToolResultBlock | UnknownBlock
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

### ServerToolUseBlock and ServerToolResultBlock

`ServerToolUseBlock` is a call to a tool that runs server-side (wire type
`server_tool_use`), and `ServerToolResultBlock` is the advisor tool's result
(wire type `advisor_tool_result`). An
[advisor](configuration.md#advisor-model) consultation shows up as a
`ServerToolUseBlock` named `'advisor'` and a `ServerToolResultBlock`. Any
other block type, a different server-side result included, arrives as an
`UnknownBlock`.

```ruby
class ServerToolUseBlock
  attr_accessor :id,    # String
                :name,  # String ('advisor', ...)
                :input  # Hash
end

class ServerToolResultBlock
  attr_accessor :tool_use_id,  # String
                :content,      # the result payload, as the CLI sent it
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
| `ClaudeAgentOptions` | Main configuration for queries and clients. Every option is listed in the [options reference](options.md) |
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
| `SDKSessionInfo` | Session metadata from `list_sessions` and `get_session_info` |
| `SessionMessage` | Single message from `get_session_messages` |
| `SandboxSettings` | Sandbox settings for isolated command execution. `ignore_violations` (which violations to ignore) is a plain Hash |
| `SandboxNetworkConfig` | Network configuration for sandbox |
| `SandboxFilesystemConfig` | Filesystem configuration for sandbox (`allow_write`, `deny_write`, `deny_read`, `allow_read`, `allow_managed_read_paths_only`) |
| `SystemPromptPreset` | System prompt preset configuration (`preset`, `append`, `exclude_dynamic_sections`, `snapshot`) |
| `SystemPromptCustom` | Custom system prompt configuration — the object form of a String prompt, so `snapshot` can be set alongside it |
| `SystemPromptFile` | System prompt loaded from a file path |
| `ToolsPreset` | Tools preset configuration for base tools selection |

### Unknown Keys

`ClaudeAgentOptions` and the value types you build and pass *in* raise `ArgumentError` on a key they do not define, naming the class, the key and the keys it accepts:

```ruby
ClaudeAgentSDK::HookMatcher.new(matchr: 'Bash', hooks: [check])
# ArgumentError: ClaudeAgentSDK::HookMatcher: unknown attribute :matchr (known: hooks, matcher, timeout)
```

This covers `.new` and `#[]=` on:

- option values: `AgentDefinition`, `SandboxSettings`, `SandboxNetworkConfig`, `SandboxFilesystemConfig`, `ThinkingConfigAdaptive` / `Enabled` / `Disabled`, `TaskBudget`, `SystemPromptPreset` / `Custom` / `File`, `ToolsPreset`, `SdkPluginConfig`, `McpStdioServerConfig`, `McpSSEServerConfig`, `McpHttpServerConfig`, `McpSdkServerConfig`
- `HookMatcher` and hook outputs: `SyncHookJSONOutput`, `AsyncHookJSONOutput`, every `*HookSpecificOutput`
- `PermissionResultAllow`, `PermissionResultDeny`, `PermissionUpdate`, `PermissionRuleValue`

A nested value is checked as its own type: `PermissionUpdate.new(rules: [{ rule_contnt: 'x' }])` raises naming `PermissionRuleValue`.

Accepted: Symbol or String keys, snake_case or camelCase spellings, and the fixed discriminator a type sets itself (`type`, `hook_event_name`, `behavior`), so on a type that defines its own `#to_h` (the MCP server configs, `SandboxSettings`, the system prompt types, the hook outputs, ...) `klass.new(value.to_h)` round-trips. Types the SDK parses from CLI output (messages, content blocks, hook inputs, `ToolPermissionContext`, the MCP status types) stay lenient, so a field added by a newer CLI is ignored rather than raising, and so does every construction through `.from_hash` or `.wrap`. Use those two for data you did not write yourself, such as a Hash deserialized from the CLI or from storage.

(0.37 printed a one-time warning here and ignored the key; 1.0 raises. See [UPGRADING-1.0.md](../UPGRADING-1.0.md).)

### Attributes Only

`#[]`, `#[]=` and the camelCase readers (`msg[:session_id]`, `msg['sessionId']`, `msg.sessionId`) are public API for a type's **attributes**: the fields it declares, plus predicates such as `options.forkSession?`. Methods your own code adds to a subclass (an `attr_accessor`, a hand-written reader or setter, a mixin's accessors, a singleton method) count as attributes too.

A name that is not an attribute behaves like an undefined one: `#[]` returns `nil`, `#[]=` ignores it (on the strict types above it raises `ArgumentError`), a camelCase call raises `NoMethodError`, and `respond_to?` answers `false`. So `msg[:to_h]` is `nil`, `msg['freeze']` does not freeze the message, and `msg.toH` raises; call the method directly instead (`msg.to_h`). `UserMessage#text` and `AssistantMessage#text` are convenience methods, not attributes.

(Through 0.37 these accessors reached any public method, with a one-time warning in 0.37.)

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
