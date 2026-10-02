# Client & Custom Transport

`ClaudeAgentSDK::Client` keeps one Claude Code session open for a conversation you drive. What it adds over `query()` is lifecycle: you can send follow-up queries in the same session, and you can call the CLI while the session runs (`interrupt`, switch the model or the permission mode, inspect and reconnect MCP servers, rewind files, stop or background a task).

**Custom tools**, **hooks** and **permission callbacks** are not part of that difference. `query()` and `ask` speak the same control protocol as `Client`, so all three run them; each is a Ruby proc or lambda you pass in `ClaudeAgentOptions`.

For a single question you don't need a session: `ClaudeAgentSDK.ask(prompt, options:)` runs `query()` to completion and returns the final `ResultMessage` (`#result` is the answer text), optionally yielding each message to a block on the way. See the README's [Quick Start](../README.md#quick-start).

## Basic Usage

`Client.open` connects, yields the client, and always disconnects when the block exits (exceptions propagate after the disconnect). It returns the block's value, and creates an `async` reactor if it isn't already running inside one.

```ruby
require 'claude_agent_sdk'

ClaudeAgentSDK::Client.open do |client|
  client.query("What is the capital of France?")

  client.receive_response do |msg|
    case msg
    when ClaudeAgentSDK::AssistantMessage
      puts msg.text
    when ClaudeAgentSDK::ResultMessage
      puts "Cost: $#{msg.total_cost_usd}" if msg.total_cost_usd
    end
  end
end
```

Called outside a reactor, `break` inside the `Client.open` block raises `LocalJumpError` (the client still disconnects), so return a value from the block instead. `break` inside `receive_response` / `receive_messages` is fine. It stops the iteration.

If your code already runs inside an `Async` reactor and you want to manage the connection yourself, call `connect` and `disconnect` directly:

```ruby
client = ClaudeAgentSDK::Client.new
begin
  client.connect
  client.query("What is the capital of France?")
  client.receive_response { |msg| puts msg }
ensure
  client.disconnect
end
```

## Advanced Features

```ruby
Async do
  client = ClaudeAgentSDK::Client.new
  client.connect

  client.interrupt                              # Send interrupt signal
  client.permission_mode = 'acceptEdits'        # Change permission mode mid-conversation
  client.model = 'claude-sonnet-5'              # Switch model mid-conversation (nil = default)
  usage  = client.context_usage                 # Context window usage by category
  status = client.mcp_status                    # Inspect MCP server status
  info   = client.get_server_info               # Inspect server init info
  client.reconnect_mcp_server('my-server')      # Reconnect a failed MCP server
  client.toggle_mcp_server('my-server', false)  # Enable/disable an MCP server
  client.stop_task('task_abc123')               # Stop a running background task
  client.background_tasks                       # Background every foreground task (Ctrl+B) => {}
  client.background_tasks(tool_use_id: 'toolu_01') # Only the task spawned by that tool_use block
                                                # => { backgrounded: true } | { backgrounded: false } (definitive miss)
                                                # '' or a non-String raises ArgumentError; nil is the all-tasks form

  client.disconnect
end.wait
```

The Ruby-style names above sit next to the Python SDK's spellings, and both work, so code ported from the Python docs runs unchanged:

| Ruby style | Python-parity name |
|------------|--------------------|
| `client.model = 'haiku'` | `client.set_model('haiku')` |
| `client.permission_mode = 'plan'` | `client.set_permission_mode('plan')` |
| `client.context_usage` | `client.get_context_usage` |
| `client.mcp_status` | `client.get_mcp_status` |
| `client.server_info` | `client.get_server_info` |

Each Ruby-style method calls its parity counterpart, so both send the same control request and raise `CLIConnectionError` when the client is not connected. The one exception is `server_info`, which reads the cached initialization result and returns `nil` instead of raising before `connect`. As with any Ruby setter, `client.model = 'haiku'` evaluates to `'haiku'`, not to the control response.

### MCP status and context usage return Hashes

`mcp_status` / `get_mcp_status` and `context_usage` / `get_context_usage` return the CLI's control response payload as a plain Hash, unchanged: Symbol keys spelled as on the wire, which for these payloads is camelCase (`:mcpServers`, `:serverInfo`, `:totalTokens`), at every level of nesting (see [Hash keys](types.md#hash-keys)). The SDK does not model or filter the payload, so fields added by newer CLI versions come through. A response without a payload reads as `{}`.

```ruby
status = client.mcp_status
status[:mcpServers].each { |s| puts "#{s[:name]}: #{s[:status]}" }
status.dig(:mcpServers, 0, :serverInfo, :version)

usage = client.context_usage
puts "#{usage[:totalTokens]} / #{usage[:maxTokens]} tokens"
```

For a typed view of the MCP status, parse the Hash yourself:

```ruby
typed = ClaudeAgentSDK::McpStatusResponse.parse(client.mcp_status)
typed.mcp_servers.each do |server|            # McpServerStatus
  puts "#{server.name} #{server.status} #{server.server_info&.version}"
  server.tools&.each { |tool| puts "  #{tool.name} read_only=#{tool.annotations&.read_only}" }
end
```

`McpServerStatus#config` is an `McpSdkServerConfigStatus` or `McpClaudeAIProxyServerConfig` for `sdk` and `claudeai-proxy` servers, and the raw Hash for every other server type. There is no typed class for context usage; read the Hash.

## Custom Transport

By default, `Client` uses `SubprocessCLITransport` to spawn the Claude Code CLI locally. You can provide a custom transport class to connect via other channels (e.g., remote SSH, WebSocket, or a sandbox VM).

A transport must implement six methods:

| Method | Purpose |
|---|---|
| `connect` | Establish the connection / spawn the remote CLI |
| `write(data)` | Send raw JSON-line bytes to stdin |
| `read_messages { \|hash\| ... }` | Yield each stdout line as a Hash parsed with `JSON.parse(line, symbolize_names: true)` (the SDK reads Symbol keys; see [Hash keys](types.md#hash-keys)); block until the stream closes |
| `end_input` | Signal EOF on stdin |
| `close` | Terminate and clean up |
| `ready?` | Report whether the transport can accept I/O |

**Environment your transport should give the CLI.** `SubprocessCLITransport`
sets a few variables that a custom transport has to set itself. The one that
changes SDK behavior is `CLAUDE_CODE_SDK_READS_SESSION_STATE=1`: with it, the
CLI reports its session state, and a one-shot `query()` with hooks,
`can_use_tool` or SDK MCP servers keeps stdin open until the CLI reports
`idle`. That is what lets a follow-up turn woken by a background subagent get
its control requests answered. Without it, `query()` closes stdin at the first
result with no tracked task in flight, the pre-1.1 behavior. The state frames
arrive marked `sdk_host_only`, and the SDK drops them from your message
stream.

Then plug it into `Client` via `transport_class:` / `transport_args:`. All connect orchestration (option transforms, MCP extraction, hook conversion, Query lifecycle) is handled for you.

```ruby
client = ClaudeAgentSDK::Client.new(
  options: options,
  transport_class: MyTransport,
  transport_args: { foo: 'bar' } # forwarded to MyTransport.new(options, **transport_args)
)
```

### One-shot queries over a custom transport

`ClaudeAgentSDK.query` and `ClaudeAgentSDK.ask` take a transport as well: a ready-made instance in `transport:`, not a class.

```ruby
transport = MyTransport.new(options, foo: 'bar')
ClaudeAgentSDK.query(prompt: 'Hello', options: options, transport: transport) { |message| puts message }

result = ClaudeAgentSDK.ask('Hello', options: options, transport: MyTransport.new(options, foo: 'bar'))
```

- The SDK connects the transport, runs the query over it and closes it, so one instance serves one query. `close` is called even when `connect` raised, and it must be idempotent.
- `options` still drives everything the SDK does on its own side: hooks, SDK MCP servers, agents, observers, callback scheduling. The command line and the environment are whatever your transport gives the CLI. `query` does not rebuild them from `options`, so build the transport from the same options.
- With a transport of your own, `can_use_tool` works through `Client` only. The CLI asks the callback when it is started with `--permission-prompt-tool stdio`; the options a `transport_class:` transport receives already carry that (`permission_prompt_tool_name: 'stdio'`), and a transport you built yourself does not get it from `query`.
- Anything that does not respond to `connect` raises `ArgumentError`.

Resuming from a `session_store` is not available over a custom transport, through `query(transport:)` or `transport_class:`: the SDK prepares the transcript only for a CLI it starts with `SubprocessCLITransport` (or a subclass of it).

### Reference: running `claude` inside an E2B sandbox

[`examples/e2b_transport_example.rb`](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/e2b_transport_example.rb) is a working transport that runs the Claude Code CLI inside an [E2B](https://e2b.dev) Firecracker microVM instead of on your host. The wire protocol stays identical — only the I/O layer changes:

```
ClaudeAgentSDK::Client (host)
    │  JSON-lines
    ▼
E2BCliTransport (host)
    │  send_stdin / commands.run(background:) / CommandHandle#each
    ▼
E2B envd RPC (HTTP/2)
    │
    ▼
/usr/local/bin/claude (in-VM subprocess)
```

The example reuses the SDK's `CommandBuilder` to produce the exact same argv that `SubprocessCLITransport` would build (including SDK MCP server `:instance` field stripping), shell-escapes it for E2B's `/bin/bash -l -c` execution path, and streams stdout/stderr back through `CommandHandle#each`.

Sketch (full file is ~250 lines):

```ruby
require 'claude_agent_sdk'
require 'e2b'

class E2BCliTransport < ClaudeAgentSDK::Transport
  def initialize(options, sandbox:, cli_path: '/usr/local/bin/claude')
    @options, @sandbox, @cli_path = options, sandbox, cli_path
  end

  def connect
    argv = ClaudeAgentSDK::CommandBuilder.new(@cli_path, @options).build
    cmd = argv.map { |a| Shellwords.shellescape(a.to_s) }.join(' ')
    @handle = @sandbox.commands.run(cmd, background: true, stdin: true,
                                    cwd: @options.cwd&.to_s, envs: build_env)
    @pid = @handle.pid
    @ready = true
  end

  def write(data)         = @sandbox.commands.send_stdin(@pid, data)
  def end_input           = @sandbox.commands.close_stdin(@pid)
  def close               = @handle&.kill
  def ready?              = @ready

  def read_messages(&block)
    buf = +''
    @handle.each do |stdout, stderr, _pty|
      next if stderr && !stderr.empty?
      stdout.each_line do |line|
        buf << line.strip
        begin
          yield JSON.parse(buf, symbolize_names: true)
          buf.clear
        rescue JSON::ParserError
          # JSON line split across reads — keep buffering
        end
      end
    end
    @handle.wait # raises E2B::CommandExitError on non-zero exit
  end
end

sandbox = E2B::Sandbox.create(template: 'base', timeout: 600)
Async do
  client = ClaudeAgentSDK::Client.new(
    options: options,
    transport_class: E2BCliTransport,
    transport_args: { sandbox: sandbox }
  )
  client.connect
  client.query('Hello from the sandbox!')
  client.receive_response { |msg| puts msg }
  client.disconnect
ensure
  sandbox.kill
end.wait
```

**Why use a remote transport?** Untrusted code execution, multi-tenant agent runs that can't share a host, environments without local Node.js, or simply isolating filesystem/network blast radius. The Firecracker VM gives you a fresh `/home/user` per session and is killable without touching the host.

**Production hardening** (intentionally omitted from the example for clarity): inactivity watchdog, keepalive heartbeat, stream reconnect on transient SSL/EOF errors, host env-var blocklist, MCP server filtering for sandbox compatibility. See the example file's header comments for what to add and why.
