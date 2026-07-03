# Claude Agent SDK for Ruby

![Claude Agent SDK for Ruby banner](assets/claude-agent-sdk-ruby-banner.png)

[![Gem Version](https://badge.fury.io/rb/claude-agent-sdk.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/claude-agent-sdk)

An **unofficial, community-maintained** Ruby SDK for the [Claude Code](https://docs.claude.com/en/docs/claude-code-overview) agent runtime. Not affiliated with or supported by Anthropic.

Official SDKs: [TypeScript](https://github.com/anthropics/claude-agent-sdk-typescript) · [Python](https://github.com/anthropics/claude-agent-sdk-python).

## Why a Ruby SDK?

Ruby powers a massive ecosystem — Rails, Sidekiq, Kamal, countless production web apps — but has no official Claude Agent SDK. This gem fills that gap so Ruby and Rails developers can build AI agents, automate coding workflows, and integrate Claude into existing applications without switching languages or shelling out to Python/Node.

All three SDKs share the same underlying mechanism: they spawn the `claude` CLI as a subprocess and communicate over stream-JSON on stdin/stdout. The wire protocol is identical, so Ruby gets the same capabilities as the official SDKs.

### Comparison with Official SDKs

| Capability | TypeScript | Python | Ruby (this gem) |
|---|:---:|:---:|:---:|
| One-shot `query()` | ✅ | ✅ | ✅ |
| Bidirectional `Client` | ✅ | ✅ | ✅ |
| Streaming input | `AsyncIterable` | `AsyncIterable` | `Enumerator` |
| Custom tools (SDK MCP servers) | `tool()` | `@tool` decorator | `create_tool` block |
| Hooks (all 27 events) | ✅ | ✅ | ✅ |
| Permission callbacks | ✅ | ✅ | ✅ |
| Structured output | ✅ | ✅ | ✅ |
| All 24 message types | ✅ | partial | ✅ |
| [Sandbox](https://github.com/anthropic-experimental/sandbox-runtime) settings | ✅ | partial | ✅ |
| Bare mode (`--bare`) | ✅ | ✅ | ✅ |
| File checkpointing & rewind | ✅ | ✅ | ✅ |
| Session browsing & mutations | ✅ | ✅ | ✅ |
| Programmatic subagents | ✅ | ✅ | ✅ |
| Bundled CLI binary | ✅ | ✅ | — (install `claude` separately) |
| Observability (OTel / Langfuse) | via [Arize](https://github.com/Arize-ai/openinference) | — | ✅ (built-in) |
| Custom transport (pluggable I/O) | — | — | ✅ |
| Rails integration | — | — | ✅ |

**Where Ruby goes further:** Built-in OpenTelemetry observer with Langfuse flow diagram support — no third-party instrumentation library needed. Custom transport support lets you swap the subprocess for any I/O layer (e.g., connect to a remote Claude Code instance over SSH or a container). Rails integration provides a `configure` block for initializers with thread-safe observer factories, and plays well with ActionCable for real-time streaming. Full typed coverage for all 24 CLI message types and all 27 hook events.

**What's missing:** The Ruby gem does not bundle the `claude` CLI binary (`npm install -g @anthropic-ai/claude-code`).

<details>
<summary><strong>Implementation differences from the official SDKs</strong></summary>

TypeScript uses native `async`/`await`. Python uses `async`/`await` with `anyio`. Ruby uses the [`async`](https://github.com/socketry/async) gem with fibers — no `await` keyword needed; blocking calls yield automatically inside an `Async` block:

```ruby
Async do
  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect
  client.query("Hello")
  client.receive_response { |msg| puts msg }
  client.disconnect
end.wait
```

Types use plain Ruby classes with `attr_accessor` and keyword args — no runtime type checking, but the same structure and field names as the TS Zod schemas / Python dataclasses. Subprocess transport uses `Open3.popen3`; wire protocol is identical.

</details>

## Installation

Add this line to your application's Gemfile:

```ruby
# Recommended: use the latest from GitHub for newest features
gem 'claude-agent-sdk', github: 'ya-luotao/claude-agent-sdk-ruby'

# Or use a stable version from RubyGems
gem 'claude-agent-sdk', '~> 0.21.0'
```

Then `bundle install`, or install directly: `gem install claude-agent-sdk`.

**Prerequisites:**
- Ruby 3.2+
- Node.js
- Claude Code 2.0.0+: `npm install -g @anthropic-ai/claude-code`

### Agentic Coding Skill

If you're using [Claude Code](https://claude.ai/claude-code), this repo is a Claude Code plugin marketplace. Add it once, then install the skill:

```bash
/plugin marketplace add ya-luotao/claude-agent-sdk-ruby
/plugin install claude-agent-ruby@claude-agent-sdk-ruby
```

This skill teaches your AI coding assistant about the SDK's APIs, patterns, and best practices.

## Quick Start

```ruby
require 'claude_agent_sdk'

ClaudeAgentSDK.query(prompt: "What is 2 + 2?") do |message|
  puts message
end
```

## Basic Usage: `query()`

`query()` is a function for querying Claude Code. It yields response messages to a block.

```ruby
require 'claude_agent_sdk'

# Simple query
ClaudeAgentSDK.query(prompt: "Hello Claude") do |message|
  puts message.text if message.is_a?(ClaudeAgentSDK::AssistantMessage)
end

# With options
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  system_prompt: "You are a helpful assistant",
  max_turns: 1
)

ClaudeAgentSDK.query(prompt: "Tell me a joke", options: options) do |message|
  puts message
end
```

**Using tools:**

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  allowed_tools: ['Read', 'Write', 'Bash'],
  permission_mode: 'acceptEdits',
  cwd: "/path/to/project"
)

ClaudeAgentSDK.query(prompt: "Create a hello.rb file", options: options) { |message| }
```

**Streaming input** — send multiple messages dynamically instead of a single prompt string:

```ruby
stream = ClaudeAgentSDK::Streaming.from_array(['Hello!', 'What is 2+2?', 'Thanks!'])

ClaudeAgentSDK.query(prompt: stream) do |message|
  puts message if message.is_a?(ClaudeAgentSDK::AssistantMessage)
end
```

See [examples/streaming_input_example.rb](examples/streaming_input_example.rb) and [examples/quick_start.rb](examples/quick_start.rb).

## `Client` — Bidirectional Sessions

`Client` supports interactive conversations with hooks, permission callbacks, and custom tools. It uses streaming mode automatically.

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  client = ClaudeAgentSDK::Client.new

  begin
    client.connect
    client.query("What is the capital of France?")
    client.receive_response { |msg| puts msg }
  ensure
    client.disconnect
  end
end.wait
```

Advanced features (`interrupt`, mid-session model/permission switching, MCP status, custom transports for E2B/SSH/etc.) → see [docs/client.md](docs/client.md).

## Custom Tools (SDK MCP Servers)

Define tools as Ruby procs/lambdas that run in-process — no subprocess, no IPC, direct access to your app state.

```ruby
greet = ClaudeAgentSDK.create_tool('greet', 'Greet a user', { name: :string }) do |args|
  { content: [{ type: 'text', text: "Hello, #{args[:name]}!" }] }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'my-tools', tools: [greet])

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: { tools: server },
  allowed_tools: ['mcp__tools__greet']
)
```

Tool arguments are JSON-Schema-validated (draft4, via the official mcp gem) before your handler runs: the simple `{ name: :string }` idiom marks every parameter required, so a missing argument returns an in-band error to the model instead of invoking the handler with `nil`. Handler exceptions and unknown tools are also reported in-band (`isError: true`) so the model can read the text and self-correct. Opt out globally with `MCP.configure { |c| c.validate_tool_call_arguments = false }`. Schemas the draft4 metaschema rejects (e.g. numeric `exclusiveMinimum`, `$ref`) fall back to validation-disabled with a warning.

Resources, prompts, mixed (SDK + external) servers, RubyLLM schema compatibility → see [docs/mcp-servers.md](docs/mcp-servers.md).

## Hooks & Permission Callbacks

**Hooks** let the Claude Code application invoke your Ruby code at all 27 lifecycle points (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `PreCompact`, etc.) with typed input objects. **Permission callbacks** give you programmatic control over tool execution.

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  hooks: { 'PreToolUse' => [ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [my_hook])] },
  can_use_tool: my_permission_callback
)
```

→ Full event list, typed inputs, and worked examples in [docs/hooks-and-permissions.md](docs/hooks-and-permissions.md).

## Advanced Topics

| Topic | Reference |
|-------|-----------|
| Structured output, thinking config, budget, fallback model, beta features, sandbox, bare mode, file checkpointing | [docs/configuration.md](docs/configuration.md) |
| Session listing, reading, renaming, tagging, deleting, forking, resume-at-message | [docs/sessions.md](docs/sessions.md) |
| OpenTelemetry tracing, Langfuse setup, custom observers | [docs/observability.md](docs/observability.md) |
| Rails integration (fiber safety, ActionCable, sessions, jobs, HTTP MCP, observability initializer) | [docs/rails.md](docs/rails.md) |
| Message, content block, and configuration type reference | [docs/types.md](docs/types.md) |
| Error handling, exception hierarchy, timeout configuration | [docs/errors.md](docs/errors.md) |

## Examples

### Core

| Example | Description |
|---------|-------------|
| [quick_start.rb](examples/quick_start.rb) | Basic `query()` usage with options |
| [client_example.rb](examples/client_example.rb) | Interactive Client usage |
| [message_types_example.rb](examples/message_types_example.rb) | Handling all 24 SDK message types |
| [streaming_input_example.rb](examples/streaming_input_example.rb) | Streaming input for multi-turn conversations |
| [session_resumption_example.rb](examples/session_resumption_example.rb) | Multi-turn conversations with session persistence |
| [structured_output_example.rb](examples/structured_output_example.rb) | JSON schema structured output |
| [error_handling_example.rb](examples/error_handling_example.rb) | Error handling with `AssistantMessage.error` |
| [bare_mode_example.rb](examples/bare_mode_example.rb) | Minimal startup with `bare: true` |
| [sandbox_example.rb](examples/sandbox_example.rb) | Full sandbox settings (network, filesystem, violations) |

### MCP Servers

| Example | Description |
|---------|-------------|
| [mcp_calculator.rb](examples/mcp_calculator.rb) | Custom tools with SDK MCP servers |
| [mcp_resources_prompts_example.rb](examples/mcp_resources_prompts_example.rb) | MCP resources and prompts |
| [http_mcp_server_example.rb](examples/http_mcp_server_example.rb) | HTTP/SSE MCP server configuration |

### Hooks & Permissions

| Example | Description |
|---------|-------------|
| [hooks_example.rb](examples/hooks_example.rb) | Using hooks to control tool execution |
| [advanced_hooks_example.rb](examples/advanced_hooks_example.rb) | Typed hook inputs/outputs |
| [lifecycle_hooks_example.rb](examples/lifecycle_hooks_example.rb) | All 27 hook events |
| [permission_callback_example.rb](examples/permission_callback_example.rb) | Dynamic tool permission control |

### Advanced

| Example | Description |
|---------|-------------|
| [budget_control_example.rb](examples/budget_control_example.rb) | Budget control with `max_budget_usd` |
| [fallback_model_example.rb](examples/fallback_model_example.rb) | Fallback model configuration |
| [extended_thinking_example.rb](examples/extended_thinking_example.rb) | Extended thinking |
| [e2b_transport_example.rb](examples/e2b_transport_example.rb) | Custom transport running CLI in an E2B microVM |

### Observability & Rails

| Example | Description |
|---------|-------------|
| [otel_langfuse_example.rb](examples/otel_langfuse_example.rb) | OpenTelemetry tracing with Langfuse backend |
| [rails_actioncable_example.rb](examples/rails_actioncable_example.rb) | ActionCable streaming to frontend |
| [rails_background_job_example.rb](examples/rails_background_job_example.rb) | Background jobs with session resumption |

## Available Tools

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code/settings#tools-available-to-claude) for a complete list of available tools.

## Development

After checking out the repo, run `bundle install` to install dependencies. Then `bundle exec rspec` to run the tests.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Star History

<a href="https://www.star-history.com/?repos=ya-luotao%2Fclaude-agent-sdk-ruby&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ya-luotao/claude-agent-sdk-ruby&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ya-luotao/claude-agent-sdk-ruby&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=ya-luotao/claude-agent-sdk-ruby&type=date&legend=top-left" />
 </picture>
</a>
