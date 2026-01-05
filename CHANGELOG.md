# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - Unreleased

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
- All 86 tests passing with full backward compatibility maintained

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
- All 86 tests passing

## [0.1.1] - 2025-10-14

### Fixed
- Added `~/.claude/local/claude` to CLI search paths to detect Claude Code in its default installation location
- Fixed issue where SDK couldn't find Claude Code when accessed via shell alias

### Added
- Comprehensive test suite with 86 passing tests
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
