---
name: claude-agent-ruby
description: Implement or modify Ruby code that uses the claude-agent-sdk gem, including query() one-shot calls, Client-based interactive sessions, streaming input, option configuration, tools/permissions, hooks, SDK MCP servers, structured output, budgets, sandboxing, session resumption, Rails integration, and error handling.
---

# Claude Agent Ruby SDK

## Overview
Use this skill to build or refactor Ruby integrations with Claude Code via `claude-agent-sdk`, favoring the gem's README and types for exact APIs.

## Decision Guide
- Choose `ClaudeAgentSDK.query` for one-shot queries or streaming input. Internally uses the control protocol (streaming mode) since v0.7.0.
- Choose `ClaudeAgentSDK::Client` for multi-turn sessions, hooks, permission callbacks, or dynamic model switching; wrap in `Async do ... end.wait`.
- Choose SDK MCP servers (`create_tool`, `create_sdk_mcp_server`) for in-process tools; choose external MCP configs for subprocess/HTTP servers.

## Implementation Checklist
- Confirm prerequisites (Ruby 3.2+, Node.js, Claude Code CLI).
- Build `ClaudeAgentSDK::ClaudeAgentOptions` and pass it to `query` or `Client.new`.
- Handle messages by type (`AssistantMessage`, `ResultMessage`, `UserMessage`, etc.) and content blocks (`TextBlock`, `ToolUseBlock`, etc.).
- Use `output_format` and read `StructuredOutput` tool-use blocks for JSON schema responses.
- Use `thinking:` with `ThinkingConfigAdaptive`, `ThinkingConfigEnabled(budget_tokens:)`, or `ThinkingConfigDisabled` to control extended thinking. Use `effort:` (`'low'`, `'medium'`, `'high'`) for effort level.
- Define hooks and permission callbacks as Ruby procs/lambdas; do not combine `can_use_tool` with `permission_prompt_tool_name`. Hook inputs include `tool_use_id` on `PreToolUseHookInput` and `PostToolUseHookInput`.
- For SDK MCP tools, include `mcp__<server>__<tool>` in `allowed_tools`. Use `annotations:` on `create_tool` for MCP tool annotations.
- Use `tools` or `ToolsPreset` for base tool selection; use `append_allowed_tools` when extending defaults.
- Configure sandboxing via `SandboxSettings` and `SandboxNetworkConfig` when requested.
- Use `resume`, `session_id`, and `fork_session` for session handling; enable file checkpointing only when explicitly needed.
- Note: when `system_prompt` is nil (default), the SDK passes `--system-prompt ""` to suppress the default Claude Code system prompt.

## Where To Look For Exact Details
- Locate the gem path with `bundle show claude-agent-sdk` or `ruby -e 'puts Gem::Specification.find_by_name(\"claude-agent-sdk\").full_gem_path'`.
- Read `<gem_path>/README.md` for canonical usage and option examples.
- Inspect `<gem_path>/lib/claude_agent_sdk/types.rb` for the full options and type list.
- Inspect `<gem_path>/lib/claude_agent_sdk/errors.rb` for error classes and handling.
- Use `references/usage-map.md` for a README section map and minimal skeletons.

## Resources
### references/
Use `references/usage-map.md` to map tasks to README sections and gem paths.
