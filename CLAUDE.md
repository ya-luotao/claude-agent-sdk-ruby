# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Unofficial, community-maintained Ruby SDK for Claude Agent (gem: `claude-agent-sdk`). Wraps the Claude Code CLI as a subprocess, communicating via stream-JSON over stdin/stdout. Requires Ruby 3.2+ and Claude Code CLI 2.0.0+.

Runtime dependencies: `async` (~2.0) for concurrency, `mcp` (>= 0.6, < 1) for MCP protocol compliance.

## Common Commands

```bash
bundle install                              # Install dependencies
bundle exec rspec                           # Run all unit tests (integration tests excluded by default)
bundle exec rspec spec/unit/types_spec.rb   # Run a single spec file
bundle exec rspec spec/unit/types_spec.rb:42  # Run a single test by line number
RUN_INTEGRATION=1 bundle exec rspec         # Include integration tests (requires Claude Code CLI)
bundle exec rubocop                         # Run linter
bundle exec rake                            # Run default task (spec + rubocop)
bundle exec rake build                      # Build the gem
```

## Architecture

### Layered Design

```
User code
  ├── ClaudeAgentSDK.query()     ← One-shot/streaming, defined in lib/claude_agent_sdk.rb
  └── ClaudeAgentSDK::Client     ← Bidirectional sessions, defined in lib/claude_agent_sdk.rb
        │
        ▼
      Query (lib/claude_agent_sdk/query.rb)
        - Bidirectional control protocol (control_request / control_response routing)
        - Hook callback dispatch with typed inputs (PreToolUseHookInput, etc.)
        - Permission callback handling (can_use_tool)
        - SDK MCP server request routing (tools/call, resources/read, prompts/get)
        - Message queue (Async::Queue) separating control messages from SDK messages
        │
        ▼
      SubprocessCLITransport (lib/claude_agent_sdk/subprocess_cli_transport.rb)
        - Spawns `claude` CLI via Open3.popen3
        - CLI command built from ClaudeAgentOptions by CommandBuilder (lib/claude_agent_sdk/command_builder.rb)
        - Reads stdout as newline-delimited JSON, writes stdin for streaming mode
        - Stderr handling in a separate Thread
        │
        ▼
      Claude Code CLI (external Node.js process)
```

### Two API Entry Points

- **`query()`** — Simple function interface. Creates a `SubprocessCLITransport` directly, reads messages via `transport.read_messages`, parses with `MessageParser`. No control protocol. Good for one-shot queries and streaming input via Enumerators.

- **`Client`** — Full-featured bidirectional sessions. Accepts optional `transport_class` (defaults to `SubprocessCLITransport`) and `transport_args` for custom transports. Creates transport, instantiates a `Query` handler that runs `read_messages` in an async task, routes control messages internally, and exposes SDK messages via `Async::Queue`. Supports hooks, permission callbacks, SDK MCP servers, interrupt, model switching, and file rewind.

### SDK MCP Servers

Custom tools run in-process (no subprocess). The flow:
1. User defines tools via `ClaudeAgentSDK.create_tool` → returns `SdkMcpTool`
2. `create_sdk_mcp_server` wraps tools in `SdkMcpServer`, which creates dynamic `MCP::Tool` subclasses and delegates to the official `MCP::Server`
3. The server config hash (`{ type: 'sdk', instance: server }`) is stored in `ClaudeAgentOptions.mcp_servers`
4. `Client.connect` extracts SDK server instances and passes them to `Query`
5. `Query.handle_control_request` dispatches `mcp_message` subtypes to the server's `list_tools` / `call_tool` / etc.

### Message Flow

CLI outputs newline-delimited JSON. `SubprocessCLITransport.read_messages` parses it and yields raw hashes. In `Client` mode, `Query.read_messages` intercepts `control_response` and `control_request` types, putting regular messages on `@message_queue`. `MessageParser.parse` converts raw hashes into typed objects (`UserMessage`, `AssistantMessage`, `SystemMessage`, `ResultMessage`, `StreamEvent`).

### Control Protocol

Only active in streaming/Client mode. Uses `Async::Condition` for request-response coordination:
- **Outbound requests** (SDK → CLI): `send_control_request` writes JSON, waits on condition, returns response
- **Inbound requests** (CLI → SDK): `handle_control_request` dispatches to `can_use_tool`, `hook_callback`, or `mcp_message` handlers, writes response back

