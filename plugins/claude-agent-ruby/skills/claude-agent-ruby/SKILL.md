---
name: claude-agent-ruby
description: Implement or modify Ruby code using the claude-agent-sdk gem. Covers query() one-shot calls, Client-based interactive sessions, streaming input, all 27 hook events, permission callbacks, SDK MCP servers, structured output, bare mode, full sandbox settings (network + filesystem), all 28 message types (including tool_progress, auth_status, prompt_suggestion, hook lifecycle, compact_boundary, session_state_changed, mirror_error, task_updated), session browsing/mutations, SessionStore transcript mirroring to external storage (S3/Redis/Postgres) with store-backed resume, subagents, file checkpointing, Rails integration, and custom transports. Use this skill whenever the user mentions claude-agent-sdk, Claude Agent Ruby, building AI agents in Ruby, or integrating Claude Code into a Ruby/Rails application.
---

# Claude Agent Ruby SDK

## Overview
Use this skill to build or refactor Ruby integrations with Claude Code via `claude-agent-sdk`, favoring the gem's README, the `docs/` topic subpages, and `lib/` types for exact APIs.

## Decision Guide
- Choose `ClaudeAgentSDK.query` for one-shot queries or streaming input. Internally uses the control protocol (streaming mode).
- Choose `ClaudeAgentSDK::Client` for multi-turn sessions, hooks, permission callbacks, MCP server control, or dynamic model switching. Prefer `ClaudeAgentSDK::Client.open(options: ...) { |client| ... }` — it creates its own reactor and always disconnects (return a value instead of `break` outside a reactor); use `Client.new` + `connect` / `ensure disconnect` only inside an existing `Async` block.
- Choose SDK MCP servers (`create_tool`, `create_sdk_mcp_server`) for in-process tools; choose external MCP configs for subprocess/HTTP servers.
- Choose `ClaudeAgentSDK.list_sessions` / `ClaudeAgentSDK.get_session_messages` for browsing previous session transcripts (pure filesystem, no CLI needed).

## Implementation Checklist
- Confirm prerequisites (Ruby 3.2+, Node.js, Claude Code CLI).
- Build `ClaudeAgentSDK::ClaudeAgentOptions` and pass it to `query` or `Client.new`.
- Handle messages by type — the SDK has **28 typed message classes**:
  - Core: `AssistantMessage`, `UserMessage`, `ResultMessage`, `StreamEvent`, `RateLimitEvent`
  - Conversation reset: `ConversationResetMessage` (the conversation was replaced mid-session, e.g. `/clear` — see references/message-handling.md)
  - System init: `InitMessage` (session start / /clear — carries uuid, session_id, tools, model, cwd, agents, betas, claude_code_version, permission_mode, slash_commands, output_style, skills, plugins, fast_mode_state)
  - Compaction: `CompactBoundaryMessage` (uuid, session_id, compact_metadata with pre_tokens, trigger, preserved_segment)
  - Status: `StatusMessage` (compacting status, permission mode changes)
  - Tasks: `TaskStartedMessage` (+ workflow_name, prompt, subagent_type, is_backgrounded, spawn_depth, skip_transcript, ambient), `TaskProgressMessage` (+ summary, subagent_type), `TaskNotificationMessage` (+ reason, resource_links, skip_transcript, ambient), `TaskUpdatedMessage` (lifecycle state change; `status` — and `is_backgrounded`, `error`, `end_time`, `total_paused_ms`, `description` — derived from `patch`, `task_id` always a String — clear active-task tracking when `status` is in `TERMINAL_TASK_STATUSES`). Optional booleans keep `nil` (absent) distinct from `false`: `is_backgrounded == false` means foreground/blocking
  - Subagent UI: `BackgroundTasksChangedMessage` (`tasks` — the full live background set, REPLACE semantics; reset on CLI restart), `PermissionDeniedMessage` (auto-denied tool call; best-effort advisory — `ResultMessage#permission_denials` is authoritative). See docs/subagents.md
  - Hooks: `HookStartedMessage`, `HookProgressMessage`, `HookResponseMessage`
  - Sessions: `SessionStateChangedMessage` (idle/running/requires_action)
  - Tools: `ToolProgressMessage` (elapsed_time_seconds per tool), `ToolUseSummaryMessage`
  - Auth: `AuthStatusMessage` (isAuthenticating, output, error)
  - Files: `FilesPersistedMessage` (files, failed, processed_at)
  - API: `APIRetryMessage` (attempt, max_retries, retry_delay_ms, error_status)
  - Session store: `MirrorErrorMessage` (a SessionStore append failed terminally — timeouts immediately, other failures after up to three attempts; session continues; local transcript stays durable)
  - Other: `LocalCommandOutputMessage`, `ElicitationCompleteMessage`, `PromptSuggestionMessage`
  - Unknown message types return `nil` (forward-compatible)
