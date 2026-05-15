# Rails Integration

The SDK integrates well with Rails applications. Below are the common patterns.

## Thread-keyed libraries are safe inside SDK callbacks

The SDK depends on [`async`](https://github.com/socketry/async), which installs a Fiber scheduler that multiplexes fibers onto a single OS thread and intercepts IO so blocking calls yield to siblings. Most mature Ruby libraries are thread-safe but not fiber-safe — they key state (checked-out DB connections, per-thread caches, request stores) on `Thread.current`. When the scheduler interleaves two fibers on one thread, those fibers share the same state slot, and interleaved IO on a shared connection silently corrupts wire protocols. This affects every DB driver keyed by thread (`pg`, `mysql2`, `sqlite3`), ActiveRecord's connection pool, and HTTP/cache clients pooled per thread.

You do **not** need to think about this. The SDK hops to a plain thread at every user-callback boundary — message blocks given to `query` / `Client`, SDK MCP tool handlers, hooks, permission callbacks, and observer methods — so your code runs with no Fiber scheduler active and inherits the ordinary thread-keyed assumptions every Rails / Sidekiq / Kamal app already makes:

```ruby
tool = ClaudeAgentSDK.create_tool('lookup_user', 'Look up a user', { id: Integer }) do |args|
  user = User.find(args[:id])                # just works
  { content: [{ type: 'text', text: user.name }] }
end

ClaudeAgentSDK.query(prompt: '...') do |message|
  Message.create!(role: 'assistant', body: message.to_s)   # just works
end
```

The trade-off: because callbacks run on a plain thread rather than inside an `Async::Task`, fiber-specific primitives aren't available to them — `Async::Task.current` will raise "No async task available". If a callback wants cooperative concurrency it should open its own `Async { }` block. In practice, callbacks typically do some Ruby work, call external services, and return — so this rarely matters. If you wrap your own call site in an outer `Async { }` block, the scheduler is visible to your code again; you've opted in, and whatever fiber-safety rules your app uses apply there.

## ActionCable Streaming

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

## Session Resumption

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
        update!(claude_session_id: message.session_id) if message.is_a?(ClaudeAgentSDK::ResultMessage)
      end
    ensure
      client.disconnect
    end.wait
  end

  private

  def build_options
    opts = { permission_mode: 'bypassPermissions', setting_sources: [] }
    opts[:resume] = claude_session_id if claude_session_id.present?
    ClaudeAgentSDK::ClaudeAgentOptions.new(**opts)
  end

  def generate_session_id
    "chat_#{id}_#{Time.current.to_i}"
  end
end
```

## Background Jobs with Error Handling

```ruby
class ClaudeAgentJob < ApplicationJob
  queue_as :claude_agents
  retry_on ClaudeAgentSDK::ProcessError, wait: :polynomially_longer, attempts: 3

  def perform(task_id)
    task = Task.find(task_id)
    Async { execute_agent(task) }.wait
  rescue ClaudeAgentSDK::CLINotFoundError
    task.update!(status: 'failed', error: 'Claude CLI not installed')
    raise
  end

  private

  def execute_agent(task)
    # ... agent execution
  end
end
```

## HTTP MCP Servers

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

## Observability in Rails

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

See:
- [examples/rails_actioncable_example.rb](../examples/rails_actioncable_example.rb)
- [examples/rails_background_job_example.rb](../examples/rails_background_job_example.rb)
- [examples/session_resumption_example.rb](../examples/session_resumption_example.rb)
- [examples/http_mcp_server_example.rb](../examples/http_mcp_server_example.rb)
