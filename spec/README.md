# Test Suite

This directory contains the test suite for the Claude Agent SDK for Ruby.

## Running Tests

### Run all tests
```bash
bundle exec rspec
```

### Run with detailed output
```bash
bundle exec rspec --format documentation
```

### Run specific test file
```bash
bundle exec rspec spec/unit/message_parser_spec.rb
```

### Run specific test by line number
```bash
bundle exec rspec spec/unit/types_spec.rb:42
```

### Run with profiling (show slowest 10 tests)
```bash
PROFILE=1 bundle exec rspec
```

## Test Structure

### Unit Tests (`spec/unit/`)

Unit tests verify individual components in isolation:

- **errors_spec.rb** - Tests for error classes and their behavior
- **types_spec.rb** - Tests for all type classes (Messages, ContentBlocks, Options, etc.)
- **message_parser_spec.rb** - Tests for JSON message parsing and validation
- **sdk_mcp_server_spec.rb** - Tests for SDK MCP server functionality and tool execution
- **transport_spec.rb** - Tests for the Transport abstract base class

### Integration Tests (`spec/integration/`)

Integration tests verify how components work together:

- **query_spec.rb** - End-to-end workflow tests demonstrating component interaction

**Note:** Integration tests are tagged with `:integration` and are skipped by default. To run them:

```bash
RUN_INTEGRATION=1 bundle exec rspec
```

Integration tests that actually connect to Claude Code CLI require it to be installed.

### Test Helpers (`spec/support/`)

- **test_helpers.rb** - Shared test fixtures and helper methods used across test files

## Test Configuration

Test configuration is managed in `spec_helper.rb`:

- **Random order** - Tests run in random order to detect order dependencies
- **Persistence** - Test status is saved to `.rspec_status` for `--only-failures` and `--next-failure`
- **No monkey patching** - RSpec's clean syntax without global method pollution
- **Integration filter** - Integration tests skipped by default (enable with `RUN_INTEGRATION=1`)

## Test Coverage

The test suite covers:

### Error Handling
- All error class instantiation and attributes
- Error inheritance hierarchy
- Error message formatting

### Type System
- Content blocks (TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock)
- Messages (UserMessage, AssistantMessage, SystemMessage, ResultMessage, StreamEvent)
- ClaudeAgentOptions with all configuration fields
- Permission types (PermissionResultAllow, PermissionResultDeny, PermissionUpdate)
- Hook matchers

### Message Parser
- Parsing all message types from JSON
- Content block parsing
- Validation and error handling for malformed messages
- Missing required field detection

### SDK MCP Server
- Tool creation with schemas
- Server configuration
- Tool execution and error handling
- JSON schema generation from Ruby types

### Transport
- Abstract base class interface
- NotImplementedError for unimplemented methods

### Integration
- Component interaction verification
- SDK MCP server integration
- Hook configuration and execution
- Permission callback handling
- End-to-end workflow simulation

**Total:** Run `bundle exec rspec` to see the current example count.

## Writing New Tests

### Test Fixtures

Use the fixtures provided in `spec/support/test_helpers.rb`:

```ruby
include TestHelpers

# Use sample messages
message = sample_user_message
result = sample_result_message
```

### Mock Transports

Create mock transports for testing without CLI:

```ruby
mock = mock_transport(
  messages: [sample_user_message, sample_result_message]
)
```

### Testing SDK Tools

```ruby
tool = ClaudeAgentSDK.create_tool('test_tool', 'Description', { arg: :string }) do |args|
  { content: [{ type: 'text', text: "Result: #{args[:arg]}" }] }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(
  name: 'test_server',
  tools: [tool]
)

result = server[:instance].call_tool('test_tool', { arg: 'value' })
```

## Continuous Integration

In CI environments, tests run with:

- Documentation formatter for better output visibility
- Random seed for reproducibility
- Strict failure reporting

The test suite should always pass with 0 failures before merging.

## Troubleshooting

### Tests hanging or timing out

If tests hang, it may be due to:
- Process not terminating properly in transport tests
- Async operations not completing

### LoadError or require failures

Ensure dependencies are installed:

```bash
bundle install
```

### Integration tests failing

Integration tests require Claude Code CLI to be installed:

```bash
npm install -g @anthropic-ai/claude-code
```

Check installation:

```bash
which claude
claude -v
```

## Contributing

When adding new features:

1. Write unit tests for new classes/methods
2. Add integration tests for feature workflows
3. Update this README if adding new test categories
4. Ensure all tests pass: `bundle exec rspec`
5. Aim for comprehensive coverage of error cases and edge conditions
