# Claude Agent SDK for Ruby

![Claude Agent SDK for Ruby banner](assets/claude-agent-sdk-ruby-banner.png)

[![Gem Version](https://badge.fury.io/rb/claude-agent-sdk.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/claude-agent-sdk)

An **unofficial, community-maintained** Ruby SDK for the [Claude Code](https://docs.claude.com/en/docs/claude-code-overview) agent runtime. Not affiliated with or supported by Anthropic.

### Official SDKs

- **TypeScript** (official): [anthropics/claude-agent-sdk-typescript](https://github.com/anthropics/claude-agent-sdk-typescript)
- **Python** (official): [anthropics/claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python)

### Why a Ruby SDK?

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

**Where Ruby goes further:** Built-in OpenTelemetry observer with Langfuse flow diagram support — no third-party instrumentation library needed. Custom transport support lets you swap the subprocess for any I/O layer (e.g., connect to a remote Claude Code instance over SSH or a container). Rails integration provides a `configure` block for initializers with thread-safe observer factories, and plays well with ActionCable for real-time streaming. Full typed coverage for all 24 CLI message types and all 27 hook events — some of which the Python SDK hasn't typed yet.

**What's missing:** The Ruby gem does not bundle the `claude` CLI binary (`npm install -g @anthropic-ai/claude-code`).

<details>
<summary><strong>Implementation differences from the official SDKs</strong></summary>

#### Async model

TypeScript uses native `async`/`await`. Python uses `async`/`await` with `anyio`. Ruby uses the [`async`](https://github.com/socketry/async) gem with fibers — no `await` keyword needed, blocking calls yield automatically inside an `Async` block.

```ruby
Async do
  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect
  client.query("Hello")
  client.receive_messages { |msg| puts msg }
  client.disconnect
end.wait
```

#### Types

TypeScript has Zod schemas with inferred types. Python uses `dataclass` with type annotations. Ruby uses plain classes with `attr_accessor` and keyword args — no runtime type checking, but the same structure and field names.

#### Subprocess transport

All three SDKs spawn `claude` CLI as a subprocess with stream-JSON over stdin/stdout. TypeScript uses Node `child_process`, Python uses `anyio.open_process`, Ruby uses `Open3.popen3`. The wire protocol is identical.

</details>

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Basic Usage: query()](#basic-usage-query)
- [Client](#client)
- [Custom Transport](#custom-transport)
- [Custom Tools (SDK MCP Servers)](#custom-tools-sdk-mcp-servers)
- [Hooks](#hooks)
- [Permission Callbacks](#permission-callbacks)
- [Structured Output](#structured-output)
- [Thinking Configuration](#thinking-configuration)
- [Budget Control](#budget-control)
- [Fallback Model](#fallback-model)
- [Beta Features](#beta-features)
- [Tools Configuration](#tools-configuration)
- [Sandbox Settings](#sandbox-settings)
- [Bare Mode](#bare-mode)
- [File Checkpointing & Rewind](#file-checkpointing--rewind)
- [Session Browsing](#session-browsing)
- [Session Mutations](#session-mutations)
- [Observability (OpenTelemetry / Langfuse)](#observability-opentelemetry--langfuse)
- [Rails Integration](#rails-integration)
- [Types](#types)
- [Error Handling](#error-handling)
- [Examples](#examples)
- [Development](#development)
- [License](#license)

## Installation

Add this line to your application's Gemfile:

```ruby
# Recommended: Use the latest from GitHub for newest features
gem 'claude-agent-sdk', github: 'ya-luotao/claude-agent-sdk-ruby'

# Or use a stable version from RubyGems
gem 'claude-agent-sdk', '~> 0.16.5'
```

And then execute:

```bash
bundle install
```

Or install directly from RubyGems:

```bash
gem install claude-agent-sdk
```

**Prerequisites:**
- Ruby 3.2+
- Node.js
- Claude Code 2.0.0+: `npm install -g @anthropic-ai/claude-code`

### Agentic Coding Skill

If you're using [Claude Code](https://claude.ai/claude-code), this repo is a Claude Code plugin marketplace. Add it once, then install the skill:

```bash
# Add the marketplace
/plugin marketplace add ya-luotao/claude-agent-sdk-ruby

# Install the plugin
/plugin install claude-agent-ruby@claude-agent-sdk-ruby
```

This skill teaches your AI coding assistant about the SDK's APIs, patterns, and best practices, making it easier to get help writing code that uses this SDK.

## Quick Start

```ruby
require 'claude_agent_sdk'

ClaudeAgentSDK.query(prompt: "What is 2 + 2?") do |message|
  puts message
end
```

## Basic Usage: query()

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

### Using Tools

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  allowed_tools: ['Read', 'Write', 'Bash'],
  permission_mode: 'acceptEdits'  # auto-accept file edits
)

ClaudeAgentSDK.query(
  prompt: "Create a hello.rb file",
  options: options
) do |message|
  # Process tool use and results
end
```

### Working Directory

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  cwd: "/path/to/project"
)
```

### Streaming Input

The `query()` function supports streaming input, allowing you to send multiple messages dynamically instead of a single prompt string.

```ruby
require 'claude_agent_sdk'

# Create a stream of messages
messages = ['Hello!', 'What is 2+2?', 'Thanks!']
stream = ClaudeAgentSDK::Streaming.from_array(messages)

# Query with streaming input
ClaudeAgentSDK.query(prompt: stream) do |message|
  puts message if message.is_a?(ClaudeAgentSDK::AssistantMessage)
end
```

You can also create custom streaming enumerators:

```ruby
# Dynamic message generation
stream = Enumerator.new do |yielder|
  yielder << ClaudeAgentSDK::Streaming.user_message("First message")
  # Do some processing...
  yielder << ClaudeAgentSDK::Streaming.user_message("Second message")
  yielder << ClaudeAgentSDK::Streaming.user_message("Third message")
end

ClaudeAgentSDK.query(prompt: stream) do |message|
  # Process responses
end
```

For a complete example, see [examples/streaming_input_example.rb](examples/streaming_input_example.rb).

## Client

`ClaudeAgentSDK::Client` supports bidirectional, interactive conversations with Claude Code. Unlike `query()`, `Client` enables **custom tools**, **hooks**, and **permission callbacks**, all of which can be defined as Ruby procs/lambdas.

**The Client class automatically uses streaming mode** for bidirectional communication, allowing you to send multiple queries dynamically during a single session without closing the connection.

### Basic Client Usage

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  client = ClaudeAgentSDK::Client.new

  begin
    # Connect automatically uses streaming mode for bidirectional communication
    client.connect

    # Send a query
    client.query("What is the capital of France?")

    # Receive the response
    client.receive_response do |msg|
      case msg
      when ClaudeAgentSDK::AssistantMessage
        puts msg.text
      when ClaudeAgentSDK::ResultMessage
        puts "Cost: $#{msg.total_cost_usd}" if msg.total_cost_usd
      end
    end

  ensure
    client.disconnect
  end
end.wait
```

### Advanced Client Features

```ruby
Async do
  client = ClaudeAgentSDK::Client.new
  client.connect

  # Send interrupt signal
  client.interrupt

  # Change permission mode during conversation
  client.set_permission_mode('acceptEdits')

  # Change AI model during conversation
  client.set_model('claude-sonnet-4-5')

  # Get MCP server connection status
  status = client.get_mcp_status
  puts "MCP status: #{status}"

  # Get server initialization info
  info = client.get_server_info
  puts "Available commands: #{info}"

  # Reconnect a failed MCP server
  client.reconnect_mcp_server('my-server')

  # Enable or disable an MCP server
  client.toggle_mcp_server('my-server', false)

  # Stop a running background task
  client.stop_task('task_abc123')

  client.disconnect
end.wait
```

### Custom Transport

By default, `Client` uses `SubprocessCLITransport` to spawn the Claude Code CLI locally. You can provide a custom transport class to connect via other channels (e.g., E2B sandbox, remote SSH, WebSocket):

```ruby
# Custom transport must implement the Transport interface:
# connect, write, read_messages, end_input, close, ready?
class E2BSandboxTransport < ClaudeAgentSDK::Transport
  def initialize(options, sandbox:)
    @options = options
    @sandbox = sandbox
  end

  def connect
    @sandbox.connect
  end

  def write(data)
    @sandbox.stdin_write(data)
  end

  def read_messages(&block)
    @sandbox.stdout_read_lines { |line| yield JSON.parse(line, symbolize_names: true) }
  end

  def end_input
    @sandbox.close_stdin
  end

  def close
    @sandbox.disconnect
  end

  def ready?
    @sandbox.connected?
  end
end

# Use it with Client — all connect orchestration (option transforms,
# MCP extraction, hook conversion, Query lifecycle) is handled for you
Async do
  client = ClaudeAgentSDK::Client.new(
    options: options,
    transport_class: E2BSandboxTransport,
    transport_args: { sandbox: my_sandbox }
  )
  client.connect
  client.query("Hello from the sandbox!")
  client.receive_response { |msg| puts msg }
  client.disconnect
end.wait
```

## Custom Tools (SDK MCP Servers)

A **custom tool** is a Ruby proc/lambda that you can offer to Claude, for Claude to invoke as needed.

Custom tools are implemented as in-process MCP servers that run directly within your Ruby application, eliminating the need for separate processes that regular MCP servers require.

**Implementation**: This SDK uses the [official Ruby MCP SDK](https://github.com/modelcontextprotocol/ruby-sdk) (`mcp` gem) internally, providing full protocol compliance while offering a simpler block-based API for tool definition.

### Creating a Simple Tool

```ruby
require 'claude_agent_sdk'
require 'async'

# Define a tool using create_tool (with optional annotations)
greet_tool = ClaudeAgentSDK.create_tool(
  'greet', 'Greet a user', { name: :string },
  annotations: { title: 'Greeter', readOnlyHint: true }
) do |args|
  { content: [{ type: 'text', text: "Hello, #{args[:name]}!" }] }
end

# Create an SDK MCP server
server = ClaudeAgentSDK.create_sdk_mcp_server(
  name: 'my-tools',
  version: '1.0.0',
  tools: [greet_tool]
)

# Use it with Claude
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: { tools: server },
  allowed_tools: ['mcp__tools__greet']
)

Async do
  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect

  client.query("Greet Alice")
  client.receive_response { |msg| puts msg }

  client.disconnect
end.wait
```

### Pre-built JSON Schemas

If your schemas come from another library (e.g., [RubyLLM](https://github.com/crmne/ruby_llm)) that deep-stringifies keys, the SDK handles them transparently — both symbol-keyed and string-keyed schemas are accepted and normalized:

```ruby
# Symbol keys (standard Ruby)
tool = ClaudeAgentSDK.create_tool('save', 'Save a fact', {
  type: 'object',
  properties: { fact: { type: 'string' } },
  required: ['fact']
}) { |args| { content: [{ type: 'text', text: "Saved: #{args[:fact]}" }] } }

# String keys (e.g., from RubyLLM or JSON.parse)
tool = ClaudeAgentSDK.create_tool('save', 'Save a fact', {
  'type' => 'object',
  'properties' => { 'fact' => { 'type' => 'string' } },
  'required' => ['fact']
}) { |args| { content: [{ type: 'text', text: "Saved: #{args[:fact]}" }] } }
```

### Benefits Over External MCP Servers

- **No subprocess management** - Runs in the same process as your application
- **Better performance** - No IPC overhead for tool calls
- **Simpler deployment** - Single Ruby process instead of multiple
- **Easier debugging** - All code runs in the same process
- **Direct access** - Tools can directly access your application's state

### Calculator Example

```ruby
# Define calculator tools
add_tool = ClaudeAgentSDK.create_tool('add', 'Add two numbers', { a: :number, b: :number }) do |args|
  result = args[:a] + args[:b]
  { content: [{ type: 'text', text: "#{args[:a]} + #{args[:b]} = #{result}" }] }
end

divide_tool = ClaudeAgentSDK.create_tool('divide', 'Divide numbers', { a: :number, b: :number }) do |args|
  if args[:b] == 0
    { content: [{ type: 'text', text: 'Error: Division by zero' }], is_error: true }
  else
    result = args[:a] / args[:b]
    { content: [{ type: 'text', text: "Result: #{result}" }] }
  end
end

# Create server
calculator = ClaudeAgentSDK.create_sdk_mcp_server(
  name: 'calculator',
  tools: [add_tool, divide_tool]
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: { calc: calculator },
  allowed_tools: ['mcp__calc__add', 'mcp__calc__divide']
)
```

### Mixed Server Support

You can use both SDK and external MCP servers together:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: {
    internal: sdk_server,      # In-process SDK server
    external: {                # External subprocess server
      type: 'stdio',
      command: 'external-server'
    }
  }
)
```

### MCP Resources and Prompts

SDK MCP servers can also expose **resources** (data sources) and **prompts** (reusable templates):

```ruby
# Create a resource (data source Claude can read)
config_resource = ClaudeAgentSDK.create_resource(
  uri: 'config://app/settings',
  name: 'Application Settings',
  description: 'Current app configuration',
  mime_type: 'application/json'
) do
  config_data = { app_name: 'MyApp', version: '1.0.0' }
  {
    contents: [{
      uri: 'config://app/settings',
      mimeType: 'application/json',
      text: JSON.pretty_generate(config_data)
    }]
  }
end

# Create a prompt template
review_prompt = ClaudeAgentSDK.create_prompt(
  name: 'code_review',
  description: 'Review code for best practices',
  arguments: [
    { name: 'code', description: 'Code to review', required: true }
  ]
) do |args|
  {
    messages: [{
      role: 'user',
      content: {
        type: 'text',
        text: "Review this code: #{args[:code]}"
      }
    }]
  }
end

# Create server with tools, resources, and prompts
server = ClaudeAgentSDK.create_sdk_mcp_server(
  name: 'dev-tools',
  tools: [my_tool],
  resources: [config_resource],
  prompts: [review_prompt]
)
```

For complete examples, see [examples/mcp_calculator.rb](examples/mcp_calculator.rb) and [examples/mcp_resources_prompts_example.rb](examples/mcp_resources_prompts_example.rb).

## Hooks

A **hook** is a Ruby proc/lambda that the Claude Code *application* (*not* Claude) invokes at specific points of the Claude agent loop. Hooks can provide deterministic processing and automated feedback for Claude. Read more in [Claude Code Hooks Reference](https://docs.anthropic.com/en/docs/claude-code/hooks).

### Supported Events

All hook input objects include common fields like `session_id`, `transcript_path`, `cwd`, and `permission_mode`.

- `PreToolUse` → `PreToolUseHookInput` (`tool_name`, `tool_input`, `tool_use_id`)
- `PostToolUse` → `PostToolUseHookInput` (`tool_name`, `tool_input`, `tool_response`, `tool_use_id`)
- `PostToolUseFailure` → `PostToolUseFailureHookInput` (`tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt`)
- `UserPromptSubmit` → `UserPromptSubmitHookInput` (`prompt`)
- `Stop` → `StopHookInput` (`stop_hook_active`)
- `SubagentStop` → `SubagentStopHookInput` (`stop_hook_active`, `agent_id`, `agent_transcript_path`, `agent_type`)
- `PreCompact` → `PreCompactHookInput` (`trigger`, `custom_instructions`)
- `Notification` → `NotificationHookInput` (`message`, `title`, `notification_type`)
- `SubagentStart` → `SubagentStartHookInput` (`agent_id`, `agent_type`)
- `PermissionRequest` → `PermissionRequestHookInput` (`tool_name`, `tool_input`, `permission_suggestions`)

### Example

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  # Define a hook that blocks dangerous bash commands
  bash_hook = lambda do |input, _tool_use_id, _context|
    # Hook inputs are typed objects (e.g., PreToolUseHookInput) with Ruby-style accessors
    return {} unless input.respond_to?(:tool_name) && input.tool_name == 'Bash'

    tool_input = input.tool_input || {}
    command = tool_input[:command] || tool_input['command'] || ''
    block_patterns = ['rm -rf', 'foo.sh']

    block_patterns.each do |pattern|
      if command.include?(pattern)
        return {
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            permissionDecision: 'deny',
            permissionDecisionReason: "Command contains forbidden pattern: #{pattern}"
          }
        }
      end
    end

    {} # Allow if no patterns match
  end

  # Create options with hook
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    allowed_tools: ['Bash'],
    hooks: {
      'PreToolUse' => [
        ClaudeAgentSDK::HookMatcher.new(
          matcher: 'Bash',
          hooks: [bash_hook]
        )
      ]
    }
  )

  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect

  # Test: Command with forbidden pattern (will be blocked)
  client.query("Run the bash command: ./foo.sh --help")
  client.receive_response { |msg| puts msg }

  client.disconnect
end.wait
```

For more examples, see [examples/hooks_example.rb](examples/hooks_example.rb).

## Permission Callbacks

A **permission callback** is a Ruby proc/lambda that allows you to programmatically control tool execution. This gives you fine-grained control over what tools Claude can use and with what inputs.

### Example

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  # Define a permission callback
  permission_callback = lambda do |tool_name, input, context|
    # Allow Read operations
    if tool_name == 'Read'
      return ClaudeAgentSDK::PermissionResultAllow.new
    end

    # Block Write to sensitive files
    if tool_name == 'Write'
      file_path = input[:file_path] || input['file_path']
      if file_path && file_path.include?('/etc/')
        return ClaudeAgentSDK::PermissionResultDeny.new(
          message: 'Cannot write to sensitive system files',
          interrupt: false
        )
      end
      return ClaudeAgentSDK::PermissionResultAllow.new
    end

    # Default: allow
    ClaudeAgentSDK::PermissionResultAllow.new
  end

  # Create options with permission callback
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    allowed_tools: ['Read', 'Write', 'Bash'],
    can_use_tool: permission_callback
  )

  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect

  # This will be allowed
  client.query("Create a file called test.txt with content 'Hello'")
  client.receive_response { |msg| puts msg }

  # This will be blocked
  client.query("Write to /etc/passwd")
  client.receive_response { |msg| puts msg }

  client.disconnect
end.wait
```

For more examples, see [examples/permission_callback_example.rb](examples/permission_callback_example.rb).

## Structured Output

Use `output_format` to get validated JSON responses matching a schema. The Claude CLI returns structured output via a `StructuredOutput` tool use block.

```ruby
require 'claude_agent_sdk'
require 'json'

# Define a JSON schema
schema = {
  type: 'object',
  properties: {
    name: { type: 'string' },
    age: { type: 'integer' },
    skills: { type: 'array', items: { type: 'string' } }
  },
  required: %w[name age skills]
}

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  output_format: { type: 'json_schema', schema: schema },
  max_turns: 3
)

structured_data = nil

ClaudeAgentSDK.query(
  prompt: "Create a profile for a software engineer",
  options: options
) do |message|
  if message.is_a?(ClaudeAgentSDK::AssistantMessage)
    message.content.each do |block|
      # Structured output comes via StructuredOutput tool use
      if block.is_a?(ClaudeAgentSDK::ToolUseBlock) && block.name == 'StructuredOutput'
        structured_data = block.input
      end
    end
  end
end

if structured_data
  puts "Name: #{structured_data[:name]}"
  puts "Age: #{structured_data[:age]}"
  puts "Skills: #{structured_data[:skills].join(', ')}"
end
```

For complete examples, see [examples/structured_output_example.rb](examples/structured_output_example.rb).

## Thinking Configuration

Control extended thinking behavior with typed configuration objects. The `thinking` option takes precedence over the deprecated `max_thinking_tokens`.

```ruby
# Adaptive thinking — CLI dynamically adjusts budget based on task complexity
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new
)

# Enabled thinking with explicit token budget
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  thinking: ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 50_000)
)

# Explicitly disabled thinking
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  thinking: ClaudeAgentSDK::ThinkingConfigDisabled.new
)
```

Use the `effort` option to control the model's effort level:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  effort: 'xhigh'  # see ClaudeAgentSDK::EFFORT_LEVELS
)
```

Valid levels live in `ClaudeAgentSDK::EFFORT_LEVELS` (`low`, `medium`, `high`, `xhigh`, `max`). The set of *supported* levels is model-dependent — `xhigh` is available on Opus 4.7 and the CLI falls back to the highest supported level at or below the one you set (e.g. `xhigh` → `high` on Opus 4.6). When `effort` is `nil`, the CLI picks a model-native default (Opus 4.7 → `xhigh`).

> **Note:** When `system_prompt` is `nil` (the default), the SDK passes `--system-prompt ""` to the CLI, which suppresses the default Claude Code system prompt. To use the default system prompt, use a `SystemPromptPreset`.

### Cross-User Prompt Caching

When running a multi-user fleet with shared preset prompts, enable `exclude_dynamic_sections` to make the system prompt byte-identical across users for prompt-caching hits:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  system_prompt: ClaudeAgentSDK::SystemPromptPreset.new(
    preset: 'claude_code',
    append: '...your shared domain instructions...',
    exclude_dynamic_sections: true
  )
)
```

When set, the CLI strips per-user dynamic sections (working directory, auto-memory, git status) from the system prompt and re-injects them into the first user message instead. Older CLIs silently ignore this option.

## Budget Control

Use `max_budget_usd` to set a spending cap for your queries:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  max_budget_usd: 0.10,  # Cap at $0.10
  max_turns: 3
)

ClaudeAgentSDK.query(prompt: "Explain recursion", options: options) do |message|
  if message.is_a?(ClaudeAgentSDK::ResultMessage)
    puts "Cost: $#{message.total_cost_usd}"
  end
end
```

For complete examples, see [examples/budget_control_example.rb](examples/budget_control_example.rb).

## Fallback Model

Use `fallback_model` to specify a backup model if the primary is unavailable:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  model: 'claude-sonnet-4-20250514',
  fallback_model: 'claude-3-5-haiku-20241022'
)

ClaudeAgentSDK.query(prompt: "Hello", options: options) do |message|
  if message.is_a?(ClaudeAgentSDK::AssistantMessage)
    puts "Model used: #{message.model}"
  end
end
```

For complete examples, see [examples/fallback_model_example.rb](examples/fallback_model_example.rb).

## Beta Features

Enable experimental features using the `betas` option:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  betas: ['context-1m-2025-08-07']  # Extended context window
)

ClaudeAgentSDK.query(prompt: "Analyze this large document...", options: options) do |message|
  puts message
end
```

Available beta features are listed in the `SDK_BETAS` constant.

## Tools Configuration

Configure base tools separately from allowed tools:

```ruby
# Using an array of tool names
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  tools: ['Read', 'Edit', 'Bash']  # Base tools available
)

# Using a preset
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  tools: ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code')
)

# Appending to allowed tools
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  append_allowed_tools: ['Write', 'Bash']
)
```

## Sandbox Settings

Configure [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) restrictions (network policy, filesystem access) via the CLI's `--sandbox` flag. The CLI handles OS-level process isolation using `srt`.

```ruby
sandbox = ClaudeAgentSDK::SandboxSettings.new(
  enabled: true,
  auto_allow_bash_if_sandboxed: true,
  network: ClaudeAgentSDK::SandboxNetworkConfig.new(
    allow_local_binding: true
  )
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  sandbox: sandbox,
  permission_mode: 'acceptEdits'
)

ClaudeAgentSDK.query(prompt: "Run some commands", options: options) do |message|
  puts message
end
```

## Bare Mode

Bare mode (`--bare`) is a minimal startup mode that skips hooks, LSP, plugin sync, attribution, auto-memory, background prefetches, keychain reads, and CLAUDE.md auto-discovery. It sets `CLAUDE_CODE_SIMPLE=1` internally. This is useful for scripted/programmatic usage where you want fast startup and full control over what's loaded.

```ruby
# Sugar option
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  bare: true,
  system_prompt: 'You are a code reviewer.',
  permission_mode: 'bypassPermissions'
)

ClaudeAgentSDK.query(prompt: "Review this function", options: options) do |message|
  # ...
end
```

In bare mode, explicitly provide any context you need:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  bare: true,
  system_prompt: 'You are a helpful assistant.',
  add_dirs: ['/path/to/project'],       # CLAUDE.md directories (auto-discovery is off)
  setting_sources: ['project'],          # load .claude/settings.json
  allowed_tools: ['Read', 'Grep', 'Glob'],
  permission_mode: 'bypassPermissions'
)
```

**What bare mode skips:** hooks, LSP, plugin sync, attribution, auto-memory, background prefetches, keychain reads, CLAUDE.md auto-discovery, teammate snapshots, release notes.

**What still works:** skills (via `/skill-name`), explicit `--add-dir` CLAUDE.md, `--settings`, `--mcp-config`, `--agents`, `--plugin-dir`, API key from `ANTHROPIC_API_KEY` env var.

## File Checkpointing & Rewind

Enable file checkpointing to revert file changes to a previous state:

```ruby
require 'async'

Async do
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    enable_file_checkpointing: true,
    permission_mode: 'acceptEdits'
  )

  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect

  # Track user message UUIDs for potential rewind
  user_message_uuids = []

  # First query - create a file
  client.query("Create a test.rb file with some code")
  client.receive_response do |message|
    # Process all message types as needed
    case message
    when ClaudeAgentSDK::UserMessage
      # Capture UUID for rewind capability
      user_message_uuids << message.uuid if message.uuid
    when ClaudeAgentSDK::AssistantMessage
      puts message.text
    when ClaudeAgentSDK::ResultMessage
      puts "Query completed (cost: $#{message.total_cost_usd})"
    end
  end

  # Second query - modify the file
  client.query("Modify the test.rb file to add error handling")
  client.receive_response do |message|
    user_message_uuids << message.uuid if message.is_a?(ClaudeAgentSDK::UserMessage) && message.uuid
  end

  # Rewind to the first checkpoint (undoes the second query's changes)
  if user_message_uuids.first
    puts "Rewinding to checkpoint: #{user_message_uuids.first}"
    client.rewind_files(user_message_uuids.first)
  end

  client.disconnect
end.wait
```

> **Note:** The `uuid` field on `UserMessage` is populated by the CLI and represents checkpoint identifiers. Rewinding to a UUID restores file state to what it was at that point in the conversation.

## Session Browsing

Browse and inspect previous Claude Code sessions directly from Ruby — no CLI subprocess required.

### Listing Sessions

```ruby
# List all sessions (sorted by most recent first)
sessions = ClaudeAgentSDK.list_sessions
sessions.each do |session|
  puts "#{session.session_id}: #{session.summary} (#{session.git_branch})"
end

# List sessions for a specific directory
sessions = ClaudeAgentSDK.list_sessions(directory: '/path/to/project', limit: 10)

# Paginate with offset
page2 = ClaudeAgentSDK.list_sessions(directory: '.', limit: 10, offset: 10)

# Include git worktree sessions
sessions = ClaudeAgentSDK.list_sessions(directory: '.', include_worktrees: true)
```

Each `SDKSessionInfo` includes:
- `session_id`, `summary`, `last_modified`, `file_size`
- `custom_title`, `first_prompt`, `git_branch`, `cwd`

### Reading Session Messages

```ruby
# Get the full conversation from a session
messages = ClaudeAgentSDK.get_session_messages(session_id: 'abc-123-...')
messages.each do |msg|
  puts "[#{msg.type}] #{msg.message}"
end

# Paginate through messages
page = ClaudeAgentSDK.get_session_messages(session_id: 'abc-123-...', offset: 10, limit: 20)
```

Each `SessionMessage` includes `type` (`"user"` or `"assistant"`), `uuid`, `session_id`, and `message` (raw API dict).

> **Note:** Session browsing reads `~/.claude/projects/` JSONL files directly. It respects the `CLAUDE_CONFIG_DIR` environment variable and automatically detects git worktrees.

## Session Mutations

Rename or tag sessions programmatically — no CLI subprocess required.

### Renaming a Session

```ruby
# Rename a session (appends a custom-title JSONL entry)
ClaudeAgentSDK.rename_session(
  session_id: '550e8400-e29b-41d4-a716-446655440000',
  title: 'My refactoring session',
  directory: '/path/to/project'  # optional
)
```

### Tagging a Session

```ruby
# Tag a session (Unicode-sanitized before storing)
ClaudeAgentSDK.tag_session(
  session_id: '550e8400-e29b-41d4-a716-446655440000',
  tag: 'experiment'
)

# Clear a tag
ClaudeAgentSDK.tag_session(
  session_id: '550e8400-e29b-41d4-a716-446655440000',
  tag: nil
)
```

### Deleting a Session

```ruby
# Hard-delete a session (removes the JSONL file permanently)
ClaudeAgentSDK.delete_session(
  session_id: '550e8400-e29b-41d4-a716-446655440000',
  directory: '/path/to/project'  # optional
)
```

### Forking a Session

```ruby
# Fork a session into a new branch with fresh UUIDs
result = ClaudeAgentSDK.fork_session(
  session_id: '550e8400-e29b-41d4-a716-446655440000',
  title: 'Experiment branch'  # optional, auto-generated if omitted
)
puts result.session_id  # UUID of the new forked session

# Fork up to a specific message (partial fork)
result = ClaudeAgentSDK.fork_session(
  session_id: '550e8400-e29b-41d4-a716-446655440000',
  up_to_message_id: 'message-uuid-here'
)
```

> **Note:** Session mutations use append-only JSONL writes with `O_WRONLY | O_APPEND` (no `O_CREAT`) for TOCTOU safety. They are safe to call while the session is open in a CLI process. `fork_session` uses `O_CREAT | O_EXCL` to prevent race conditions.

## Observability (OpenTelemetry / Langfuse)

The SDK includes a built-in **observer interface** and an **OpenTelemetry observer** for tracing agent sessions. Traces are emitted using standard `gen_ai.*` semantic conventions, compatible with Langfuse, Jaeger, Datadog, and any OTel backend.

### How It Works

Register observers via `ClaudeAgentOptions`. The SDK calls `on_message` for every parsed message in both `query()` and `Client`, and `on_close` when the session ends. Observer errors are silently rescued so they never crash your application.

```
claude_agent.session            (root span — one per query/session)
├── claude_agent.generation     (per AssistantMessage, with model + token usage)
├── claude_agent.tool.Bash      (per tool call, open on ToolUseBlock, close on ToolResultBlock)
├── claude_agent.tool.Read
├── claude_agent.generation
└── ...
```

### Setup with Langfuse

**1. Install the OTel gems** (not bundled with the SDK — you choose your exporter):

```bash
gem install opentelemetry-sdk opentelemetry-exporter-otlp
```

Or add to your Gemfile:

```ruby
gem 'opentelemetry-sdk', '~> 1.4'
gem 'opentelemetry-exporter-otlp', '~> 0.28'
```

**2. Configure the OTel SDK** to export to your Langfuse instance:

```ruby
require 'base64'
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'

# Langfuse authenticates via Basic Auth over OTLP
public_key = ENV['LANGFUSE_PUBLIC_KEY']
secret_key = ENV['LANGFUSE_SECRET_KEY']
auth = Base64.strict_encode64("#{public_key}:#{secret_key}")

# Self-hosted or cloud: https://cloud.langfuse.com (EU) / https://us.cloud.langfuse.com (US)
langfuse_host = ENV.fetch('LANGFUSE_HOST', 'https://cloud.langfuse.com')

OpenTelemetry::SDK.configure do |c|
  c.service_name = 'my-agent-app'
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "#{langfuse_host}/api/public/otel/v1/traces",
        headers: {
          'Authorization' => "Basic #{auth}",
          'x-langfuse-ingestion-version' => '4'
        }
      )
    )
  )
end
```

**3. Create the observer and run a query:**

```ruby
require 'claude_agent_sdk'
require 'claude_agent_sdk/instrumentation'

observer = ClaudeAgentSDK::Instrumentation::OTelObserver.new(
  'langfuse.session.id' => 'my-session-123',  # optional: group traces by session
  'user.id' => 'user-42'                      # optional: tag with user ID
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  observers: [observer],
  allowed_tools: ['Bash', 'Read'],
  permission_mode: 'bypassPermissions'
)

ClaudeAgentSDK.query(prompt: "List files in /tmp", options: options) do |msg|
  puts msg.text if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
end

# For long-running apps, flush before exit:
# OpenTelemetry.tracer_provider.shutdown
```

### Span Attributes

The OTel observer sets attributes using both `gen_ai.*` (OTel GenAI) and OpenInference conventions for maximum backend compatibility:

| Span | Type | Key Attributes |
|------|------|----------------|
| `claude_agent.session` | `agent` | `gen_ai.system`, `gen_ai.request.model`, `session.id`, `input.value`, `output.value`, `gen_ai.usage.cost`, `llm.cost.total` |
| `claude_agent.generation` | `generation` | `gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `output.value` |
| `claude_agent.tool.*` | `tool` | `tool.name`, `input.value`, `output.value` |

Events (`api_retry`, `rate_limit`, `tool_progress`) are recorded on the root span.

The `langfuse.observation.type` attribute is set on each span (`agent`/`generation`/`tool`) to enable Langfuse's **trace flow diagram** (DAG graph visualization).

### Custom Observers

Implement the `Observer` module to build your own instrumentation:

```ruby
class MyObserver
  include ClaudeAgentSDK::Observer

  def on_message(message)
    case message
    when ClaudeAgentSDK::ResultMessage
      puts "Cost: $#{message.total_cost_usd}, Tokens: #{message.usage}"
    end
  end

  def on_close
    puts "Session ended"
  end
end

options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [MyObserver.new])
```

For a complete multi-tool example, see [examples/otel_langfuse_example.rb](examples/otel_langfuse_example.rb).

## Rails Integration

The SDK integrates well with Rails applications. Here are common patterns:

### Thread-keyed libraries are safe inside SDK callbacks

The SDK depends on [`async`](https://github.com/socketry/async), which installs
a Fiber scheduler that multiplexes fibers onto a single OS thread and
intercepts IO so blocking calls yield to siblings. Most mature Ruby libraries
are thread-safe but not fiber-safe — they key state (checked-out DB
connections, per-thread caches, request stores) on `Thread.current`. When the
scheduler interleaves two fibers on one thread, those fibers share the same
state slot, and interleaved IO on a shared connection silently corrupts wire
protocols. This affects every DB driver keyed by thread (`pg`, `mysql2`,
`sqlite3`), ActiveRecord's connection pool, and HTTP/cache clients pooled per
thread.

You do **not** need to think about this. The SDK hops to a plain thread at
every user-callback boundary — message blocks given to `query` / `Client`, SDK
MCP tool handlers, hooks, permission callbacks, and observer methods — so
your code runs with no Fiber scheduler active and inherits the ordinary
thread-keyed assumptions every Rails / Sidekiq / Kamal app already makes:

```ruby
tool = ClaudeAgentSDK.create_tool('lookup_user', 'Look up a user', { id: Integer }) do |args|
  user = User.find(args[:id])                # just works
  { content: [{ type: 'text', text: user.name }] }
end

ClaudeAgentSDK.query(prompt: '...') do |message|
  Message.create!(role: 'assistant', body: message.to_s)   # just works
end
```

The trade-off: because callbacks run on a plain thread rather than inside
an `Async::Task`, fiber-specific primitives aren't available to them —
`Async::Task.current` will raise "No async task available". If a callback
wants cooperative concurrency it should open its own `Async { }` block. In
practice, callbacks typically do some Ruby work, call external services, and
return — so this rarely matters. If you wrap your own call site in an outer
`Async { }` block, the scheduler is visible to your code again; you've opted
in, and whatever fiber-safety rules your app uses apply there.

### ActionCable Streaming

Stream Claude responses to the frontend in real-time:

```ruby
# app/jobs/chat_agent_job.rb
class ChatAgentJob < ApplicationJob
  queue_as :claude_agents

  def perform(chat_id, message_content)
    Async do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        system_prompt: { type: 'preset', preset: 'claude_code' },
        permission_mode: 'bypassPermissions'
      )

      client = ClaudeAgentSDK::Client.new(options: options)

      begin
        client.connect
        client.query(message_content)

        client.receive_response do |message|
          case message
          when ClaudeAgentSDK::AssistantMessage
            ChatChannel.broadcast_to(chat_id, { type: 'chunk', content: message.text })

          when ClaudeAgentSDK::ResultMessage
            ChatChannel.broadcast_to(chat_id, {
              type: 'complete',
              content: message.result,
              cost: message.total_cost_usd
            })
          end
        end
      ensure
        client.disconnect
      end
    end.wait
  end
end
```

### Session Resumption

Persist Claude sessions for multi-turn conversations:

```ruby
# app/models/chat_session.rb
class ChatSession < ApplicationRecord
  # Columns: id, claude_session_id, user_id, created_at, updated_at

  def send_message(content)
    options = build_options
    client = ClaudeAgentSDK::Client.new(options: options)

    Async do
      client.connect
      client.query(content, session_id: claude_session_id ? nil : generate_session_id)

      client.receive_response do |message|
        if message.is_a?(ClaudeAgentSDK::ResultMessage)
          # Save session ID for next message
          update!(claude_session_id: message.session_id)
        end
      end
    ensure
      client.disconnect
    end.wait
  end

  private

  def build_options
    opts = {
      permission_mode: 'bypassPermissions',
      setting_sources: []
    }
    opts[:resume] = claude_session_id if claude_session_id.present?
    ClaudeAgentSDK::ClaudeAgentOptions.new(**opts)
  end

  def generate_session_id
    "chat_#{id}_#{Time.current.to_i}"
  end
end
```

### Background Jobs with Error Handling

```ruby
class ClaudeAgentJob < ApplicationJob
  queue_as :claude_agents
  retry_on ClaudeAgentSDK::ProcessError, wait: :polynomially_longer, attempts: 3

  def perform(task_id)
    task = Task.find(task_id)

    Async do
      execute_agent(task)
    end.wait

  rescue ClaudeAgentSDK::CLINotFoundError => e
    task.update!(status: 'failed', error: 'Claude CLI not installed')
    raise
  end

  private

  def execute_agent(task)
    # ... agent execution
  end
end
```

### HTTP MCP Servers

Connect to remote tool services:

```ruby
mcp_servers = {
  'api_tools' => ClaudeAgentSDK::McpHttpServerConfig.new(
    url: ENV['MCP_SERVER_URL'],
    headers: { 'Authorization' => "Bearer #{ENV['MCP_TOKEN']}" }
  ).to_h
}

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: mcp_servers,
  permission_mode: 'bypassPermissions'
)
```

### Observability in Rails

Add OpenTelemetry tracing to your Rails app with a single initializer:

```ruby
# config/initializers/opentelemetry.rb
require 'base64'
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'

if ENV['LANGFUSE_PUBLIC_KEY'].present?
  auth = Base64.strict_encode64("#{ENV['LANGFUSE_PUBLIC_KEY']}:#{ENV['LANGFUSE_SECRET_KEY']}")
  langfuse_host = ENV.fetch('LANGFUSE_HOST', 'https://cloud.langfuse.com')

  OpenTelemetry::SDK.configure do |c|
    c.service_name = Rails.application.class.module_parent_name.underscore
    c.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
        OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: "#{langfuse_host}/api/public/otel/v1/traces",
          headers: {
            'Authorization' => "Basic #{auth}",
            'x-langfuse-ingestion-version' => '4'
          }
        )
      )
    )
  end
end
```

```ruby
# config/initializers/claude_agent_sdk.rb
require 'claude_agent_sdk/instrumentation'

ClaudeAgentSDK.configure do |config|
  config.default_options = {
    permission_mode: 'bypassPermissions',
    observers: ENV['LANGFUSE_PUBLIC_KEY'].present? ? [
      # Use a lambda so each query gets a fresh observer instance (thread-safe).
      # A single shared instance would have its span state clobbered by concurrent requests.
      -> { ClaudeAgentSDK::Instrumentation::OTelObserver.new }
    ] : []
  }
end
```

Then every `ClaudeAgentSDK.query` and `Client` session automatically gets traced — no per-call wiring needed. The lambda factory ensures each request gets its own observer with isolated span state, safe for concurrent Puma/Sidekiq workers.

For complete examples, see:
- [examples/rails_actioncable_example.rb](examples/rails_actioncable_example.rb)
- [examples/rails_background_job_example.rb](examples/rails_background_job_example.rb)
- [examples/session_resumption_example.rb](examples/session_resumption_example.rb)
- [examples/http_mcp_server_example.rb](examples/http_mcp_server_example.rb)

## Types

See [lib/claude_agent_sdk/types.rb](lib/claude_agent_sdk/types.rb) for complete type definitions.

### Message Types

```ruby
# Union type of all possible messages
Message = UserMessage | AssistantMessage | SystemMessage | ResultMessage
```

#### UserMessage

User input message.

```ruby
class UserMessage
  attr_accessor :content,           # String | Array<ContentBlock>
                :uuid,              # String | nil - Unique ID for rewind support
                :parent_tool_use_id, # String | nil
                :tool_use_result    # Hash | nil - Tool result data when message is a tool response
end
```

#### AssistantMessage

Assistant response message with content blocks.

```ruby
class AssistantMessage
  attr_accessor :content,           # Array<ContentBlock>
                :model,             # String
                :parent_tool_use_id,# String | nil
                :error,             # String | nil ('authentication_failed', 'billing_error', 'rate_limit', 'invalid_request', 'server_error', 'unknown')
                :usage              # Hash | nil - Token usage info from the API response
end
```

#### SystemMessage

System message with metadata. Task lifecycle events are typed subclasses.

```ruby
class SystemMessage
  attr_accessor :subtype,  # String ('init', 'task_started', 'task_progress', 'task_notification', etc.)
                :data      # Hash
end

# Typed subclasses (all inherit from SystemMessage, so is_a?(SystemMessage) still works)
class TaskStartedMessage < SystemMessage
  attr_accessor :task_id, :description, :uuid, :session_id, :tool_use_id, :task_type
end

class TaskProgressMessage < SystemMessage
  attr_accessor :task_id, :description, :usage, :uuid, :session_id, :tool_use_id, :last_tool_name
end

class TaskNotificationMessage < SystemMessage
  attr_accessor :task_id, :status, :output_file, :summary, :uuid, :session_id, :tool_use_id, :usage
end
```

#### ResultMessage

Final result message with cost and usage information.

```ruby
class ResultMessage
  attr_accessor :subtype,           # String
                :duration_ms,       # Integer
                :duration_api_ms,   # Integer
                :is_error,          # Boolean
                :num_turns,         # Integer
                :session_id,        # String
                :stop_reason,       # String | nil ('end_turn', 'max_tokens', 'stop_sequence')
                :total_cost_usd,    # Float | nil
                :usage,             # Hash | nil
                :result,            # String | nil (final text result)
                :structured_output  # Hash | nil (when using output_format)
end
```

### Content Block Types

```ruby
# Union type of all content blocks
ContentBlock = TextBlock | ThinkingBlock | ToolUseBlock | ToolResultBlock | UnknownBlock
```

#### TextBlock

Text content block.

```ruby
class TextBlock
  attr_accessor :text  # String
end
```

#### ThinkingBlock

Thinking content block (for models with extended thinking capability).

```ruby
class ThinkingBlock
  attr_accessor :thinking,  # String
                :signature  # String
end
```

#### ToolUseBlock

Tool use request block.

```ruby
class ToolUseBlock
  attr_accessor :id,    # String
                :name,  # String
                :input  # Hash
end
```

#### ToolResultBlock

Tool execution result block.

```ruby
class ToolResultBlock
  attr_accessor :tool_use_id,  # String
                :content,      # String | Array<Hash> | nil
                :is_error      # Boolean | nil
end
```

#### UnknownBlock

Generic content block for types the SDK doesn't explicitly handle (e.g., `document` for PDFs, `image` for inline images). Preserves the raw data for forward compatibility with newer CLI versions.

```ruby
class UnknownBlock
  attr_accessor :type,  # String — the original block type (e.g., "document")
                :data   # Hash — the full raw block hash
end
```

### Error Types

```ruby
# Base exception class for all SDK errors
class ClaudeSDKError < StandardError; end

# Raised when connection to Claude Code fails
class CLIConnectionError < ClaudeSDKError; end

# Raised when the control protocol does not respond in time
class ControlRequestTimeoutError < CLIConnectionError; end

# Raised when Claude Code CLI is not found
class CLINotFoundError < CLIConnectionError
  # @param message [String] Error message (default: "Claude Code not found")
  # @param cli_path [String, nil] Optional path to the CLI that was not found
end

# Raised when the Claude Code process fails
class ProcessError < ClaudeSDKError
  attr_reader :exit_code,  # Integer | nil
              :stderr      # String | nil
end

# Raised when JSON parsing fails
class CLIJSONDecodeError < ClaudeSDKError
  attr_reader :line,           # String - The line that failed to parse
              :original_error  # Exception - The original JSON decode exception
end

# Raised when message parsing fails
class MessageParseError < ClaudeSDKError
  attr_reader :data  # Hash | nil
end
```

### Configuration Types

| Type | Description |
|------|-------------|
| `Configuration` | Global defaults via `ClaudeAgentSDK.configure` block |
| `ClaudeAgentOptions` | Main configuration for queries and clients |
| `HookMatcher` | Hook configuration with matcher pattern and timeout |
| `PermissionResultAllow` | Permission callback result to allow tool use |
| `PermissionResultDeny` | Permission callback result to deny tool use |
| `AgentDefinition` | Agent definition with description, prompt, tools, model, skills, memory, mcp_servers |
| `ThinkingConfigAdaptive` | Adaptive thinking mode (CLI dynamically adjusts budget) |
| `ThinkingConfigEnabled` | Enabled thinking with explicit `budget_tokens` |
| `ThinkingConfigDisabled` | Disabled thinking |
| `SdkMcpTool` | SDK MCP tool definition with name, description, input_schema, handler, annotations |
| `McpStdioServerConfig` | MCP server config for stdio transport |
| `McpSSEServerConfig` | MCP server config for SSE transport |
| `McpHttpServerConfig` | MCP server config for HTTP transport |
| `SdkPluginConfig` | SDK plugin configuration |
| `McpServerStatus` | Status of a single MCP server connection (with `.parse`) |
| `McpStatusResponse` | Response from `get_mcp_status` containing all server statuses (with `.parse`) |
| `McpServerInfo` | MCP server name and version |
| `McpToolInfo` | MCP tool name, description, and annotations |
| `McpToolAnnotations` | MCP tool annotation hints (`read_only`, `destructive`, `open_world`) |
| `TaskUsage` | Typed usage data (`total_tokens`, `tool_uses`, `duration_ms`) with `from_hash` factory |
| `SDKSessionInfo` | Session metadata from `list_sessions` |
| `SessionMessage` | Single message from `get_session_messages` |
| `SandboxSettings` | Sandbox settings for isolated command execution |
| `SandboxNetworkConfig` | Network configuration for sandbox |
| `SandboxIgnoreViolations` | Configure which sandbox violations to ignore |
| `SystemPromptPreset` | System prompt preset configuration |
| `ToolsPreset` | Tools preset configuration for base tools selection |

### Constants

| Constant | Description |
|----------|-------------|
| `SDK_BETAS` | Available beta features (e.g., `"context-1m-2025-08-07"`) |
| `PERMISSION_MODES` | Available permission modes |
| `SETTING_SOURCES` | Available setting sources |
| `HOOK_EVENTS` | Available hook events |
| `ASSISTANT_MESSAGE_ERRORS` | Possible error types in AssistantMessage |
| `TASK_NOTIFICATION_STATUSES` | Task lifecycle notification statuses (`completed`, `failed`, `stopped`) |
| `MCP_SERVER_CONNECTION_STATUSES` | MCP server connection states (`connected`, `failed`, `needs-auth`, `pending`, `disabled`) |

## Error Handling

### AssistantMessage Errors

`AssistantMessage` includes an `error` field for API-level errors:

```ruby
ClaudeAgentSDK.query(prompt: "Hello") do |message|
  if message.is_a?(ClaudeAgentSDK::AssistantMessage) && message.error
    case message.error
    when 'rate_limit'
      puts "Rate limited - retry after delay"
    when 'authentication_failed'
      puts "Check your API key"
    when 'billing_error'
      puts "Check your billing status"
    when 'invalid_request'
      puts "Invalid request format"
    when 'server_error'
      puts "Server error - retry later"
    end
  end
end
```

For complete examples, see [examples/error_handling_example.rb](examples/error_handling_example.rb).

### Exception Handling

```ruby
require 'claude_agent_sdk'

begin
  ClaudeAgentSDK.query(prompt: "Hello") do |message|
    puts message
  end
rescue ClaudeAgentSDK::ControlRequestTimeoutError
  puts "Control protocol timed out — consider increasing the timeout"
rescue ClaudeAgentSDK::CLINotFoundError
  puts "Please install Claude Code"
rescue ClaudeAgentSDK::ProcessError => e
  puts "Process failed with exit code: #{e.exit_code}"
rescue ClaudeAgentSDK::CLIJSONDecodeError => e
  puts "Failed to parse response: #{e}"
end
```

#### Configuring Timeout

The control request timeout defaults to **1200 seconds** (20 minutes) to accommodate long-running agent sessions. Override it via environment variable:

```bash
# Set a custom timeout (in seconds)
export CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS=300  # 5 minutes
```

### Error Types

| Error | Description |
|-------|-------------|
| `ClaudeSDKError` | Base error for all SDK errors |
| `CLIConnectionError` | Connection issues |
| `ControlRequestTimeoutError` | Control protocol timeout (configurable via env var) |
| `CLINotFoundError` | Claude Code not installed |
| `ProcessError` | Process failed (includes `exit_code` and `stderr`) |
| `CLIJSONDecodeError` | JSON parsing issues |
| `MessageParseError` | Message parsing issues |

See [lib/claude_agent_sdk/errors.rb](lib/claude_agent_sdk/errors.rb) for all error types.

## Available Tools

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code/settings#tools-available-to-claude) for a complete list of available tools.

## Examples

### Core Examples

| Example | Description |
|---------|-------------|
| [examples/quick_start.rb](examples/quick_start.rb) | Basic `query()` usage with options |
| [examples/client_example.rb](examples/client_example.rb) | Interactive Client usage |
| [examples/message_types_example.rb](examples/message_types_example.rb) | Handling all 24 SDK message types |
| [examples/streaming_input_example.rb](examples/streaming_input_example.rb) | Streaming input for multi-turn conversations |
| [examples/session_resumption_example.rb](examples/session_resumption_example.rb) | Multi-turn conversations with session persistence |
| [examples/structured_output_example.rb](examples/structured_output_example.rb) | JSON schema structured output |
| [examples/error_handling_example.rb](examples/error_handling_example.rb) | Error handling with `AssistantMessage.error` |
| [examples/bare_mode_example.rb](examples/bare_mode_example.rb) | Minimal startup with `bare: true` |
| [examples/sandbox_example.rb](examples/sandbox_example.rb) | Full sandbox settings (network, filesystem, violations) |

### MCP Server Examples

| Example | Description |
|---------|-------------|
| [examples/mcp_calculator.rb](examples/mcp_calculator.rb) | Custom tools with SDK MCP servers |
| [examples/mcp_resources_prompts_example.rb](examples/mcp_resources_prompts_example.rb) | MCP resources and prompts |
| [examples/http_mcp_server_example.rb](examples/http_mcp_server_example.rb) | HTTP/SSE MCP server configuration |

### Hooks & Permissions

| Example | Description |
|---------|-------------|
| [examples/hooks_example.rb](examples/hooks_example.rb) | Using hooks to control tool execution |
| [examples/advanced_hooks_example.rb](examples/advanced_hooks_example.rb) | Typed hook inputs/outputs (PreToolUse, PostToolUse) |
| [examples/lifecycle_hooks_example.rb](examples/lifecycle_hooks_example.rb) | All 27 hook events (SessionStart, Stop, PostCompact, etc.) |
| [examples/permission_callback_example.rb](examples/permission_callback_example.rb) | Dynamic tool permission control |

### Advanced Features

| Example | Description |
|---------|-------------|
| [examples/budget_control_example.rb](examples/budget_control_example.rb) | Budget control with `max_budget_usd` |
| [examples/fallback_model_example.rb](examples/fallback_model_example.rb) | Fallback model configuration |
| [examples/extended_thinking_example.rb](examples/extended_thinking_example.rb) | Extended thinking (API parity) |

### Observability

| Example | Description |
|---------|-------------|
| [examples/otel_langfuse_example.rb](examples/otel_langfuse_example.rb) | OpenTelemetry tracing with Langfuse backend |

### Rails Integration

| Example | Description |
|---------|-------------|
| [examples/rails_actioncable_example.rb](examples/rails_actioncable_example.rb) | ActionCable streaming to frontend |
| [examples/rails_background_job_example.rb](examples/rails_background_job_example.rb) | Background jobs with session resumption |

## Development

After checking out the repo, run `bundle install` to install dependencies. Then, run `bundle exec rspec` to run the tests.

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