### Observer / Instrumentation

Optional observability layer for tracing agent sessions (e.g., Langfuse via OpenTelemetry).

- **`Observer`** module (`lib/claude_agent_sdk/observer.rb`) — base interface with no-op defaults: `on_user_prompt(prompt)`, `on_message(message)`, `on_error(error)`, `on_close`
- **`OTelObserver`** (`lib/claude_agent_sdk/instrumentation/otel.rb`) — emits OTel spans with `gen_ai.*` + OpenInference semantic conventions. Lazy-requires `opentelemetry-api`; not loaded unless user explicitly `require 'claude_agent_sdk/instrumentation'`
- Observers registered via `ClaudeAgentOptions.new(observers: [...])`. Supports callable factories (lambdas) for thread-safe global defaults in Rails
- `resolve_observers` materializes callables into fresh instances per query/session; `notify_observers` calls methods with `rescue StandardError` so observers never crash the pipeline
- `on_user_prompt` is called before the prompt is sent to stdin (before CLI responds with InitMessage), so the OTel observer buffers it and applies to the root span in `start_trace`

### SessionStore / Transcript Mirroring

Optional adapter for mirroring session transcripts to external storage (the subprocess still writes the local-disk transcript; the store gets a secondary copy).

- **`SessionStore`** (`lib/claude_agent_sdk/session_store.rb`) — only `#append` and `#load` are required; the SDK probes optional methods via `SessionStore.implements?` (duck typing — adapters need not subclass)
- Keys/entries cross the adapter boundary as Hashes with **string keys** (e.g., `{ 'project_key' => ..., 'session_id' => ... }`)
- **`TranscriptMirrorBatcher`** buffers `transcript_mirror` stdout frames and flushes to `#append` per-turn (`batched`, default) or near-realtime (`eager`); failures retry with backoff but never raise — they surface as `MirrorErrorMessage`
- Retried batches may overlap prior writes, so adapters should dedupe by `entry["uuid"]`
- `lib/claude_agent_sdk/testing/session_store_conformance.rb` provides a shared conformance suite for custom adapters

### Session Management

`sessions.rb` / `session_resume.rb` / `session_mutations.rb` implement session listing (`SDKSessionInfo`), resume (can materialize the transcript from a SessionStore when the local file is absent), forking, and mutations.

### FiberBoundary (fiber safety)

`async` installs a Fiber scheduler, but most Ruby libraries (pg, mysql2, ActiveRecord pools) key state on `Thread.current` and are thread-safe, not fiber-safe. `FiberBoundary.invoke` (`lib/claude_agent_sdk/fiber_boundary.rb`) hops every user-supplied callback (tool handlers, hooks, permission callbacks, message blocks, observers) to a plain thread before invoking it. Consequence: the thread hop severs `break`/`return`/`next` from the surrounding method — SDK loops yielding user callbacks must keep loop control outside the invoked block (see `Client#receive_response`; user `break` is bridged via `.invoke_iteration`).

### Global Configuration

`ClaudeAgentSDK.configure { |c| c.default_options = { ... } }` (`lib/claude_agent_sdk/configuration.rb`) sets defaults merged into every request — the Rails-initializer pattern. Per-call `ClaudeAgentOptions` override the defaults.

## Key Conventions

- All source in `lib/claude_agent_sdk/`, entry point is `lib/claude_agent_sdk.rb`
- Types use plain Ruby classes with `attr_accessor` and keyword args (no Struct/Data)
- Hook inputs are typed classes inheriting from `BaseHookInput`; hook outputs use `to_h` for serialization with camelCase keys for CLI compatibility
- `ClaudeAgentOptions` is the central config object (~30 fields); uses `dup_with` for immutable-style updates
- `to_h` methods on config types convert Ruby snake_case to CLI camelCase (e.g., `auto_allow_bash_if_sandboxed` → `autoAllowBashIfSandboxed`)
- RuboCop config: max line length 181 (set in `.rubocop_todo.yml`), max method length 30 (large core files like `query.rb`/`types.rb` excluded), Style/Documentation disabled
- Tests use `expect` syntax only (no `should`), `disable_monkey_patching!` enabled
- Test helpers in `spec/support/test_helpers.rb` provide `sample_*` message fixtures and `mock_transport`
