---
name: claude-agent-ruby
description: Implement or modify Ruby code that uses the claude-agent-sdk gem, including query() one-shot calls, Client-based interactive sessions, streaming input, option configuration, tools/permissions, hooks, SDK MCP servers, structured output, budgets, sandboxing, session resumption, session browsing (list_sessions/get_session_messages), task lifecycle messages, MCP server control (reconnect/toggle/stop), Rails integration, and error handling.
---

# Claude Agent Ruby SDK

## Overview
Use this skill to build or refactor Ruby integrations with Claude Code via `claude-agent-sdk`, favoring the gem's README and types for exact APIs.

## Decision Guide
- Choose `ClaudeAgentSDK.query` for one-shot queries or streaming input. Internally uses the control protocol (streaming mode) since v0.7.0.
- Choose `ClaudeAgentSDK::Client` for multi-turn sessions, hooks, permission callbacks, MCP server control, or dynamic model switching; wrap in `Async do ... end.wait`.
- Choose SDK MCP servers (`create_tool`, `create_sdk_mcp_server`) for in-process tools; choose external MCP configs for subprocess/HTTP servers.
- Choose `ClaudeAgentSDK.list_sessions` / `ClaudeAgentSDK.get_session_messages` for browsing previous session transcripts (pure filesystem, no CLI needed).

## Implementation Checklist
- Confirm prerequisites (Ruby 3.2+, Node.js, Claude Code CLI).
- Build `ClaudeAgentSDK::ClaudeAgentOptions` and pass it to `query` or `Client.new`.
- Handle messages by type (`AssistantMessage`, `ResultMessage`, `UserMessage`, etc.) and content blocks (`TextBlock`, `ToolUseBlock`, `UnknownBlock`, etc.). Use `is_a?` filtering — unknown content block types are returned as `UnknownBlock` (with `.type` and `.data` accessors) and unknown message types are returned as `nil`.
- Handle task lifecycle messages: `TaskStartedMessage`, `TaskProgressMessage`, `TaskNotificationMessage` are `SystemMessage` subclasses — existing `is_a?(SystemMessage)` checks still match them. Use `is_a?(TaskStartedMessage)` for specific dispatch.
- Use `ResultMessage#stop_reason` to check why Claude stopped (e.g., `'end_turn'`, `'max_tokens'`, `'stop_sequence'`).
- Use `output_format` and read `StructuredOutput` tool-use blocks for JSON schema responses.
- Use `thinking:` with `ThinkingConfigAdaptive`, `ThinkingConfigEnabled(budget_tokens:)`, or `ThinkingConfigDisabled` to control extended thinking. Use `effort:` (`'low'`, `'medium'`, `'high'`) for effort level.
- Define hooks and permission callbacks as Ruby procs/lambdas; do not combine `can_use_tool` with `permission_prompt_tool_name`. Hook inputs include `tool_use_id` on `PreToolUseHookInput` and `PostToolUseHookInput`. Tool-lifecycle hooks (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`) also carry `agent_id` and `agent_type` when firing inside subagents.
- For SDK MCP tools, include `mcp__<server>__<tool>` in `allowed_tools`. Use `annotations:` on `create_tool` for MCP tool annotations. Both symbol-keyed and string-keyed `input_schema` hashes are accepted (e.g., from RubyLLM or `JSON.parse`); the SDK normalizes to symbol keys internally.
- Use `tools` or `ToolsPreset` for base tool selection; use `append_allowed_tools` when extending defaults.
- Configure sandboxing via `SandboxSettings` and `SandboxNetworkConfig` when requested.
- Use `resume`, `session_id`, and `fork_session` for session handling; enable file checkpointing only when explicitly needed.
- Use `Client#reconnect_mcp_server(name)`, `Client#toggle_mcp_server(name, enabled)`, and `Client#stop_task(task_id)` for live MCP and task control.
- Use typed MCP status types: `McpStatusResponse.parse(client.get_mcp_status)` returns `McpServerStatus` objects with `server_info`, `tools`, `error`, etc.
- Note: when `system_prompt` is nil (default), the SDK passes `--system-prompt ""` to suppress the default Claude Code system prompt.

## Where To Look For Exact Details
- Locate the gem path with `bundle show claude-agent-sdk` or `ruby -e 'puts Gem::Specification.find_by_name(\"claude-agent-sdk\").full_gem_path'`.
- Read `<gem_path>/README.md` for canonical usage and option examples.
- Inspect `<gem_path>/lib/claude_agent_sdk/types.rb` for the full options and type list.
- Inspect `<gem_path>/lib/claude_agent_sdk/sessions.rb` for session browsing types and functions.
- Inspect `<gem_path>/lib/claude_agent_sdk/errors.rb` for error classes and handling.
- Use `references/usage-map.md` for a README section map and minimal skeletons.

## Resources
### references/
Use `references/usage-map.md` to map tasks to README sections and gem paths.
