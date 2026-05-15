# Client & Custom Transport

`ClaudeAgentSDK::Client` supports bidirectional, interactive conversations with Claude Code. Unlike `query()`, `Client` enables **custom tools**, **hooks**, and **permission callbacks**, all of which can be defined as Ruby procs/lambdas. The Client class automatically uses streaming mode for bidirectional communication, allowing you to send multiple queries dynamically during a single session without closing the connection.

## Basic Usage

```ruby
require 'claude_agent_sdk'
require 'async'

Async do
  client = ClaudeAgentSDK::Client.new

  begin
    client.connect
    client.query("What is the capital of France?")

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

## Advanced Features

```ruby
Async do
  client = ClaudeAgentSDK::Client.new
  client.connect

  client.interrupt                              # Send interrupt signal
  client.set_permission_mode('acceptEdits')     # Change permission mode mid-conversation
  client.set_model('claude-sonnet-4-5')         # Switch model mid-conversation
  status = client.get_mcp_status                # Inspect MCP server status
  info   = client.get_server_info               # Inspect server init info
  client.reconnect_mcp_server('my-server')      # Reconnect a failed MCP server
  client.toggle_mcp_server('my-server', false)  # Enable/disable an MCP server
  client.stop_task('task_abc123')               # Stop a running background task

  client.disconnect
end.wait
```

## Custom Transport

By default, `Client` uses `SubprocessCLITransport` to spawn the Claude Code CLI locally. You can provide a custom transport class to connect via other channels (e.g., remote SSH, WebSocket, or a sandbox VM).

A transport must implement six methods:

| Method | Purpose |
|---|---|
| `connect` | Establish the connection / spawn the remote CLI |
| `write(data)` | Send raw JSON-line bytes to stdin |
| `read_messages { \|hash\| ... }` | Yield parsed JSON messages from stdout; block until the stream closes |
| `end_input` | Signal EOF on stdin |
| `close` | Terminate and clean up |
| `ready?` | Report whether the transport can accept I/O |

Then plug it into `Client` via `transport_class:` / `transport_args:`. All connect orchestration (option transforms, MCP extraction, hook conversion, Query lifecycle) is handled for you.

```ruby
client = ClaudeAgentSDK::Client.new(
  options: options,
  transport_class: MyTransport,
  transport_args: { foo: 'bar' } # forwarded to MyTransport.new(options, **transport_args)
)
```

### Reference: running `claude` inside an E2B sandbox

[`examples/e2b_transport_example.rb`](../examples/e2b_transport_example.rb) is a working transport that runs the Claude Code CLI inside an [E2B](https://e2b.dev) Firecracker microVM instead of on your host. The wire protocol stays identical — only the I/O layer changes:

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