- Handle content blocks: `TextBlock`, `ThinkingBlock`, `ToolUseBlock`, `ToolResultBlock`, `UnknownBlock`
- `AssistantMessage` carries: `content`, `model`, `parent_tool_use_id`, `error`, `usage`, `message_id` (API message ID), `stop_reason`, `session_id`, `uuid` (transcript UUID)
- `ResultMessage` carries: `stop_reason`, `model_usage` (per-model breakdown), `permission_denials`, `errors` (on error subtypes), `uuid`, `fast_mode_state`, `terminal_reason` (why the query loop ended; `aborted_streaming`/`aborted_tools` mean interrupted)
- Use `output_format` for JSON schema structured output
- Use `thinking: ThinkingConfigAdaptive.new` and control depth with `effort:`. `ThinkingConfigEnabled(budget_tokens:)` is only for older models that take a fixed budget; `ThinkingConfigDisabled` turns thinking off.

## Hooks (27 events)
All hook events: PreToolUse, PostToolUse, PostToolUseFailure, Notification, UserPromptSubmit, SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact, PermissionRequest, PermissionDenied, Setup, TeammateIdle, TaskCreated, TaskCompleted, Elicitation, ElicitationResult, ConfigChange, WorktreeCreate, WorktreeRemove, InstructionsLoaded, CwdChanged, FileChanged.

Define hooks as Ruby procs/lambdas. Do not combine `can_use_tool` with `permission_prompt_tool_name`. Tool-lifecycle hooks carry `agent_id` and `agent_type` when firing inside subagents. `StopHookInput` and `SubagentStopHookInput` include `last_assistant_message` plus optional `background_tasks` / `session_crons` snapshots of the **parent session's** background work (`nil` = not provided, `[]` = explicitly empty; not a registry of all agents). Every dispatched hook and `can_use_tool` callback gets `context.request_id` and `context.signal` (a `ClaudeAgentSDK::CancellationSignal`: `cancelled?` / `wait(timeout:)`) — cancellation is cooperative (CLI cancel, EOF, disconnect, callback failure, hook timeout), default `:thread` callbacks are never force-killed, and a decision returned after cancellation is discarded, never sent as an allow.

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
- `SandboxNetworkConfig`: allowed_domains, denied_domains, allow_managed_domains_only, allow_unix_sockets, allow_all_unix_sockets, allow_local_binding, allow_mach_lookup, http_proxy_port, socks_proxy_port
- `SandboxFilesystemConfig`: allow_write, deny_write, deny_read, allow_read, allow_managed_read_paths_only

## SDK MCP Tools
- Include `mcp__<server>__<tool>` in `allowed_tools`
- Use `annotations:` on `create_tool` for MCP tool annotations
- Use `meta:` on `create_tool` for `_meta` field forwarding (e.g., `{ 'anthropic/maxResultSizeChars' => 100000 }` to prevent truncation of large results)
- If `annotations[:maxResultSizeChars]` is set, `_meta` is auto-populated
- Both symbol-keyed and string-keyed `input_schema` hashes are accepted

