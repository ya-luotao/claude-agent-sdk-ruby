# Custom Tools (SDK MCP Servers)

A **custom tool** is a Ruby proc/lambda that you can offer to Claude, for Claude to invoke as needed. Custom tools are implemented as in-process MCP servers that run directly within your Ruby application, eliminating the need for separate processes that regular MCP servers require.

**Implementation:** This SDK uses the [official Ruby MCP SDK](https://github.com/modelcontextprotocol/ruby-sdk) (`mcp` gem) internally, providing full protocol compliance while offering a simpler block-based API for tool definition.

## Creating a Simple Tool

```ruby
require 'claude_agent_sdk'
require 'async'

greet_tool = ClaudeAgentSDK.create_tool(
  'greet', 'Greet a user', { name: :string },
  annotations: { title: 'Greeter', readOnlyHint: true }
) do |args|
  { content: [{ type: 'text', text: "Hello, #{args[:name]}!" }] }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(
  name: 'my-tools',
  version: '1.0.0',
  tools: [greet_tool]
)

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

## Pre-built JSON Schemas

If your schemas come from another library (e.g., [RubyLLM](https://github.com/crmne/ruby_llm)) that deep-stringifies keys, the SDK handles them transparently — both symbol-keyed and string-keyed schemas are accepted and normalized:

**Reserved argument name:** do not use `server_context` as a top-level tool
argument. The underlying MCP gem uses that keyword for injected request context
and would overwrite the user value before your handler runs. Registering a tool
whose root `properties` declare it raises `ArgumentError`, for both shorthand and
pre-built schemas (including directly constructed `SdkMcpTool` objects). For
composed, referenced, or free-form schemas, actual MCP calls containing this
top-level key return an actionable `isError: true` tool result before the handler
runs. This runtime guard remains active even if schema validation falls back to
a permissive schema. Rename the argument to something like `request_context`.
Nested object properties named `server_context` are safe and remain supported.

```ruby
# Symbol keys (standard Ruby)
ClaudeAgentSDK.create_tool('save', 'Save a fact', {
  type: 'object',
  properties: { fact: { type: 'string' } },
  required: ['fact']
}) { |args| { content: [{ type: 'text', text: "Saved: #{args[:fact]}" }] } }

# String keys (e.g., from RubyLLM or JSON.parse)
ClaudeAgentSDK.create_tool('save', 'Save a fact', {
  'type' => 'object',
  'properties' => { 'fact' => { 'type' => 'string' } },
  'required' => ['fact']
}) { |args| { content: [{ type: 'text', text: "Saved: #{args[:fact]}" }] } }
```

## Benefits Over External MCP Servers

- **No subprocess management** — runs in the same process as your application
- **Better performance** — no IPC overhead for tool calls
- **Simpler deployment** — single Ruby process instead of multiple
- **Easier debugging** — all code runs in the same process
- **Direct access** — tools can directly access your application's state

## Calculator Example

```ruby
add_tool = ClaudeAgentSDK.create_tool('add', 'Add two numbers', { a: :number, b: :number }) do |args|
  result = args[:a] + args[:b]
  { content: [{ type: 'text', text: "#{args[:a]} + #{args[:b]} = #{result}" }] }
end

divide_tool = ClaudeAgentSDK.create_tool('divide', 'Divide numbers', { a: :number, b: :number }) do |args|
  if args[:b] == 0
    { content: [{ type: 'text', text: 'Error: Division by zero' }], is_error: true }
  else
    { content: [{ type: 'text', text: "Result: #{args[:a] / args[:b]}" }] }
  end
end

calculator = ClaudeAgentSDK.create_sdk_mcp_server(
  name: 'calculator',
  tools: [add_tool, divide_tool]
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: { calc: calculator },
  allowed_tools: ['mcp__calc__add', 'mcp__calc__divide']
)
```

An exception raised inside a handler is returned to the model as an
`isError: true` result carrying the exception message, so it can self-correct.
This includes `exit`, `Interrupt` and other signal exceptions: they are reported
the same way, as the exception class and message (`"SystemExit: exit"`), instead
of escaping the session and leaving the CLI waiting on the tool call. Your
process keeps running. Cancellation of the tool call itself still propagates.

## Mixed Server Support

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

A hand-written SDK entry may use String or Symbol keys:
`{ 'type' => 'sdk', 'name' => 'calc', 'instance' => server }` behaves exactly like
the Hash `create_sdk_mcp_server` returns. The instance is registered in-process
and is never sent to the CLI.

## MCP Resources and Prompts

SDK MCP servers can also expose **resources** (data sources) and **prompts** (reusable templates):

```ruby
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

review_prompt = ClaudeAgentSDK.create_prompt(
  name: 'code_review',
  description: 'Review code for best practices',
  arguments: [{ name: 'code', description: 'Code to review', required: true }]
) do |args|
  {
    messages: [{
      role: 'user',
      content: { type: 'text', text: "Review this code: #{args[:code]}" }
    }]
  }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(
  name: 'dev-tools',
  tools: [my_tool],
  resources: [config_resource],
  prompts: [review_prompt]
)
```

An exception raised inside a resource reader or prompt generator is answered
with a JSON-RPC internal error (`-32603`) carrying the exception message. `exit`,
`Interrupt` and other signal exceptions are reported the same way (as
`"SystemExit: exit"`, `"Interrupt: Interrupt"`, ...) and do not end your process.

See [examples/mcp_calculator.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/mcp_calculator.rb) and [examples/mcp_resources_prompts_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/mcp_resources_prompts_example.rb) for complete examples.
