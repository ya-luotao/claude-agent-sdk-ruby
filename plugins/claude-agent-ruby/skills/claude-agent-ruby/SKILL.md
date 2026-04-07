---
name: claude-agent-ruby
description: Implement or modify Ruby code using the claude-agent-sdk gem. Covers query() one-shot calls, Client-based interactive sessions, streaming input, all 27 hook events, permission callbacks, SDK MCP servers, structured output, bare mode, full sandbox settings (network + filesystem), all 24 message types (including tool_progress, auth_status, prompt_suggestion, hook lifecycle, compact_boundary, session_state_changed), session browsing/mutations, subagents, file checkpointing, Rails integration, and custom transports. Use this skill whenever the user mentions claude-agent-sdk, Claude Agent Ruby, building AI agents in Ruby, or integrating Claude Code into a Ruby/Rails application.
---

# Claude Agent Ruby SDK

## Overview
Use this skill to build or refactor Ruby integrations with Claude Code via `claude-agent-sdk`, favoring the gem's README and types for exact APIs.

## Decision Guide
- Choose `ClaudeAgentSDK.query` for one-shot queries or streaming input. Internally uses the control protocol (streaming mode).
- Choose `ClaudeAgentSDK::Client` for multi-turn sessions, hooks, permission callbacks, MCP server control, or dynamic model switching; wrap in `Async do ... end.wait`.
- Choose SDK MCP servers (`create_tool`, `create_sdk_mcp_server`) for in-process tools; choose external MCP configs for subprocess/HTTP servers.
- Choose `ClaudeAgentSDK.list_sessions` / `ClaudeAgentSDK.get_session_messages` for browsing previous session transcripts (pure filesystem, no CLI needed).

## Implementation Checklist
- Confirm prerequisites (Ruby 3.2+, Node.js, Claude Code CLI).
- Build `ClaudeAgentSDK::ClaudeAgentOptions` and pass it to `query` or `Client.new`.
- Handle messages by type — the SDK has **24 typed message classes**:
  - Core: `AssistantMessage`, `UserMessage`, `ResultMessage`, `StreamEvent`, `RateLimitEvent`
  - System init: `InitMessage` (session start / /clear — carries uuid, session_id, tools, model, cwd, agents, betas, claude_code_version, permission_mode, slash_commands, output_style, skills, plugins, fast_mode_state)
  - Compaction: `CompactBoundaryMessage` (uuid, session_id, compact_metadata with pre_tokens, trigger, preserved_segment)
  - Status: `StatusMessage` (compacting status, permission mode changes)
  - Tasks: `TaskStartedMessage` (+ workflow_name, prompt), `TaskProgressMessage` (+ summary), `TaskNotificationMessage`
  - Hooks: `HookStartedMessage`, `HookProgressMessage`, `HookResponseMessage`
  - Sessions: `SessionStateChangedMessage` (idle/running/requires_action)
  - Tools: `ToolProgressMessage` (elapsed_time_seconds per tool), `ToolUseSummaryMessage`
  - Auth: `AuthStatusMessage` (isAuthenticating, output, error)
  - Files: `FilesPersistedMessage` (files, failed, processed_at)
  - API: `APIRetryMessage` (attempt, max_retries, retry_delay_ms, error_status)
  - Other: `LocalCommandOutputMessage`, `ElicitationCompleteMessage`, `PromptSuggestionMessage`
  - Unknown message types return `nil` (forward-compatible)
- Handle content blocks: `TextBlock`, `ThinkingBlock`, `ToolUseBlock`, `ToolResultBlock`, `UnknownBlock`
- `ResultMessage` carries: `stop_reason`, `model_usage` (per-model breakdown), `permission_denials`, `errors` (on error subtypes), `uuid`, `fast_mode_state`
- Use `output_format` for JSON schema structured output
- Use `thinking:` with `ThinkingConfigAdaptive`, `ThinkingConfigEnabled(budget_tokens:)`, or `ThinkingConfigDisabled`. Use `effort:` for effort level.

