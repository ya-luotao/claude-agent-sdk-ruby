# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
