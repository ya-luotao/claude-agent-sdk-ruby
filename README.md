# Claude Agent SDK for Ruby

Ruby SDK for Claude Agent. See the [Claude Agent SDK documentation](https://docs.anthropic.com/en/docs/claude-code/sdk) for more information.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'claude-agent-sdk'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install claude-agent-sdk
```

**Prerequisites:**
- Ruby 3.0+
- Node.js
- Claude Code 2.0.0+: `npm install -g @anthropic-ai/claude-code`

## Quick Start

```ruby
require 'claude_agent_sdk'

ClaudeAgentSDK.query(prompt: "What is 2 + 2?") do |message|
  puts message
end
```

## Basic Usage: query()

`query()` is a function for querying Claude Code. It yields response messages to a block. See [lib/claude_agent_sdk.rb](lib/claude_agent_sdk.rb).

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

## Client

`ClaudeAgentSDK::Client` supports bidirectional, interactive conversations with Claude Code. Unlike `query()`, `Client` enables **hooks** and **permission callbacks**, both of which can be defined as Ruby procs/lambdas. See [lib/claude_agent_sdk.rb](lib/claude_agent_sdk.rb).

### Basic Client Usage

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  client = ClaudeAgentSDK::Client.new

  begin
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

### Hooks

A **hook** is a Ruby proc/lambda that the Claude Code *application* (*not* Claude) invokes at specific points of the Claude agent loop. Hooks can provide deterministic processing and automated feedback for Claude. Read more in [Claude Code Hooks Reference](https://docs.anthropic.com/en/docs/claude-code/hooks).

For more examples, see [examples/hooks_example.rb](examples/hooks_example.rb).

#### Example

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  # Define a hook that blocks dangerous bash commands
  bash_hook = lambda do |input, tool_use_id, context|
    tool_name = input[:tool_name]
    tool_input = input[:tool_input]

    return {} unless tool_name == 'Bash'

    command = tool_input[:command] || ''
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

### Permission Callbacks

A **permission callback** is a Ruby proc/lambda that allows you to programmatically control tool execution. This gives you fine-grained control over what tools Claude can use and with what inputs.

For more examples, see [examples/permission_callback_example.rb](examples/permission_callback_example.rb).

#### Example

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

### Advanced Client Features

The Client class supports several advanced features:

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

  # Get server initialization info
  info = client.server_info
  puts "Available commands: #{info}"

  client.disconnect
end.wait
```

## Types

See [lib/claude_agent_sdk/types.rb](lib/claude_agent_sdk/types.rb) for complete type definitions:
- `ClaudeAgentOptions` - Configuration options
- `AssistantMessage`, `UserMessage`, `SystemMessage`, `ResultMessage` - Message types
- `TextBlock`, `ToolUseBlock`, `ToolResultBlock` - Content blocks

## Error Handling

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

Error types:
- `ClaudeSDKError` - Base error
- `CLINotFoundError` - Claude Code not installed
- `CLIConnectionError` - Connection issues
- `ProcessError` - Process failed
- `CLIJSONDecodeError` - JSON parsing issues
- `MessageParseError` - Message parsing issues

See [lib/claude_agent_sdk/errors.rb](lib/claude_agent_sdk/errors.rb) for all error types.

## Available Tools

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code/settings#tools-available-to-claude) for a complete list of available tools.

## Examples

See the following examples for complete working code:

- [examples/quick_start.rb](examples/quick_start.rb) - Basic `query()` usage with options
- [examples/client_example.rb](examples/client_example.rb) - Interactive Client usage
- [examples/hooks_example.rb](examples/hooks_example.rb) - Using hooks to control tool execution
- [examples/permission_callback_example.rb](examples/permission_callback_example.rb) - Dynamic tool permission control

## Development

After checking out the repo, run `bundle install` to install dependencies. Then, run `bundle exec rspec` to run the tests.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/anthropics/claude-agent-sdk-ruby.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