## Hooks (27 events)
All hook events: PreToolUse, PostToolUse, PostToolUseFailure, Notification, UserPromptSubmit, SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact, PermissionRequest, PermissionDenied, Setup, TeammateIdle, TaskCreated, TaskCompleted, Elicitation, ElicitationResult, ConfigChange, WorktreeCreate, WorktreeRemove, InstructionsLoaded, CwdChanged, FileChanged.

Define hooks as Ruby procs/lambdas. Do not combine `can_use_tool` with `permission_prompt_tool_name`. Tool-lifecycle hooks carry `agent_id` and `agent_type` when firing inside subagents. `StopHookInput` and `SubagentStopHookInput` include `last_assistant_message`.

Hook-specific outputs with `to_h`: `PreToolUseHookSpecificOutput`, `PostToolUseHookSpecificOutput`, `PostToolUseFailureHookSpecificOutput`, `UserPromptSubmitHookSpecificOutput`, `NotificationHookSpecificOutput`, `SubagentStartHookSpecificOutput`, `SessionStartHookSpecificOutput`, `SetupHookSpecificOutput`, `PermissionRequestHookSpecificOutput`, `PermissionDeniedHookSpecificOutput`, `CwdChangedHookSpecificOutput`, `FileChangedHookSpecificOutput`.

## Bare Mode
Use `bare: true` for minimal startup — skips hooks, LSP, plugin sync, CLAUDE.md auto-discovery, auto-memory, keychain reads. Explicitly provide context via `system_prompt`, `add_dirs`, `setting_sources`, `allowed_tools`.

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  bare: true,
  system_prompt: 'You are a code reviewer.',
  permission_mode: 'bypassPermissions'
)
```

## Sandbox Settings (full CC parity)
- `SandboxSettings`: enabled, fail_if_unavailable, auto_allow_bash_if_sandboxed, excluded_commands, allow_unsandboxed_commands, network, filesystem, ignore_violations (Hash), enable_weaker_nested_sandbox, enable_weaker_network_isolation, ripgrep
- `SandboxNetworkConfig`: allowed_domains, allow_managed_domains_only, allow_unix_sockets, allow_all_unix_sockets, allow_local_binding, http_proxy_port, socks_proxy_port
- `SandboxFilesystemConfig`: allow_write, deny_write, deny_read, allow_read, allow_managed_read_paths_only

## SDK MCP Tools
- Include `mcp__<server>__<tool>` in `allowed_tools`
- Use `annotations:` on `create_tool` for MCP tool annotations
- Both symbol-keyed and string-keyed `input_schema` hashes are accepted

## Session Management
- `resume`, `session_id`, `fork_session` for session handling
- `Client#reconnect_mcp_server(name)`, `Client#toggle_mcp_server(name, enabled)`, `Client#stop_task(task_id)` for live control
- `Client#rewind_files(uuid)` with `enable_file_checkpointing: true`
- `McpStatusResponse.parse(client.get_mcp_status)` for typed MCP status

## Where To Look For Exact Details
- Locate the gem: `bundle show claude-agent-sdk`
- Read `<gem_path>/README.md` for canonical usage and option examples
- Inspect `<gem_path>/lib/claude_agent_sdk/types.rb` for all types
- Inspect `<gem_path>/lib/claude_agent_sdk/message_parser.rb` for message parsing
- Inspect `<gem_path>/lib/claude_agent_sdk/sessions.rb` for session browsing
- Inspect `<gem_path>/lib/claude_agent_sdk/errors.rb` for error classes
- Use `references/usage-map.md` for a README section map and minimal skeletons

## Resources
### references/
- Read `references/usage-map.md` to map tasks to README sections, gem paths, and minimal skeletons.
- Read `references/message-handling.md` to extract text/tool blocks, build streaming input, use Client runtime APIs, and capture UUIDs for rewind.
- Read `references/options.md` to configure `ClaudeAgentOptions` (defaults, tools, permissions, output formats, budgets, sandbox, sessions, agents, custom transports), and to browse/mutate sessions.
- Read `references/mcp-servers.md` to define in-process SDK MCP tools/resources/prompts, configure external MCP servers, or manage MCP servers at runtime.
- Read `references/rails.md` for initializers, background jobs, ActionCable streaming, and session resumption patterns.
- Read `references/troubleshooting.md` for common setup/runtime errors and timeout tuning.
