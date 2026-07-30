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

## Fiber workers (solid_queue) and `callback_scheduling: :inline`

[solid_queue 728](https://github.com/rails/solid_queue/pull/728) added a fiber-based worker mode: workers configured with `fibers: N` run claimed jobs as fibers on one async reactor thread — built for exactly the long-lived, I/O-bound "LLM streaming" jobs this SDK produces. It requires the app to be fiber-isolated end to end:

```ruby
# config/application.rb
ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
```

On Rails 7.2+, ActiveRecord releases connections between queries under fiber isolation, so fiber counts can far exceed the pool size (e.g. 50 fibers on 25 connections).

In such a host the default thread hop works *against* you: every callback is ejected from the reactor onto a fresh bare thread, where `Fiber.scheduler` is `nil` (reactor APIs like `Async::Task#stop` / `Async::Notification` are unusable), and an implicitly checked-out AR connection dies with the throwaway thread (stranded until the reaper reclaims it). For these hosts the SDK offers opt-in inline scheduling:

```ruby
# config/initializers/claude_agent_sdk.rb — process-wide, matching
# isolation_level's process-wide nature. Only set this in processes that run
# fiber workers; or pass it per-session via ClaudeAgentOptions instead.
ClaudeAgentSDK.configure do |config|
  config.default_options = { callback_scheduling: :inline }
end
```

With `:inline`, every user callback — message blocks, hooks, permission callbacks, SDK MCP handlers, observers — runs in place on the reactor fiber of the job. This is the same execution model as the Python SDK (async callbacks run natively on the event loop). Concretely:

- `Fiber.scheduler` is live inside callbacks; reactor primitives work directly. DB access goes through the Rails 7.2+ fiber-aware pool under the same assumptions as the rest of your fiber-worker jobs.
- No per-call threads exist, so nothing can strand an AR connection.
- The whole SDK session can live directly on the job fiber — no bridge threads. `Client#connect` already requires an Async context, and the transport's pipe I/O is scheduler-aware.
- Hook timeouts become **cooperative**: a timed-out inline hook is cancelled at its next suspension point (its `ensure` blocks run), instead of being abandoned on a worker thread. A CPU-stuck hook cannot be timed out.
- The CLI's cancellation of an in-flight callback (e.g. permission prompt superseded) can now actually interrupt it at a suspension point.

The one real risk: **scheduler-opaque blocking stalls the whole reactor.** CPU-bound work or a GVL-holding C extension inside an inline callback blocks every job on that worker, not just yours. Move such pieces onto a thread explicitly:

```ruby
tool = ClaudeAgentSDK.create_tool('render', 'Render a chart', { data: String }) do |args|
  png = ClaudeAgentSDK.offload { expensive_render(args[:data]) }  # plain thread
  { content: [{ type: 'text', text: Base64.encode64(png) }] }
end
```

`ClaudeAgentSDK.offload` is a no-op outside a reactor, so it's safe to call unconditionally.

Preconditions, spelled out: `:inline` is only correct when the process satisfies the same requirements as solid_queue's fiber workers — `isolation_level = :fiber`, Rails 7.2+ for AR, and no thread-keyed libraries used inside callbacks without a fiber-aware wrapper. The SDK warns once if it detects `:inline` under `isolation_level == :thread`. Everything else (Puma request threads, threaded Sidekiq/solid_queue workers) should stay on the default `callback_scheduling: :thread`.

Note that `SessionStore` adapter calls (`#append` / `#load`) intentionally stay on threads even in `:inline` mode — their timeouts are hard bounds (`Thread#join`) so a wedged store adapter can never stall the reactor.

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
- [examples/rails_actioncable_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/rails_actioncable_example.rb)
- [examples/rails_background_job_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/rails_background_job_example.rb)
- [examples/session_resumption_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/session_resumption_example.rb)
- [examples/http_mcp_server_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/http_mcp_server_example.rb)
