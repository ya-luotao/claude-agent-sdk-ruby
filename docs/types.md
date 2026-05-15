# Types Reference

See [lib/claude_agent_sdk/types.rb](../lib/claude_agent_sdk/types.rb) for complete type definitions.

## Message Types

```ruby
# Union type of all possible messages
Message = UserMessage | AssistantMessage | SystemMessage | ResultMessage
```

### UserMessage

User input message.

```ruby
class UserMessage
  attr_accessor :content,            # String | Array<ContentBlock>
                :uuid,               # String | nil - Unique ID for rewind support
                :parent_tool_use_id, # String | nil
                :tool_use_result     # Hash | nil - Tool result data when message is a tool response
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
  attr_accessor :subtype,  # String ('init', 'task_started', 'task_progress', 'task_notification', etc.)
                :data      # Hash
end

# Typed subclasses (all inherit from SystemMessage, so is_a?(SystemMessage) still works)
class TaskStartedMessage < SystemMessage
  attr_accessor :task_id, :description, :uuid, :session_id, :tool_use_id, :task_type
end

class TaskProgressMessage < SystemMessage
  attr_accessor :task_id, :description, :usage, :uuid, :session_id, :tool_use_id, :last_tool_name
end

class TaskNotificationMessage < SystemMessage
  attr_accessor :task_id, :status, :output_file, :summary, :uuid, :session_id, :tool_use_id, :usage
end
```

### ResultMessage

Final result message with cost and usage information.

```ruby
class ResultMessage
  attr_accessor :subtype,           # String
                :duration_ms,       # Integer
                :duration_api_ms,   # Integer
                :is_error,          # Boolean
                :num_turns,         # Integer
                :session_id,        # String
                :stop_reason,       # String | nil ('end_turn', 'max_tokens', 'stop_sequence')
                :total_cost_usd,    # Float | nil
                :usage,             # Hash | nil
                :result,            # String | nil (final text result)
                :structured_output  # Hash | nil (when using output_format)
end
```

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
| `SystemPromptPreset` | System prompt preset configuration |
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
| `MCP_SERVER_CONNECTION_STATUSES` | MCP server connection states (`connected`, `failed`, `needs-auth`, `pending`, `disabled`) |
| `EFFORT_LEVELS` | Effort levels (`low`, `medium`, `high`, `xhigh`, `max`) |
