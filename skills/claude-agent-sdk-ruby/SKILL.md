---
name: claude-agent-ruby
description: Implement or modify Ruby code that uses the claude-agent-sdk gem, including query() one-shot calls, Client-based interactive sessions, streaming input, option configuration, tools/permissions, hooks, SDK MCP servers, structured output, budgets, sandboxing, betas/tools presets, control-timeout handling, session resumption/rewind, session browsing (list_sessions/get_session_messages), task lifecycle messages, MCP server control (reconnect/toggle/stop), Rails integration, and error handling.
---

# Claude Agent SDK for Ruby

## Quick start

- Use `ClaudeAgentSDK.query` for one-shot prompts (unidirectional streaming).
- Use `ClaudeAgentSDK::Client` for interactive sessions (multiple turns, interrupt, hooks, permission callbacks, custom tools, runtime control APIs).
- Install prerequisites: Ruby 3.2+, Node.js, and Claude Code CLI.

```ruby
require 'claude_agent_sdk'

ClaudeAgentSDK.query(prompt: "What is 2 + 2?") do |message|
  puts message.inspect
end
```

## Workflow

1. Choose an interface:
   - Use `ClaudeAgentSDK.query` for simple, stateless calls.
   - Use `ClaudeAgentSDK::Client` when you need bidirectional control (send multiple prompts, interrupt, change model/permissions, rewind files) or when using hooks/permission callbacks/custom tools.
2. Configure options:
   - Set per-request options with `ClaudeAgentSDK::ClaudeAgentOptions`.
   - Set app-wide defaults with `ClaudeAgentSDK.configure` (especially in Rails initializers).
3. Handle messages:
   - Parse assistant text from content blocks.
   - Stop on `ClaudeAgentSDK::ResultMessage` (final result, cost, session_id, structured output).
4. Handle runtime concerns:
   - Rescue `ClaudeAgentSDK::ControlRequestTimeoutError` for long-running control requests.
   - Tune `CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS` when session orchestration needs longer waits.

## Use these references

- Read `references/message-handling.md` to extract text/tool blocks, build streaming input with `Streaming` helpers, use Client runtime APIs (interrupt, set_model, MCP control, stop_task), and capture `UserMessage#uuid` for rewind.
- Read `references/options.md` to configure `ClaudeAgentOptions` (defaults, tools, permissions, output formats, budgets, sandbox, sessions, agents, custom transports), and to browse/mutate sessions (`list_sessions`, `get_session_messages`, `rename_session`, `tag_session`).
- Read `references/mcp-servers.md` to define in-process SDK MCP tools/resources/prompts, configure external MCP servers, or manage MCP servers at runtime (reconnect, toggle, status).
- Read `references/rails.md` for initializers, background jobs, ActionCable streaming, and session resumption patterns.
- Read `references/troubleshooting.md` for common setup/runtime errors and timeout tuning.
