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
- Budget Control
- Fallback Model
- Beta Features
- Tools Configuration
- Sandbox Settings
- File Checkpointing & Rewind
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

SDK MCP tool:
```ruby
tool = ClaudeAgentSDK.create_tool('greet', 'Greet a user', { name: :string }) do |args|
  { content: [{ type: 'text', text: "Hello, #{args[:name]}!" }] }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'tools', tools: [tool])

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: { tools: server },
  allowed_tools: ['mcp__tools__greet']
)
```
