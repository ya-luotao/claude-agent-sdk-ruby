# Claude Agent SDK for Ruby

> **Disclaimer**: This is an **unofficial, community-maintained** Ruby SDK for Claude Agent. It is not officially supported by Anthropic. For official SDK support, see the [Python SDK](https://docs.claude.com/en/api/agent-sdk/python).
>
> This implementation is based on the official Python SDK and aims to provide feature parity for Ruby developers. Use at your own risk.

[![Gem Version](https://badge.fury.io/rb/claude-agent-sdk.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/claude-agent-sdk)

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Basic Usage: query()](#basic-usage-query)
- [Client](#client)
- [Custom Tools (SDK MCP Servers)](#custom-tools-sdk-mcp-servers)
- [Hooks](#hooks)
- [Permission Callbacks](#permission-callbacks)
- [Structured Output](#structured-output)
- [Budget Control](#budget-control)
- [Fallback Model](#fallback-model)
- [Beta Features](#beta-features)
- [Tools Configuration](#tools-configuration)
- [Sandbox Settings](#sandbox-settings)
- [File Checkpointing & Rewind](#file-checkpointing--rewind)
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
gem 'claude-agent-sdk', '~> 0.4.0'
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

If you're using [Claude Code](https://claude.ai/claude-code) or another agentic coding tool that supports [skills](https://skills.sh), you can install the SDK skill:

```bash
npx skills add https://github.com/ya-luotao/claude-agent-sdk-ruby --skill claude-agent-sdk-ruby
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
  if message.is_a?(ClaudeAgentSDK::AssistantMessage)
    message.content.each do |block|
      puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  end
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
      if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
        msg.content.each do |block|
          puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      elsif msg.is_a?(ClaudeAgentSDK::ResultMessage)
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
  info = client.server_info
  puts "Available commands: #{info}"

  # (Parity alias) Get server initialization info
  info = client.get_server_info
  puts "Available commands: #{info}"

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

# Define a tool using create_tool
greet_tool = ClaudeAgentSDK.create_tool('greet', 'Greet a user', { name: :string }) do |args|
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

- `PreToolUse` → `PreToolUseHookInput` (`tool_name`, `tool_input`)
- `PostToolUse` → `PostToolUseHookInput` (`tool_name`, `tool_input`, `tool_response`)
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

Run commands in an isolated sandbox for additional security:

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
      # Handle assistant responses
      message.content.each do |block|
        puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
      end
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

## Rails Integration

The SDK integrates well with Rails applications. Here are common patterns:

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
            text = extract_text(message)
            ChatChannel.broadcast_to(chat_id, { type: 'chunk', content: text })

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

  private

  def extract_text(message)
    message.content
      .select { |b| b.is_a?(ClaudeAgentSDK::TextBlock) }
      .map(&:text)
      .join("\n\n")
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
                :parent_tool_use_id # String | nil
end
```

#### AssistantMessage

Assistant response message with content blocks.

```ruby
class AssistantMessage
  attr_accessor :content,           # Array<ContentBlock>
                :model,             # String
                :parent_tool_use_id,# String | nil
                :error              # String | nil ('authentication_failed', 'billing_error', 'rate_limit', 'invalid_request', 'server_error', 'unknown')
end
```

#### SystemMessage

System message with metadata.

```ruby
class SystemMessage
  attr_accessor :subtype,  # String ('init', etc.)
                :data      # Hash
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
                :total_cost_usd,    # Float | nil
                :usage,             # Hash | nil
                :result,            # String | nil (final text result)
                :structured_output  # Hash | nil (when using output_format)
end
```

### Content Block Types

```ruby
# Union type of all content blocks
ContentBlock = TextBlock | ThinkingBlock | ToolUseBlock | ToolResultBlock
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

### Error Types

```ruby
# Base exception class for all SDK errors
class ClaudeSDKError < StandardError; end

# Raised when Claude Code CLI is not found
class CLINotFoundError < CLIConnectionError
  # @param message [String] Error message (default: "Claude Code not found")
  # @param cli_path [String, nil] Optional path to the CLI that was not found
end

# Raised when connection to Claude Code fails
class CLIConnectionError < ClaudeSDKError; end

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
| `ClaudeAgentOptions` | Main configuration for queries and clients |
| `HookMatcher` | Hook configuration with matcher pattern and timeout |
| `PermissionResultAllow` | Permission callback result to allow tool use |
| `PermissionResultDeny` | Permission callback result to deny tool use |
| `AgentDefinition` | Agent definition with description, prompt, tools, model |
| `McpStdioServerConfig` | MCP server config for stdio transport |
| `McpSSEServerConfig` | MCP server config for SSE transport |
| `McpHttpServerConfig` | MCP server config for HTTP transport |
| `SdkPluginConfig` | SDK plugin configuration |
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
rescue ClaudeAgentSDK::CLINotFoundError
  puts "Please install Claude Code"
rescue ClaudeAgentSDK::ProcessError => e
  puts "Process failed with exit code: #{e.exit_code}"
rescue ClaudeAgentSDK::CLIJSONDecodeError => e
  puts "Failed to parse response: #{e}"
end
```

### Error Types

| Error | Description |
|-------|-------------|
| `ClaudeSDKError` | Base error for all SDK errors |
| `CLINotFoundError` | Claude Code not installed |
| `CLIConnectionError` | Connection issues |
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
| [examples/streaming_input_example.rb](examples/streaming_input_example.rb) | Streaming input for multi-turn conversations |
| [examples/session_resumption_example.rb](examples/session_resumption_example.rb) | Multi-turn conversations with session persistence |
| [examples/structured_output_example.rb](examples/structured_output_example.rb) | JSON schema structured output |
| [examples/error_handling_example.rb](examples/error_handling_example.rb) | Error handling with `AssistantMessage.error` |

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
| [examples/advanced_hooks_example.rb](examples/advanced_hooks_example.rb) | Typed hook inputs/outputs |
| [examples/permission_callback_example.rb](examples/permission_callback_example.rb) | Dynamic tool permission control |

### Advanced Features

| Example | Description |
|---------|-------------|
| [examples/budget_control_example.rb](examples/budget_control_example.rb) | Budget control with `max_budget_usd` |
| [examples/fallback_model_example.rb](examples/fallback_model_example.rb) | Fallback model configuration |
| [examples/extended_thinking_example.rb](examples/extended_thinking_example.rb) | Extended thinking (API parity) |

### Rails Integration

| Example | Description |
|---------|-------------|
| [examples/rails_actioncable_example.rb](examples/rails_actioncable_example.rb) | ActionCable streaming to frontend |
| [examples/rails_background_job_example.rb](examples/rails_background_job_example.rb) | Background jobs with session resumption |

## Development

After checking out the repo, run `bundle install` to install dependencies. Then, run `bundle exec rspec` to run the tests.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
