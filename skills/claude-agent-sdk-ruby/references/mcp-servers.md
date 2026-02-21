# MCP servers (custom tools)

Use MCP servers to offer tools/resources/prompts to Claude.

You can run MCP servers in-process (SDK MCP servers) or connect to external servers.

## SDK MCP servers (in-process)

Define tools as Ruby procs/lambdas, then mount them as an SDK MCP server.

```ruby
require "claude_agent_sdk"
require "async"

greet_tool = ClaudeAgentSDK.create_tool("greet", "Greet a user", { name: :string }) do |args|
  { content: [{ type: "text", text: "Hello, #{args[:name]}!" }] }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(
  name: "tools",
  version: "1.0.0",
  tools: [greet_tool]
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: { tools: server },
  allowed_tools: ["mcp__tools__greet"]
)

Async do
  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect
  client.query("Greet Alice")
  client.receive_response { |msg| puts msg.inspect }
ensure
  client&.disconnect
end.wait
```

Tool return shape:
- Return `{ content: [{ type: "text", text: "..." }], is_error: true|false }`.
- Tools with no parameters can use an empty schema: `input_schema: {}` (fixed in v0.7.2).

## External MCP servers

Configure external servers in `ClaudeAgentOptions#mcp_servers` using hashes or config helpers:

- Stdio (subprocess): `ClaudeAgentSDK::McpStdioServerConfig.new(command: "...", args: [...], env: {...}).to_h`
- SSE: `ClaudeAgentSDK::McpSSEServerConfig.new(url: "...", headers: {...}).to_h`
- HTTP: `ClaudeAgentSDK::McpHttpServerConfig.new(url: "...", headers: {...}).to_h`

Example:

```ruby
mcp_servers = {
  "api_tools" => ClaudeAgentSDK::McpHttpServerConfig.new(
    url: ENV.fetch("MCP_SERVER_URL"),
    headers: { "Authorization" => "Bearer #{ENV.fetch("MCP_TOKEN")}" }
  ).to_h
}

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: mcp_servers,
  permission_mode: "bypassPermissions"
)
```

## Resources and prompts (SDK MCP)

SDK MCP servers can also expose resources and prompts via `ClaudeAgentSDK.create_resource` and `ClaudeAgentSDK.create_prompt`.
