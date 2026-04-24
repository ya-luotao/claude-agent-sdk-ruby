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
- Custom Transport
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
- Bare Mode
- File Checkpointing & Rewind
- Session Browsing
- Session Mutations
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

Bare mode (minimal startup):
```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  bare: true,
  system_prompt: 'You are a helpful assistant.',
  add_dirs: ['/path/to/project'],
  permission_mode: 'bypassPermissions'
)

ClaudeAgentSDK.query(prompt: "Review this code", options: options) do |msg|
  puts msg if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
end
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

# Opus 4.7 defaults thinking display to "omitted" (empty thinking field,
# signature only). Pass display: "summarized" to receive plaintext
# thinking text. Valid values: "summarized", "omitted".
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new(display: 'summarized')
)

# Effort level — see ClaudeAgentSDK::EFFORT_LEVELS
# ('low', 'medium', 'high', 'xhigh', 'max'; model-dependent)
options = ClaudeAgentSDK::ClaudeAgentOptions.new(effort: 'xhigh')
```

Full sandbox configuration:
```ruby
sandbox = ClaudeAgentSDK::SandboxSettings.new(
  enabled: true,
  fail_if_unavailable: true,
  auto_allow_bash_if_sandboxed: true,
  network: ClaudeAgentSDK::SandboxNetworkConfig.new(
    allowed_domains: ['api.example.com', 'cdn.example.com'],
    allow_local_binding: true
  ),
  filesystem: ClaudeAgentSDK::SandboxFilesystemConfig.new(
    allow_write: ['/tmp/output'],
    deny_read: ['/etc/secrets']
  ),
  ignore_violations: { 'network' => ['metrics.internal'] },
  enable_weaker_network_isolation: false
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  sandbox: sandbox,
  permission_mode: 'acceptEdits'
)
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

All message types (comprehensive handler):
```ruby
ClaudeAgentSDK.query(prompt: "Do something", options: options) do |msg|
  case msg
  when ClaudeAgentSDK::InitMessage
    puts "Session started: #{msg.session_id} (#{msg.claude_code_version})"
  when ClaudeAgentSDK::AssistantMessage
    puts msg.text
  when ClaudeAgentSDK::CompactBoundaryMessage
    puts "Compacted: #{msg.compact_metadata&.pre_tokens} tokens (#{msg.compact_metadata&.trigger})"
  when ClaudeAgentSDK::StatusMessage
    puts "Status: #{msg.status}" if msg.status
  when ClaudeAgentSDK::TaskStartedMessage
    puts "Task #{msg.task_id} started: #{msg.description}"
  when ClaudeAgentSDK::TaskProgressMessage
    puts "Task #{msg.task_id} progress (#{msg.summary})"
  when ClaudeAgentSDK::TaskNotificationMessage
    puts "Task #{msg.task_id} #{msg.status}: #{msg.summary}"
  when ClaudeAgentSDK::ToolProgressMessage
    puts "Tool #{msg.tool_name} running (#{msg.elapsed_time_seconds}s)"
  when ClaudeAgentSDK::HookStartedMessage
    puts "Hook #{msg.hook_name} started (#{msg.hook_event})"
  when ClaudeAgentSDK::HookResponseMessage
    puts "Hook #{msg.hook_name}: #{msg.outcome}"
  when ClaudeAgentSDK::SessionStateChangedMessage
    puts "Session state: #{msg.state}"
  when ClaudeAgentSDK::AuthStatusMessage
    puts "Auth: #{msg.is_authenticating ? 'authenticating...' : 'done'}"
  when ClaudeAgentSDK::PromptSuggestionMessage
    puts "Suggested next: #{msg.suggestion}"
  when ClaudeAgentSDK::APIRetryMessage
    puts "API retry #{msg.attempt}/#{msg.max_retries} (#{msg.error})"
  when ClaudeAgentSDK::ResultMessage
    puts "Done in #{msg.duration_ms}ms, cost: $#{msg.total_cost_usd}"
    puts "Stop reason: #{msg.stop_reason}"
    puts "Model usage: #{msg.model_usage}" if msg.model_usage
    puts "Errors: #{msg.errors}" if msg.errors
  when ClaudeAgentSDK::RateLimitEvent
    puts "Rate limit: #{msg.rate_limit_info.status}"
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

Session mutations:
```ruby
# Rename a session
ClaudeAgentSDK.rename_session(session_id: 'uuid', title: 'My Feature Work')

# Tag a session
ClaudeAgentSDK.tag_session(session_id: 'uuid', tag: 'important')

# Clear a tag
ClaudeAgentSDK.tag_session(session_id: 'uuid', tag: nil)
```

Hook with all 27 events example:
```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  hooks: {
    'PreToolUse' => [
      ClaudeAgentSDK::HookMatcher.new(
        matcher: 'Bash',
        hooks: [->(input, _tool_use_id, _ctx) {
          puts "About to run: #{input.tool_input}"
          {} # allow
        }]
      )
    ],
    'SessionStart' => [
      ClaudeAgentSDK::HookMatcher.new(
        hooks: [->(input, _id, _ctx) {
          puts "Session starting (source: #{input.source})"
          {}
        }]
      )
    ],
    'Stop' => [
      ClaudeAgentSDK::HookMatcher.new(
        hooks: [->(input, _id, _ctx) {
          puts "Stopped. Last message: #{input.last_assistant_message}"
          {}
        }]
      )
    ]
  }
)
```
