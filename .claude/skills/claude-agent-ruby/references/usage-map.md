# Usage Map (Gem Install)

## Locate gem docs (no repo needed)
- Bundler: `bundle show claude-agent-sdk`
- RubyGems: `ruby -e 'puts Gem::Specification.find_by_name("claude-agent-sdk").full_gem_path'`
- Open `<gem_path>/README.md`, `<gem_path>/lib/claude_agent_sdk/types.rb`, and `<gem_path>/lib/claude_agent_sdk/errors.rb`.

## README section map
- Installation
- Quick Start
- Basic Usage: query()
- Client
- Custom Tools (SDK MCP Servers)
- Hooks
- Permission Callbacks
- Structured Output
- Thinking Configuration
- Budget Control
- Fallback Model
- Beta Features
- Tools Configuration
- Sandbox Settings
- File Checkpointing & Rewind
- Session Browsing
- Rails Integration
- Types
- Error Handling

## Minimal skeletons

One-shot query:
```ruby
require 'claude_agent_sdk'

ClaudeAgentSDK.query(prompt: "Hello") { |msg| puts msg }
```

Interactive client:
```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  client = ClaudeAgentSDK::Client.new
  client.connect
  client.query("Hello")
  client.receive_response { |msg| puts msg }
  client.disconnect
end.wait
```

SDK MCP tool (with optional annotations):
```ruby
tool = ClaudeAgentSDK.create_tool(
  'greet', 'Greet a user', { name: :string },
  annotations: { title: 'Greeter', readOnlyHint: true }
) do |args|
  { content: [{ type: 'text', text: "Hello, #{args[:name]}!" }] }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'tools', tools: [tool])

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: { tools: server },
  allowed_tools: ['mcp__tools__greet']
)
```

SDK MCP tool (pre-built JSON schema, e.g. from RubyLLM):
```ruby
tool = ClaudeAgentSDK.create_tool('save', 'Save a fact', {
  'type' => 'object',
  'properties' => { 'fact' => { 'type' => 'string' } },
  'required' => ['fact']
}) { |args| { content: [{ type: 'text', text: "Saved: #{args[:fact]}" }] } }
```

SDK MCP tool (no parameters):
```ruby
tool = ClaudeAgentSDK.create_tool('ping', 'Ping the server', {}) do |_args|
  { content: [{ type: 'text', text: 'pong' }] }
end
```

Thinking configuration:
```ruby
# Adaptive (32k default budget)
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new
)

# Custom budget
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  thinking: ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 10_000)
)

# Effort level
options = ClaudeAgentSDK::ClaudeAgentOptions.new(effort: 'high')
```

MCP server control (Client only):
```ruby
Async do
  client = ClaudeAgentSDK::Client.new
  client.connect

  # Reconnect a failed server
  client.reconnect_mcp_server('my-server')

  # Disable a server
  client.toggle_mcp_server('my-server', false)

  # Stop a background task
  client.stop_task('task_abc123')

  # Get typed MCP status
  raw = client.get_mcp_status
  status = ClaudeAgentSDK::McpStatusResponse.parse(raw)
  status.mcp_servers.each do |s|
    puts "#{s.name}: #{s.status}"
  end

  client.disconnect
end.wait
```

Task lifecycle messages:
```ruby
ClaudeAgentSDK.query(prompt: "Do something") do |msg|
  case msg
  when ClaudeAgentSDK::TaskStartedMessage
    puts "Task #{msg.task_id} started: #{msg.description}"
  when ClaudeAgentSDK::TaskProgressMessage
    puts "Task #{msg.task_id} progress: #{msg.usage}"
  when ClaudeAgentSDK::TaskNotificationMessage
    puts "Task #{msg.task_id} #{msg.status}: #{msg.summary}"
  when ClaudeAgentSDK::ResultMessage
    puts "Done (stop_reason: #{msg.stop_reason})"
  end
end
```

Session browsing (no CLI needed):
```ruby
require 'claude_agent_sdk'

# List recent sessions
sessions = ClaudeAgentSDK.list_sessions(limit: 10)
sessions.each do |s|
  puts "#{s.session_id}: #{s.summary} (#{s.git_branch})"
end

# Read messages from a session
messages = ClaudeAgentSDK.get_session_messages(session_id: sessions.first.session_id)
messages.each do |m|
  puts "[#{m.type}] #{m.message}"
end

# List sessions for a specific directory
sessions = ClaudeAgentSDK.list_sessions(directory: '/path/to/project', include_worktrees: true)
```
