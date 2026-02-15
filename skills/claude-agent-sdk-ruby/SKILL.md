---
name: claude-agent-sdk-ruby
description: Use when writing or refactoring Ruby code that integrates Claude Code via the claude-agent-sdk gem (ClaudeAgentSDK.query, ClaudeAgentSDK::Client, streaming input, ClaudeAgentOptions configuration including global defaults via ClaudeAgentSDK.configure, tools/permissions, MCP servers, hooks, structured output, budgets, sandboxing, betas/tools presets, control-timeout handling, session resumption/rewind, and Rails patterns like jobs or ActionCable).
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

- Read `references/message-handling.md` to extract text/tool blocks, capture `UserMessage#uuid` for rewind, and use `ResultMessage` fields.
- Read `references/options.md` to configure `ClaudeAgentOptions` (defaults, tools, permissions, output formats, budgets, sandbox, sessions, advanced flags).
- Read `references/mcp-servers.md` to define in-process SDK MCP tools/resources/prompts or configure external MCP servers.
- Read `references/rails.md` for initializers, background jobs, ActionCable streaming, and session resumption patterns.
- Read `references/troubleshooting.md` for common setup/runtime errors and timeout tuning.
