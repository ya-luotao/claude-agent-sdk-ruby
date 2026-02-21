# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.2] - 2026-02-21

### Fixed
- **Empty input schema crash:** Tools with no parameters (`input_schema: {}`) caused `MCP::Tool::InputSchema` validation failure (`required` array must have at least 1 item per JSON Schema draft-04). Now omits `required` when empty.
- **RuboCop offense:** Removed redundant `else` clause in `MessageParser.parse`

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
