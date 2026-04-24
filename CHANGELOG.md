# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.16.5] - 2026-04-24

### Added
- `display:` option on `ThinkingConfigAdaptive` and `ThinkingConfigEnabled`, forwarded to the CLI as `--thinking-display <summarized|omitted>`. Opus 4.7 defaults thinking display to `"omitted"` (empty `thinking` field, signature only), so pass `ThinkingConfigAdaptive.new(display: "summarized")` to receive plaintext summarized thinking text. Invalid values raise `ArgumentError` at construction. See [adaptive thinking docs](https://docs.claude.com/en/docs/build-with-claude/adaptive-thinking).

### Internal
- Extracted private `writeln`/`write` helpers in `Client` and `Query` to consolidate the `@transport.write(json + "\n")` pattern across five call sites. Pure refactor; same bytes on the wire.

## [0.16.4] - 2026-04-23

### Fixed
- `Client#receive_response` no longer hangs in interactive Client mode. The 0.16.1 flag-based fix relied on the loop draining via the transport's `:end` sentinel, which only arrives when the CLI subprocess exits — true for one-shot `query()` but never for a `Client` whose CLI stays alive between turns. `receive_response` now drives `QueryHandler#receive_messages` directly so its `break` runs on the same fiber as the underlying `Async::Queue#dequeue` loop and unwinds it. The 0.16.1 regression spec passed only because its stub iterated a finite array; replaced with a real `Async::Queue` driven from a sibling task so a hang now fails the test.

### Internal
- `FiberBoundary` doc-comment now warns that `break`/`return`/`next` cannot cross the thread hop, so SDK-internal loops yielding user callbacks must keep loop control on the outer side of the boundary.

## [0.16.3] - 2026-04-23

### Changed
- Internal: extracted `SubprocessCLITransport#record_bounded_stderr` helper to deduplicate the recent-stderr ring-buffer append/trim logic shared by `handle_stderr` and `drain_stderr_with_accumulation`, and replaced the inlined `20` cap with a named `RECENT_STDERR_LINES_LIMIT` constant. No public behavior change.

## [0.16.2] - 2026-04-23

### Changed
- Extracted `ClaudeAgentSDK::CommandBuilder` from `SubprocessCLITransport`. CLI argv assembly now lives in its own class and can be exercised in isolation — `CommandBuilder.new(cli_path, options).build` returns the argv array without booting a transport. No public behavior change; `SubprocessCLITransport#build_command` still works and now delegates to `CommandBuilder`.

## [0.16.1] - 2026-04-21

### Fixed
- `Client#receive_response` no longer raises `LocalJumpError: break from proc-closure` when called inside `Async { }`. The 0.15.1 thread-hop severed `break`'s unwind target; replaced with a flag so the loop exits via the natural `end` marker after `ResultMessage`.

## [0.16.0] - 2026-04-22

### Added
- **`#text` on every message type that carries content.** No more hand-rolling a `select { TextBlock }.map(&:text).join` in every consumer.
  - `AssistantMessage#text` — joins text across `TextBlock`s in the content array.
  - `UserMessage#text` — handles both String content (plain prompt) and Array-of-blocks content.
  - `SessionMessage#text` — joins text across parsed content blocks from a historical transcript.
  - `#to_s` on each message type is aliased to `#text`, so `puts message` and string interpolation just work.
  - Non-text blocks (`ToolUseBlock`, `ThinkingBlock`, `ToolResultBlock`, `UnknownBlock`) intentionally do **not** answer `#text` — only `TextBlock` is textual. The message helpers use `Array#grep(TextBlock)` to select text blocks.
- **`SessionMessage#content_blocks`** returns typed block objects (`TextBlock`, `ThinkingBlock`, `ToolUseBlock`, `ToolResultBlock`, `UnknownBlock`) instead of the raw hash blocks from the JSONL transcript. Unknown block types become `UnknownBlock` for forward compatibility with newer CLI versions.

### Changed
- Rails Integration / Quick Start / Observability / File Checkpointing README examples dropped the `content.select { is_a?(TextBlock) }.map(&:text).join` dance in favor of `message.text`.

## [0.15.1] - 2026-04-22

### Fixed
- **Thread-keyed libraries are now safe inside SDK callbacks.** The SDK internally hops to a plain thread at every user-callback boundary — blocks passed to `ClaudeAgentSDK.query` / `Client#receive_messages`, SDK MCP tool handlers, hooks, permission callbacks, and observer methods — so the `async` gem's Fiber scheduler is no longer visible to user code. Previously, any library that keys state on `Thread.current` (ActiveRecord and every DB driver keyed by thread — `pg`, `mysql2`, `sqlite3` — plus per-thread HTTP/cache pools, request stores, etc.) could be corrupted by the scheduler interleaving two fibers onto one checked-out connection. Rails/Sidekiq/Kamal consumers no longer need a caller-side wrapper to avoid this. See the "Thread-keyed libraries are safe inside SDK callbacks" subsection under Rails Integration in the README.

### Changed
- **Callbacks run on a plain thread, not inside `Async::Task`.** Fiber-specific primitives (e.g. `Async::Task.current.sleep`, `Async::Task.current.async { ... }`) are no longer available inside tool handlers, hooks, permission callbacks, message blocks, or observers. Callbacks that want cooperative concurrency can open their own `Async { }` block. In practice callbacks do ordinary Ruby work and return a value, so this rarely affects real code.

## [0.15.0] - 2026-04-17

### Fixed

#### Protocol & CLI
- `--setting-sources` is now only emitted when the option is explicitly configured. Previously every invocation sent `--setting-sources ""`, which the CLI can interpret as "no setting sources" rather than "use defaults", overriding the CLI's own source resolution.
- `extra_args` flag names are validated against a lowercase kebab-case pattern and raise `ArgumentError` otherwise. Prevents option injection from multi-tenant configs (e.g. an attacker-controlled hash injecting `--permission-mode bypassPermissions` and relying on CLI last-wins to defeat SDK-chosen safety).

#### Concurrency
- `SubprocessCLITransport#close` replaced `Timeout.timeout` with Async-safe polling on `@process.alive?`. Stdlib `Timeout.timeout` raises via `Thread#raise`, which can corrupt fiber-scheduler state when `close` runs inside the Async reactor. Still raises `Timeout::Error` so existing rescue clauses keep working.
- Inbound `control_request` handlers are now spawned as children of the current read task via `Async::Task.current.async`. Bare `Async do` had ambiguous parent linkage; `@task.stop` could leave handler tasks writing to a closed transport.

#### Sessions
- `list_sessions` and `get_session_messages` coerce `offset: nil` to 0. Previously callers splatting from an options hash crashed on `nil.positive?` / `messages[nil..]`.
- `fork_session` streams the source JSONL via `File.foreach` instead of `File.read`, and scrubs non-UTF-8 bytes on each line. Fixes `Encoding::InvalidByteSequenceError` on stray bytes in tool output and avoids slurping sessions that can reach hundreds of MB.
- `simple_hash` (used for project-dir hashing) now iterates UTF-16 code units to match JavaScript's `charCodeAt`. Previously `each_char` + `ord` diverged from the official tools for supplementary characters (emoji, CJK extensions), so paths containing them hashed to different project directories and silently returned no sessions.

#### Security
- Replaced shell backticks with `Open3.capture3` (array args) in worktree detection. The path argument was already `Shellwords.escape`d, but running via `/bin/sh` leaves a latent shell-injection surface — any future interpolation without escaping would be exploitable.

### Changed
- `derive_fork_title` helper is now `private_class_method`, matching its siblings on `SessionMutations`.



### Added
- **`EFFORT_LEVELS` constant** exposing `%w[low medium high xhigh max]`. Consumers can reference `ClaudeAgentSDK::EFFORT_LEVELS` for validation instead of hard-coding the list.
- **`xhigh` effort level**: documented in the SDK to match the Claude Code CLI (2.1.111+). Supported on Opus 4.7; the CLI auto-falls-back to the highest supported level on older models (e.g. `xhigh` → `high` on Opus 4.6).

### Changed
- Inline comments and README updated to reference `ClaudeAgentSDK::EFFORT_LEVELS` rather than a stale hard-coded level list.

## [0.14.1] - 2026-04-09

### Fixed
- **Thinking configuration**: Use `--thinking adaptive` / `--thinking disabled` CLI flags instead of mapping to `--max-thinking-tokens`. Previously, `ThinkingConfigAdaptive` was mapped to `--max-thinking-tokens 32000` (fixed budget) and `ThinkingConfigDisabled` to `--max-thinking-tokens 0`, which put the CLI into the wrong mode. Only `ThinkingConfigEnabled` now uses `--max-thinking-tokens`. (Parity with [Python SDK #796](https://github.com/anthropics/claude-agent-sdk-python/pull/796))

### Added
- **`exclude_dynamic_sections`** on `SystemPromptPreset`: When set to `true`, the CLI strips per-user dynamic sections (working directory, auto-memory, git status) from the preset system prompt and re-injects them into the first user message. This makes the system prompt byte-identical across users, enabling cross-user prompt-caching hits. Sent via `excludeDynamicSections` in the initialize control message; older CLIs silently ignore it. (Parity with [Python SDK #797](https://github.com/anthropics/claude-agent-sdk-python/pull/797))

## [0.14.0] - 2026-04-08 — Python SDK v0.1.51–0.1.56 Parity

### Added

#### Type Completeness
- `AssistantMessage`: `message_id`, `stop_reason`, `session_id`, `uuid` fields (populated from CLI message data)
- `AgentDefinition`: `disallowed_tools`, `max_turns`, `initial_prompt`, `background`, `effort`, `permission_mode` fields (serialized to CLI via initialize request)
- `ToolPermissionContext`: `tool_use_id`, `agent_id` fields for distinguishing parallel permission requests and sub-agent context
- `PERMISSION_MODES`: added `dontAsk` and `auto` values

#### New Types and Options
- `SystemPromptFile` class — loads system prompt from a file path via `--system-prompt-file` CLI flag
- `TaskBudget` class — API-side token budget, passed as `--task-budget` CLI flag
- `ForkSessionResult` class — returned by `fork_session()` with the new session ID
- `session_id` option on `ClaudeAgentOptions` — specify a custom session ID via `--session-id` CLI flag
- `task_budget` option on `ClaudeAgentOptions`

#### Session Management
- `ClaudeAgentSDK.delete_session(session_id:, directory:)` — hard-deletes a session JSONL file
- `ClaudeAgentSDK.fork_session(session_id:, directory:, up_to_message_id:, title:)` — filesystem-level fork with UUID remapping, sidechain filtering, content-replacement forwarding, and auto-generated titles
- `offset` parameter on `ClaudeAgentSDK.list_sessions` for cursor-based pagination

#### Client Introspection
- `Client#get_context_usage` / `Query#get_context_usage` — sends `get_context_usage` control request for context window breakdown (tokens by category, model, MCP tools, memory files, etc.)

#### MCP Robustness
- `SdkMcpTool#meta` field and `_meta` forwarding in `tools/list` responses — prevents silent truncation of large tool results (>50K chars) by forwarding `anthropic/maxResultSizeChars` through the MCP `_meta` field
- `create_tool` auto-populates `_meta` from `annotations[:maxResultSizeChars]` when present

## [0.13.1] - 2026-04-05

### Fixed
- Handle `ProcessError` when CLI exits non-zero after delivering a valid result (e.g., StructuredOutput `tool_use` triggers exit code 1). Previously this propagated as a fatal error; now it is suppressed when a result was already received.

## [0.13.0] - 2026-04-03

### Added

#### Observer Interface
- `Observer` module with `on_user_prompt`, `on_message`, `on_error`, `on_close` — all with no-op defaults
- `observers` option on `ClaudeAgentOptions` (default `[]`) — register observers for both `query()` and `Client`
- `resolve_observers` supports callable factories (lambdas) for thread-safe global defaults in Rails/Puma/Sidekiq
- `notify_observers` rescues per-observer errors so observers never crash the main pipeline

#### OpenTelemetry Instrumentation
- `ClaudeAgentSDK::Instrumentation::OTelObserver` — emits spans using `gen_ai.*` and OpenInference semantic conventions
- Span tree: `claude_agent.session` (root) → `claude_agent.generation` + `claude_agent.tool.*` (children)
- `langfuse.observation.type` set on all spans (`agent`/`generation`/`tool`) to enable Langfuse trace flow diagram
- `input.value`/`output.value` (OpenInference) for Langfuse Preview Input/Output fields
- `llm.token_count.*`, `llm.cost.total`, `llm.model_name` for full Langfuse cost/usage tracking
- `openinference.span.kind` (`AGENT`/`LLM`/`TOOL`) on all spans
- Events: `api_retry`, `rate_limit`, `tool_progress` recorded on root span
- Lazy `require 'opentelemetry'` — zero cost for users who don't use it

#### Examples
- `otel_langfuse_example.rb` — Langfuse-via-OTel setup with OTLP exporter
- `test_langfuse_otel.rb` — multi-tool integration test (Bash tool calls)

### Changed
- README: added Observability section with Langfuse setup guide, span attribute reference, custom observer example, Rails initializer patterns
- README: split sandbox into CLI settings vs sandbox-runtime rows in comparison table
- README: updated recommended gem version to `~> 0.13.0`
- CLAUDE.md: documented observer/instrumentation architecture

## [0.12.0] - 2026-04-01

Full Claude Code parity release — cross-referenced against the Claude Code source (`coreSchemas.ts`) and TypeScript SDK to bring every message type, hook event, and sandbox setting into the Ruby SDK.

### Added

#### All 24 Message Types (full CLI parity)
- `InitMessage` — session start / `/clear` with uuid, session_id, agents, api_key_source, betas, claude_code_version, cwd, tools, mcp_servers, model, permission_mode, slash_commands, output_style, skills, plugins, fast_mode_state
- `CompactBoundaryMessage` — context compaction with uuid, session_id, compact_metadata (pre_tokens, trigger, preserved_segment)
- `StatusMessage` — compacting status, permission mode changes
- `APIRetryMessage` — attempt, max_retries, retry_delay_ms, error_status, error
- `LocalCommandOutputMessage` — local command output content
- `HookStartedMessage`, `HookProgressMessage`, `HookResponseMessage` — hook lifecycle with hook_id, hook_name, hook_event, stdout, stderr, output, exit_code, outcome
- `SessionStateChangedMessage` — idle/running/requires_action state
- `FilesPersistedMessage` — files, failed, processed_at
- `ElicitationCompleteMessage` — MCP elicitation completion
- `ToolProgressMessage` — per-tool elapsed time tracking (type: `tool_progress`)
- `AuthStatusMessage` — authentication status (type: `auth_status`)
- `ToolUseSummaryMessage` — tool use summaries (type: `tool_use_summary`)
- `PromptSuggestionMessage` — predicted next prompts (type: `prompt_suggestion`)

#### All 27 Hook Events (full CLI parity)
- New hook input types: `SessionStartHookInput`, `SessionEndHookInput`, `StopFailureHookInput`, `PostCompactHookInput`, `PermissionDeniedHookInput`, `SetupHookInput`, `TeammateIdleHookInput`, `TaskCreatedHookInput`, `TaskCompletedHookInput`, `ElicitationHookInput`, `ElicitationResultHookInput`, `ConfigChangeHookInput`, `InstructionsLoadedHookInput`, `CwdChangedHookInput`, `FileChangedHookInput`, `WorktreeCreateHookInput`, `WorktreeRemoveHookInput`
- New hook specific output types: `SetupHookSpecificOutput`, `PermissionDeniedHookSpecificOutput`, `CwdChangedHookSpecificOutput`, `FileChangedHookSpecificOutput`
- `StopHookInput` and `SubagentStopHookInput` now include `last_assistant_message`

#### Bare Mode
- `bare: true` option on `ClaudeAgentOptions` — sugar for `--bare` CLI flag (skips hooks, LSP, plugin sync, CLAUDE.md auto-discovery, auto-memory, keychain reads)

#### Full Sandbox Settings (CC parity)
- `SandboxFilesystemConfig` — new class with allow_write, deny_write, deny_read, allow_read, allow_managed_read_paths_only
- `SandboxNetworkConfig` — added allowed_domains, allow_managed_domains_only
- `SandboxSettings` — added fail_if_unavailable, filesystem, enable_weaker_network_isolation, ripgrep
- `ignore_violations` now accepts a plain Hash (matching CC's `Record<string, string[]>`)
- Removed `SandboxIgnoreViolations` class (CC uses generic hash, not typed struct)

#### Expanded Existing Types
- `ResultMessage` — added uuid, fast_mode_state, model_usage, permission_denials, errors
- `TaskStartedMessage` — added workflow_name, prompt
- `TaskProgressMessage` — added summary
- `CompactMetadata` — added preserved_segment
- `ASSISTANT_MESSAGE_ERRORS` — added max_output_tokens

#### Session Browsing
- `get_session_info(session_id:, directory:)` — single-session metadata lookup without scanning full directory
- `SDKSessionInfo` — added tag, created_at fields; improved title/summary extraction

#### Examples
- `message_types_example.rb` — comprehensive handler for all 24 message types
- `lifecycle_hooks_example.rb` — all 27 hook events with typed inputs/outputs
- `bare_mode_example.rb` — minimal startup patterns
- `sandbox_example.rb` — full sandbox config (network, filesystem, violations)

### Fixed
- Graceful subprocess shutdown: wait before SIGTERM to avoid race conditions
- `CLAUDE_CODE_ENTRYPOINT` uses default-if-absent semantics (doesn't override caller env)
- Pre-existing `Time.zone` spec failures in sessions_spec.rb
- Pre-existing `File.open` without block in session_mutations.rb

### Changed
- README restructured: positioned as community Ruby SDK (not Python mirror), 3-way comparison table (TS/Python/Ruby), links to official SDKs
- Skill updated to cover all new types and hook events

## [0.11.0] - 2026-03-20

### Added

#### Custom Transport Support
- `Client.new` accepts `transport_class:` and `transport_args:` keyword arguments, allowing consumers to plug in custom transports (e.g., E2B sandbox, remote SSH) without duplicating `Client#connect` internals
- Default remains `SubprocessCLITransport` — zero behavior change for existing callers
- Custom transport class must implement the `Transport` interface (`connect`, `write`, `read_messages`, `end_input`, `close`, `ready?`)
- `transport_args` are passed as keyword arguments to `transport_class.new(options, **transport_args)`
- All option transformations, MCP extraction, hook conversion, and Query lifecycle stay in `Client#connect` — the transport only handles I/O

## [0.10.0] - 2026-03-20

Port of Python SDK v0.1.48 features for feature parity.

### Added

#### Session Mutations
- `ClaudeAgentSDK.rename_session(session_id:, title:, directory:)` — rename a session by appending a custom-title JSONL entry
- `ClaudeAgentSDK.tag_session(session_id:, tag:, directory:)` — tag a session (pass `nil` to clear); tags are Unicode-sanitized
- `SessionMutations` module with `rename_session`, `tag_session`, and internal Unicode sanitization helpers
- Ported from Python SDK's `_internal/session_mutations.py` with TOCTOU-safe `O_WRONLY | O_APPEND` file operations

#### AssistantMessage Usage
- `usage` attribute on `AssistantMessage` — token usage data from the API response
- `MessageParser` populates `usage` from `data.dig(:message, :usage)`

#### AgentDefinition Fields
- `skills`, `memory`, `mcp_servers` attributes on `AgentDefinition`
- Serialized as `skills`, `memory`, `mcpServers` (camelCase) in the CLI wire protocol initialize request

#### TaskUsage Typed Class
- `TaskUsage` class with `total_tokens`, `tool_uses`, `duration_ms` attributes
- `TaskUsage.from_hash` factory supporting symbol, string, camelCase, and snake_case keys

### Removed

#### FGTS Environment Variable
- Removed auto-setting of `CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING` environment variable when `include_partial_messages` is enabled — Python SDK v0.1.48 reverted this because it causes HTTP 400 errors on LiteLLM proxies, Bedrock, and Vertex with Claude 4.5 models. The `--include-partial-messages` CLI flag remains the correct mechanism.

## [0.9.0] - 2026-03-12

Port of Python SDK v0.1.48 parity improvements.

### Added

#### Typed Rate Limit Events
- `RateLimitInfo` class with `status`, `resets_at`, `rate_limit_type`, `utilization`, `overage_status`, `overage_resets_at`, `overage_disabled_reason`, `raw` attributes
- `RATE_LIMIT_STATUSES` constant (`allowed`, `allowed_warning`, `rejected`)
- `RATE_LIMIT_TYPES` constant (`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `overage`)
- `RateLimitEvent` now has typed `rate_limit_info`, `uuid`, `session_id` attributes (previously raw `data` hash)
- Backward-compatible `data` accessor on `RateLimitEvent` returns raw hash from `rate_limit_info.raw`

#### MCP Status Output Types
- `McpClaudeAIProxyServerConfig` type for `claudeai-proxy` servers in MCP status responses
- `McpSdkServerConfigStatus` type for serializable SDK server config in status responses
- `McpServerStatus.parse` handles `claudeai-proxy` config type

#### Effort Level
- `effort` option now supports `"max"` value in addition to `"low"`, `"medium"`, `"high"`

## [0.8.1] - 2026-03-08

Python SDK parity fixes for one-shot `query()` control protocol and CLI transport.

### Fixed

#### One-Shot Query Control Protocol
- **Hooks and `can_use_tool` in `query()`:** One-shot `query()` now passes `hooks`, `can_use_tool`, and SDK MCP servers through to the `Query` handler, matching the Python SDK (previously these were Client-only)
- **`can_use_tool` validation:** String prompts with `can_use_tool` now raise `ArgumentError` (streaming mode required); conflicting `permission_prompt_tool_name` also raises early
- **`session_id` parity:** One-shot queries now send `session_id: ''` (was `'default'`), matching Python SDK behavior
- **Premature stdin close:** Added `wait_for_result_and_end_input` that holds stdin open until the first result when hooks or SDK MCP servers need control message exchange
- **`stream_input` stdin leak:** Moved `end_input` to `ensure` block so stdin is always closed even when the stream enumerator raises
- **`Async::Condition` race:** Added `@first_result_received` flag guard to prevent lost signals when result arrives before `wait` is called

#### CLI Transport Parity
- **File checkpointing:** Moved from deprecated `--enable-file-checkpointing` CLI flag to `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING` environment variable
- **Partial messages:** Now also sets `CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING=1` environment variable when `include_partial_messages` is enabled
- **Tools preset:** `ToolsPreset` objects and preset hashes now map to `--tools default` (was `--tools <json>`)
- **Plugins:** Changed from `--plugins <json>` to `--plugin-dir <path>` per-plugin, matching current CLI interface
- **Plugin type:** `SdkPluginConfig` now defaults to `type: 'local'` (was `'plugin'`), normalizes legacy `'plugin'` type
- **Rewind control request:** Changed key from `userMessageUuid` to `user_message_id` for Python SDK parity
- **Settings file with sandbox:** When sandbox is enabled and settings is a file path, now reads and parses the file to merge sandbox settings (raises on missing/invalid files instead of silently dropping settings)

#### Hook Input Parsing
- **Falsy value preservation:** `parse_hook_input` now uses `key?`-based lookup instead of `||`, correctly preserving `false` and `nil` values (e.g., `stop_hook_active: false`)
- **Empty hooks normalization:** `query()` now skips empty matcher lists and normalizes hooks to `nil` when no matchers survive, preventing unnecessary 60s close-wait timeout

### Changed
- **`build_command` refactored:** Extracted `build_settings_args`, `build_tools_args`, `build_output_format_args`, `build_mcp_servers_args`, `build_plugins_args` private helpers to reduce method complexity

## [0.8.0] - 2026-03-05

Port of Python SDK v0.1.46 features.

### Added

#### Task Message Types
- `TaskStartedMessage`, `TaskProgressMessage`, `TaskNotificationMessage` — typed `SystemMessage` subclasses for background task lifecycle events
- `TASK_NOTIFICATION_STATUSES` constant (`completed`, `failed`, `stopped`)
- `MessageParser` dispatches on `subtype` within `system` messages, falling back to generic `SystemMessage` for unknown subtypes

#### MCP Server Control
- `reconnect_mcp_server(server_name)` on `Query` and `Client` — retry failed MCP server connections
- `toggle_mcp_server(server_name, enabled)` on `Query` and `Client` — enable/disable MCP servers live
- `stop_task(task_id)` on `Query` and `Client` — stop a running background task

#### Subagent Context on Hook Inputs
- `agent_id` and `agent_type` attributes on `PreToolUseHookInput`, `PostToolUseHookInput`, `PostToolUseFailureHookInput`, `PermissionRequestHookInput`
- Populated when hooks fire inside subagents, allowing attribution of tool calls to specific agents

#### Result Message
- `stop_reason` attribute on `ResultMessage` (e.g., `'end_turn'`, `'max_tokens'`, `'stop_sequence'`)

#### Typed MCP Status Response
- `McpServerInfo`, `McpToolAnnotations`, `McpToolInfo`, `McpServerStatus`, `McpStatusResponse` types
- `.parse` class methods for hydrating from raw CLI response hashes
- `MCP_SERVER_CONNECTION_STATUSES` constant (`connected`, `failed`, `needs-auth`, `pending`, `disabled`)

#### Session Browsing
- `ClaudeAgentSDK.list_sessions(directory:, limit:, include_worktrees:)` — list sessions from `~/.claude/projects/` JSONL files
- `ClaudeAgentSDK.get_session_messages(session_id:, directory:, limit:, offset:)` — reconstruct conversation chain from session transcript
- `SDKSessionInfo` type with `session_id`, `summary`, `last_modified`, `file_size`, `custom_title`, `first_prompt`, `git_branch`, `cwd`
- `SessionMessage` type with `type`, `uuid`, `session_id`, `message`
- Pure filesystem operations — no CLI subprocess required
- Git worktree-aware session scanning
- `parentUuid` chain walking with cycle detection for robust conversation reconstruction

### Fixed
- **`McpToolAnnotations.parse` losing `false` values:** `readOnly: false` was evaluated as `false || nil → nil` due to `||` short-circuiting. Now uses `.key?` to check presence before falling back to snake_case keys.

## [0.7.3] - 2026-02-26

### Fixed
- **String-keyed JSON schema crash:** Libraries like [RubyLLM](https://github.com/crmne/ruby_llm) that deep-stringify schema keys (e.g., `{ 'type' => 'object', 'properties' => { ... } }`) were misidentified as simple type-mapping schemas, causing each top-level key to be treated as a parameter name instead of passing the schema through. Now both symbol-keyed and string-keyed schemas are detected and normalized correctly. (PR #9 by [@iuhoay](https://github.com/iuhoay))
- **Shallow key symbolization:** `convert_schema` used `transform_keys` (shallow) which left nested property keys as strings, breaking downstream `MCP::Tool::InputSchema` construction. Now uses deep symbolization recursively.
- **Guard ordering crash:** `convert_schema` and `convert_input_schema` accessed `schema[:type]` before the `schema.is_a?(Hash)` guard, which would raise `NoMethodError` on `nil` input.
- **Schema detection tightened:** Pre-built schema detection now requires `type == 'object'` and `properties.is_a?(Hash)`, preventing false positives when a simple schema happens to have parameters named `type` and `properties`.

### Added
- `ClaudeAgentSDK.deep_symbolize_keys` utility method for recursive hash key symbolization

## [0.7.2] - 2026-02-21

### Fixed
- **Unknown content block crash:** Unrecognized content block types (e.g., `document` blocks from PDF reading) now return `UnknownBlock` instead of raising `MessageParseError`, aligning with the Python SDK's forward-compatible design
- **Unknown message type crash:** Unrecognized message types now return `nil` (skipped by callers) instead of raising
- **Empty input schema crash:** Tools with no parameters (`input_schema: {}`) caused `MCP::Tool::InputSchema` validation failure (`required` array must have at least 1 item per JSON Schema draft-04). Now omits `required` when empty.

### Added
- `UnknownBlock` type that preserves raw data for unrecognized content block types

### Changed
- **Breaking (minor):** `MessageParser.parse` no longer raises `MessageParseError` for unknown message types — returns `nil` instead. If you were rescuing `MessageParseError` to handle unknown types, check for `nil` return values instead.
- **Breaking (minor):** `MessageParser.parse_content_block` no longer raises `MessageParseError` for unknown content block types — returns `UnknownBlock` instead. Content block iteration using `is_a?` filtering (e.g., `block.is_a?(TextBlock)`) is unaffected.

## [0.7.1] - 2026-02-21

### Fixed
- **Transport initialization crash:** `SubprocessCLITransport#initialize` used raw `options` parameter instead of resolved `@options` on lines 19, 20, 27 — caused `NoMethodError: undefined method 'cli_path' for nil` when using single-arg form (how `Client.new` calls it)

## [0.7.0] - 2026-02-20

### Added

#### Thinking Configuration
- `ThinkingConfigAdaptive`, `ThinkingConfigEnabled`, `ThinkingConfigDisabled` classes for structured thinking control
- `thinking` option on `ClaudeAgentOptions` — takes precedence over deprecated `max_thinking_tokens`
  - `ThinkingConfigAdaptive` → 32,000 token default budget
  - `ThinkingConfigEnabled(budget_tokens:)` → explicit budget
  - `ThinkingConfigDisabled` → 0 tokens (thinking off)
- `effort` option on `ClaudeAgentOptions` — maps to `--effort` CLI flag (`'low'`, `'medium'`, `'high'`)

#### Tool Annotations
- `annotations` attribute on `SdkMcpTool` for MCP tool annotations (e.g., `readOnlyHint`, `title`)
- `annotations:` keyword on `ClaudeAgentSDK.create_tool`
- Annotations included in `SdkMcpServer#list_tools` responses

#### Hook Enhancements
- `tool_use_id` attribute on `PreToolUseHookInput` and `PostToolUseHookInput`
- `additional_context` attribute on `PreToolUseHookSpecificOutput`

#### Message Enhancements
- `tool_use_result` attribute on `UserMessage` for tool response data
- `MessageParser` populates `tool_use_result` from CLI output

### Changed

#### Architecture: Always Streaming Mode (BREAKING for internal API)
- **`SubprocessCLITransport`** now always uses `--input-format stream-json` — removed `--print` mode and `--agents` CLI flag
- **`SubprocessCLITransport.new`** still accepts `(prompt, options)` for compatibility but ignores the prompt argument (always uses streaming mode)
- **`query()`** now uses the full control protocol internally (Query handler + initialize handshake), matching the Python SDK
- **Agents** are sent via the `initialize` control request over stdin instead of CLI `--agents` flag, avoiding OS ARG_MAX limits
- **`query()`** now supports SDK MCP servers and `can_use_tool` callbacks (previously Client-only)

#### Empty System Prompt
- When `system_prompt` is `nil`, passes `--system-prompt ""` to CLI for predictable behavior without the default Claude Code system prompt

## [0.6.3] - 2026-02-18

### Fixed
- **ProcessError stderr:** Real stderr output is now included in `ProcessError` exceptions (was always "No stderr output captured")
- **Rate limit events:** Added `RateLimitEvent` type and `rate_limit_event` message parsing support

## [0.6.2] - 2026-02-17

### Fixed
- **Large prompt `Errno::E2BIG` crash:** Prompts exceeding 200KB are now piped via stdin instead of passed as CLI arguments, avoiding the OS `ARG_MAX` limit (typically 1MB on macOS/Linux). This fixes `CLIConnectionError: Failed to start Claude Code: Argument list too long` when using `query()` with large prompts.
- **Stderr pipe deadlock (`Errno::EPIPE`):** Always drain stderr in a background thread, even when `stderr` option is not set. Without this, `--verbose` output fills the 64KB OS pipe buffer, the subprocess blocks on write, and all pipes stall. Previously only manifested with long-running Opus sessions.

## [0.6.0] - 2026-02-13

### Added
- **Configurable control request timeout:** New `CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS` environment variable (default 1200s) for tuning the control protocol timeout — essential for long-running agent sessions and agent teams
- **`ControlRequestTimeoutError`:** Dedicated error class (`< CLIConnectionError`) raised on control request timeouts, enabling typed exception handling instead of string matching

### Fixed
- **camelCase `requestId` fallback:** All control message routing (`read_messages`, `handle_control_response`, `handle_control_request`) now tolerates both `request_id` and `requestId` keys from the CLI
- **Outbound `requestId` parity:** Control requests and responses now include both `request_id` and `requestId` for maximum CLI compatibility
- **Pending request unblocking:** Transport errors now signal all pending control request conditions, preventing callers from hanging until timeout
- **Error object in message queue:** `read_messages` rescue now enqueues the exception object (not just `e.message`), preserving error class for typed handling
- **Thread-safe CLI discovery:** `find_cli` uses `Open3.capture2` instead of backtick shell for thread safety
- **Robust process cleanup:** `close` now uses SIGTERM → 2s grace period → SIGKILL escalation (was immediate SIGTERM with no fallback), handles `Errno::ESRCH` for already-dead processes, and logs cleanup warnings instead of silently swallowing errors

## [0.5.0] - 2026-02-07

### Added
- **Default configuration:** `ClaudeAgentSDK.configure` block for setting default options that merge with every `ClaudeAgentOptions` instance, ideal for Rails initializers (PR #8)
- `ClaudeAgentSDK.reset_configuration` for resetting defaults (useful in tests)
- Deep merge for `env` and `mcp_servers` hashes; provided values override configured defaults
- `OPTION_DEFAULTS` constant on `ClaudeAgentOptions` for introspectable non-nil defaults

### Changed
- `ClaudeAgentOptions#initialize` now uses `**kwargs` internally to correctly distinguish caller-provided values from method signature defaults

## [0.4.2] - 2026-02-07

### Fixed
- **MCP response fidelity:** Non-text content (images, binary data) is now preserved in SDK MCP tool responses instead of being silently dropped
- **MCP error key:** Tool error flag is now sent as `isError` (camelCase) matching the JSON-RPC spec, instead of `is_error` which the CLI ignored
- **MCP structured content:** `structuredContent` is now passed through in tool responses
- **ENV pollution:** `query()` and `Client.connect` no longer mutate the global `ENV`; entrypoint is passed via transport options
- **Symbol key env:** Fixed symbol keys in `env` option causing spawn failures (PR #7)

### Added
- `ClaudeAgentSDK.flexible_fetch` helper for tolerant hash key lookup (symbol/string, camelCase/snake_case)
- Gated real CLI integration tests (`RUN_REAL_INTEGRATION=1`) with budget cap
- `CLAUDE.md` architecture guide for contributors

## [0.4.1] - 2026-02-05

### Added

#### Hook Parity
- Added hook event support for `PostToolUseFailure`, `Notification`, `SubagentStart`, and `PermissionRequest`
- Expanded `SubagentStop` hook inputs with `agent_id`, `agent_transcript_path`, and `agent_type`
- Added hook-specific outputs for new hook events
- Added `updatedMCPToolOutput` support to `PostToolUse` hook outputs

#### MCP Status APIs
- `get_mcp_status` on `Query` and `Client` for live MCP connection status (streaming mode)
- `get_server_info` on `Client` as a parity alias for server initialization info

### Fixed
- Hook input parsing now supports both symbol and string keys
- Hook callback timeouts are enforced and control request cancellation is handled cleanly

## [0.4.0] - 2026-01-06

### Added

#### File Checkpointing & Rewind
- `enable_file_checkpointing` option in `ClaudeAgentOptions` for enabling file state checkpointing
- `rewind_files(user_message_uuid)` method on `Query` and `Client` classes
- `uuid` field on `UserMessage` for tracking message identifiers for rewind support

#### Beta Features Support
- `SDK_BETAS` constant with available beta features (e.g., `"context-1m-2025-08-07"`)
- `betas` option in `ClaudeAgentOptions` for enabling beta features

#### Tools Configuration
- `tools` option for base tools selection (separate from `allowed_tools`)
- Supports array of tool names, empty array `[]`, or `ToolsPreset` object
- `ToolsPreset` class for preset-based tool configuration
- `append_allowed_tools` option to append tools to the allowed list

#### Sandbox Settings
- `SandboxSettings` class for isolated command execution configuration
- `SandboxNetworkConfig` class for network isolation settings
- `SandboxIgnoreViolations` class for configuring violation handling
- `sandbox` option in `ClaudeAgentOptions` for sandbox configuration
- Automatic merging of sandbox settings into the main settings JSON

#### Additional Types
- `SystemPromptPreset` class for preset-based system prompts

### Technical Details
- All new CLI flags properly passed to Claude Code subprocess
- Sandbox settings merged into `--settings` JSON for CLI compatibility
- UserMessage UUID parsed from CLI output for rewind support

## [0.2.0] - 2025-10-17

### Changed
- **BREAKING:** Updated minimum Ruby version from 3.0+ to 3.2+ (required by official MCP SDK)
- **Major refactoring:** SDK MCP server now uses official Ruby MCP SDK (`mcp` gem v0.4) internally
- Internal implementation migrated from custom MCP to wrapping official `MCP::Server`

### Added
- Official Ruby MCP SDK (`mcp` gem) as runtime dependency
- Full MCP protocol compliance via official SDK
- `handle_json` method for protocol-compliant JSON-RPC handling

### Improved
- Better long-term maintenance by leveraging official SDK updates
- Aligned with Python SDK implementation pattern (using official MCP library)
- All tests passing with full backward compatibility maintained

### Technical Details
- Creates dynamic `MCP::Tool`, `MCP::Resource`, and `MCP::Prompt` classes from block-based definitions
- User-facing API remains unchanged - no breaking changes for Ruby 3.2+ users
- Maintains backward-compatible methods (`list_tools`, `call_tool`, etc.)

## [0.1.3] - 2025-10-15

### Added
- **MCP resource support:** Full support for MCP resources (list, read, subscribe operations)
- **MCP prompt support:** Support for MCP prompts (list, get operations)
- **Streaming input support:** Added streaming capabilities for input handling
- Feature complete MCP implementation matching Python SDK functionality

## [0.1.2] - 2025-10-14

### Fixed
- **Critical:** Replaced `Async::Process` with Ruby's built-in `Open3` for subprocess management
- Fixed "uninitialized constant Async::Process" error that prevented the gem from working
- Process management now uses standard Ruby threads instead of async tasks
- All tests passing

## [0.1.1] - 2025-10-14

### Fixed
- Added `~/.claude/local/claude` to CLI search paths to detect Claude Code in its default installation location
- Fixed issue where SDK couldn't find Claude Code when accessed via shell alias

### Added
- Comprehensive test suite (RSpec)
- Test documentation in spec/README.md

### Changed
- Marked as unofficial SDK in README and gemspec
- Updated repository URLs to reflect community-maintained status

## [0.1.0] - 2025-10-14

### Added
- Initial release of Claude Agent SDK for Ruby
- Support for `query()` function for simple one-shot interactions
- `ClaudeSDKClient` class for bidirectional, stateful conversations
- Custom tool support via SDK MCP servers
- Hook support for all major hook events
- Comprehensive error handling
- Full async/await support using the `async` gem
- Examples demonstrating common use cases