## Session Management
- `resume`, `session_id`, `fork_session` option for session handling
- `ClaudeAgentSDK.delete_session(session_id:, directory:)` — hard-deletes a session
- `ClaudeAgentSDK.fork_session(session_id:, directory:, up_to_message_id:, title:)` → `ForkSessionResult` — filesystem fork with UUID remapping
- `ClaudeAgentSDK.list_sessions(directory:, limit:, offset:, include_worktrees:)` — supports `offset` for pagination
- `ClaudeAgentSDK.list_subagents(session_id:, directory:)` / `ClaudeAgentSDK.get_subagent_messages(session_id:, agent_id:, directory:, limit:, offset:)` — subagent transcript readers; `ClaudeAgentSDK.get_subagent_metadata(session_id:, agent_id:, directory:)` returns the agent's sidecar as a string-keyed Hash with the CLI's own spelling (`'toolUseId'` = spawning Agent tool call, `'parentAgentId'`, `'agentType'`, `'spawnDepth'`, unknown fields preserved) or `nil` — historical metadata, not live status, and often still `nil` at SubagentStart
- **SessionStore mirroring**: `ClaudeAgentOptions.new(session_store: store)` mirrors transcripts to external storage (subclass `ClaudeAgentSDK::SessionStore` — only `#append`/`#load` required; `InMemorySessionStore` for tests; S3/Redis/Postgres reference adapters in `examples/session_stores/`). `session_store_flush: 'eager'` flushes each frame as soon as the store is free (frames arriving mid-append coalesce into the next append); `load_timeout_ms` bounds resume store calls.
- **Resume from store**: pair `session_store` with `resume:`/`continue_conversation` — no local JSONL needed. Note: runs the CLI against a temp `CLAUDE_CONFIG_DIR` seeded with `.credentials.json` (refreshToken redacted), `.claude.json`, and user `settings.json`/`cowork_settings.json` (minus `enabledPlugins`, `extraKnownMarketplaces`, `env.CLAUDE_CONFIG_DIR`); user `CLAUDE.md`/`agents/`/`skills/`/`plugins/` stay invisible; project `.claude/*` still applies.
- **Store-backed sessions**: every session function above (`list_sessions`, `get_session_info`, `get_session_messages`, `list_subagents`, `get_subagent_metadata`, `get_subagent_messages`, `rename_session`, `tag_session`, `delete_session`, `fork_session`) takes `session_store: store` to operate on the store instead of local disk; with a store, `directory: nil` means cwd (not "all projects") and `include_worktrees:` raises `ArgumentError`. `import_session_to_store` migrates disk → store. The old `*_from_store` / `*_via_store` functions are deprecated (one-time warning, removed in 1.0). Validate adapters with `ClaudeAgentSDK::Testing.run_session_store_conformance`.
- `Client#get_context_usage` — context window breakdown (tokens by category, model, MCP tools, etc.)
- `Client#reconnect_mcp_server(name)`, `Client#toggle_mcp_server(name, enabled)`, `Client#stop_task(task_id)`, `Client#background_tasks(tool_use_id: nil)` for live control
- `Client#rewind_files(uuid)` with `enable_file_checkpointing: true`
- `McpStatusResponse.parse(client.get_mcp_status)` for typed MCP status

## Where To Look For Exact Details
- Locate the gem: `bundle show claude-agent-sdk`
- Read `<gem_path>/README.md` for the overview, install, and minimal API examples
- Read `<gem_path>/docs/*.md` for topic subpages — `client.md` (bidirectional + custom transports), `mcp-servers.md` (SDK MCP tools/resources/prompts), `hooks-and-permissions.md` (27 hook events + permission callbacks), `configuration.md` (structured output, thinking, budget, sandbox, bare mode, file checkpointing), `sessions.md` (list/read/rename/tag/fork/resume + SessionStore mirroring/store-backed helpers), `observability.md` (OTel + Langfuse), `rails.md` (ActionCable, jobs, initializers), `types.md` (message/content-block/configuration types), `errors.md` (error hierarchy + timeout)
- Inspect `<gem_path>/lib/claude_agent_sdk/types.rb` for all types
- Inspect `<gem_path>/lib/claude_agent_sdk/message_parser.rb` for message parsing
- Inspect `<gem_path>/lib/claude_agent_sdk/sessions.rb` for session browsing
- Inspect `<gem_path>/lib/claude_agent_sdk/errors.rb` for error classes
- Use `references/usage-map.md` for a documentation map (README + docs/) and minimal skeletons

## Resources
### references/
- Read `references/usage-map.md` to map tasks to README and `docs/` subpages, gem paths, and minimal skeletons.
- Read `references/message-handling.md` to extract text/tool blocks, build streaming input, use Client runtime APIs, and capture UUIDs for rewind.
- Read `references/options.md` to configure `ClaudeAgentOptions` (defaults, tools, permissions, skills, output formats, budgets, sandbox, sessions, agents, custom transports), and to browse/mutate sessions.
- Read `references/mcp-servers.md` to define in-process SDK MCP tools/resources/prompts, configure external MCP servers, or manage MCP servers at runtime.
- Read `references/rails.md` for the install generator, the `claude_agent_sdk:install_cli` rake task, `Railtie.callback_wrapper`, background jobs, ActionCable streaming, and session resumption patterns.
- Read `references/troubleshooting.md` for common setup/runtime errors and timeout tuning.
