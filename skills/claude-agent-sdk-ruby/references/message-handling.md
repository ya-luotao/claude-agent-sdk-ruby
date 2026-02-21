# Message handling (claude-agent-sdk)

Use these patterns to consume messages yielded by `ClaudeAgentSDK.query` and `ClaudeAgentSDK::Client#receive_messages`.

## Message types you will see

- `ClaudeAgentSDK::UserMessage` (has `uuid` for rewind checkpoints when enabled)
- `ClaudeAgentSDK::AssistantMessage` (has `content` blocks)
- `ClaudeAgentSDK::SystemMessage` (metadata/events)
- `ClaudeAgentSDK::ResultMessage` (end-of-turn marker with `result`, `structured_output`, `total_cost_usd`, `session_id`)
- `ClaudeAgentSDK::StreamEvent` (partial updates; only if enabled)

## Content block types

- `ClaudeAgentSDK::TextBlock` — text content (`.text`)
- `ClaudeAgentSDK::ThinkingBlock` — extended thinking (`.thinking`, `.signature`)
- `ClaudeAgentSDK::ToolUseBlock` — tool call (`.id`, `.name`, `.input`)
- `ClaudeAgentSDK::ToolResultBlock` — tool result (`.tool_use_id`, `.content`, `.is_error`)
- `ClaudeAgentSDK::UnknownBlock` — forward-compatible fallback for unrecognized types like `document` (PDF) or `image` (`.type`, `.data`); use `is_a?` filtering to skip gracefully

## Forward compatibility (v0.7.2+)

The SDK handles unknown types gracefully:
- Unknown content block types → `UnknownBlock` (preserves raw data in `.data`)
- Unknown message types → `nil` (skipped by callers)

This means newer CLI versions won't crash older SDK versions. Filter content blocks with `is_a?` checks, and unknown types are silently skipped:

```ruby
message.content.each do |block|
  case block
  when ClaudeAgentSDK::TextBlock
    puts block.text
  when ClaudeAgentSDK::ToolUseBlock
    puts "Tool: #{block.name}"
  when ClaudeAgentSDK::UnknownBlock
    # Access raw data if needed: block.type, block.data
  end
end
```

## Extract assistant text

```ruby
def assistant_text(message)
  return "" unless message.is_a?(ClaudeAgentSDK::AssistantMessage)

  message.content
    .select { |b| b.is_a?(ClaudeAgentSDK::TextBlock) }
    .map(&:text)
    .join("\n\n")
end
```

## Handle tool calls

```ruby
def tool_uses(message)
  return [] unless message.is_a?(ClaudeAgentSDK::AssistantMessage)

  message.content.select { |b| b.is_a?(ClaudeAgentSDK::ToolUseBlock) }
end
```

Tool results arrive as `ClaudeAgentSDK::ToolResultBlock` content blocks.

## Stop at the end of a turn

When using `Client#receive_response`, stop when you see `ClaudeAgentSDK::ResultMessage`.

```ruby
client.receive_response do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    puts assistant_text(message)
  when ClaudeAgentSDK::ResultMessage
    puts "Cost: $#{message.total_cost_usd}" if message.total_cost_usd
    puts "Session: #{message.session_id}"
    puts "Structured: #{message.structured_output.inspect}" if message.structured_output
  end
end
```

## Capture UUIDs for rewind

If `enable_file_checkpointing` is enabled, the CLI populates `UserMessage#uuid`. Store UUIDs if you plan to call `Client#rewind_files(uuid)`.
