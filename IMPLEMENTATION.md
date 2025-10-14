# Claude Agent SDK Ruby Implementation

This document provides an overview of the Ruby implementation of the Claude Agent SDK, based on the Python version.

## Implementation Summary

The Ruby SDK has been fully implemented with the following components:

### Core Components (~1,354 lines of code)

1. **Transport Layer** (411 lines)
   - `transport.rb` - Abstract transport interface (44 lines)
   - `subprocess_cli_transport.rb` - CLI subprocess implementation (367 lines)
   - Features: Process management, stderr handling, version checking, command building

2. **Query Class** (424 lines)
   - `query.rb` - Full control protocol implementation
   - Features:
     - Bidirectional control request/response routing
     - Hook callback execution
     - Permission callback handling
     - Message streaming with async queues
     - Initialization handshake
     - SDK MCP server support (partial)
     - Control operations: interrupt, set_permission_mode, set_model

3. **Type System** (358 lines)
   - `types.rb` - Complete type definitions
   - Message types: UserMessage, AssistantMessage, SystemMessage, ResultMessage, StreamEvent
   - Content blocks: TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock
   - Configuration: ClaudeAgentOptions with all major settings
   - MCP server configs: McpStdioServerConfig, McpSSEServerConfig, McpHttpServerConfig, McpSdkServerConfig
   - Permission types: PermissionResultAllow, PermissionResultDeny, PermissionUpdate
   - Hook types: HookMatcher, HookCallback

4. **Message Parser** (103 lines)
   - `message_parser.rb` - JSON message parsing
   - Handles all message types with proper error handling

5. **Error Handling** (53 lines)
   - `errors.rb` - Comprehensive error classes
   - ClaudeSDKError, CLIConnectionError, CLINotFoundError, ProcessError, CLIJSONDecodeError, MessageParseError

6. **Main Library** (256 lines)
   - `lib/claude_agent_sdk.rb` - Entry point with query() and Client class
   - Features:
     - Simple `query()` function for one-shot queries
     - Full-featured `Client` class for bidirectional conversations
     - Hooks support
     - Permission callbacks support
     - Advanced features: interrupt, set_permission_mode, set_model, server_info

### Examples (~315 lines)

1. **quick_start.rb** - Basic usage examples with query()
2. **client_example.rb** - Interactive client usage
3. **hooks_example.rb** - Hook callback examples
4. **permission_callback_example.rb** - Permission callback examples

### Documentation

- **README.md** - Comprehensive documentation with examples
- **CHANGELOG.md** - Version history
- **IMPLEMENTATION.md** - This file

## Architecture

The Ruby SDK follows the Python SDK's architecture closely:

```
┌─────────────────────────────────────────┐
│           User Application              │
│  (query() or Client with callbacks)     │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│         Query (Control Protocol)        │
│  - Hook execution                       │
│  - Permission callbacks                 │
│  - Message routing                      │
│  - Control requests/responses           │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│     SubprocessCLITransport              │
│  - Process management                   │
│  - stdin/stdout/stderr handling         │
│  - Command building                     │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│         Claude Code CLI                 │
│  (External Node.js process)             │
└─────────────────────────────────────────┘
```

## Key Design Decisions

1. **Async Runtime**: Uses the `async` gem (Ruby's async/await runtime) instead of Python's `anyio`
2. **Message Passing**: Uses `Async::Queue` for message streaming instead of memory object streams
3. **Synchronization**: Uses `Async::Condition` for control request/response coordination
4. **Naming**: Follows Ruby conventions (snake_case) while maintaining API similarity
5. **Callbacks**: Uses Ruby procs/lambdas for hooks and permission callbacks

## Features Implemented

### ✅ Completed

- [x] Basic query() function for simple queries
- [x] Full Client class for interactive conversations
- [x] Transport abstraction with subprocess implementation
- [x] Complete message type system
- [x] Message parsing with error handling
- [x] Control protocol (bidirectional communication)
- [x] Hook support (PreToolUse, PostToolUse, etc.)
- [x] Permission callback support
- [x] Interrupt capability
- [x] Dynamic permission mode changes
- [x] Dynamic model changes
- [x] Server info retrieval
- [x] Comprehensive error handling
- [x] Working examples for all features

### 🚧 Partial Implementation

- [ ] SDK MCP server support (structure in place, but tool execution not implemented)
- [ ] Full MCP protocol methods (only initialize, tools/list, tools/call basics)

### ⏱️ Not Yet Implemented

- [ ] Test suite (RSpec tests)
- [ ] Full MCP server tool decorator and execution
- [ ] Streaming input support (async iterables for prompt)
- [ ] Session forking
- [ ] Agent definitions
- [ ] Setting sources control
- [ ] Partial messages streaming

## Comparison with Python SDK

### Similarities
- Same overall architecture
- Same message types and structures
- Same control protocol
- Same hook and permission callback concepts
- Similar API design

### Differences

| Feature | Python | Ruby |
|---------|--------|------|
| Async runtime | anyio | async gem |
| Message queue | MemoryObjectStream | Async::Queue |
| Synchronization | anyio.Event | Async::Condition |
| Type hints | Yes (TypedDict, dataclass) | No (uses regular classes) |
| MCP integration | Full with mcp package | Partial (manual routing) |
| Async iterators | Built-in | Uses blocks/enumerators |

## Usage Comparison

### Python
```python
import anyio
from claude_agent_sdk import query, ClaudeAgentOptions

async def main():
    async for message in query(prompt="Hello"):
        print(message)

anyio.run(main)
```

### Ruby
```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  ClaudeAgentSDK.query(prompt: "Hello") do |message|
    puts message
  end
end.wait
```

## Dependencies

- **async** (~2.0) - Async I/O runtime
- **async-io** (~1.0) - I/O support for async
- Ruby 3.0+ required

## Testing

Currently, the SDK has no automated tests. Recommended test structure:

```
spec/
├── unit/
│   ├── types_spec.rb
│   ├── message_parser_spec.rb
│   ├── errors_spec.rb
│   └── transport_spec.rb
└── integration/
    ├── query_spec.rb
    └── client_spec.rb
```

## Future Enhancements

1. **Complete MCP Support**
   - Implement full SDK MCP server with tool decorator
   - Support all MCP protocol methods
   - Resource and prompt support

2. **Testing**
   - Unit tests for all components
   - Integration tests with mock CLI
   - E2E tests with actual Claude Code

3. **Additional Features**
   - Streaming input support
   - Session forking
   - Agent definitions
   - Partial message streaming

4. **Performance**
   - Optimize message parsing
   - Better async task management
   - Connection pooling for multiple queries

5. **Developer Experience**
   - Better error messages
   - Debug logging
   - Type documentation (YARD)
   - More examples

## Conclusion

The Ruby SDK successfully implements the core functionality of the Python SDK, providing a robust foundation for building Claude-powered applications in Ruby. The implementation prioritizes correctness and maintainability while following Ruby idioms and conventions.

Total implementation: ~1,600 lines of code + documentation and examples.
