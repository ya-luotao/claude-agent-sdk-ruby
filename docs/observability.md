# Observability (OpenTelemetry / Langfuse)

The SDK includes a built-in **observer interface** and an **OpenTelemetry observer** for tracing agent sessions. Traces are emitted using standard `gen_ai.*` semantic conventions, compatible with Langfuse, Jaeger, Datadog, and any OTel backend.

## How It Works

Register observers via `ClaudeAgentOptions`. The SDK calls `on_user_prompt` when a prompt is sent (`query()` with a String prompt, and `Client#query`), `on_message` for every parsed message, `on_error` once per error that surfaces to your code (before `on_close` where both fire), and `on_close` when the session ends. Observer errors are silently rescued so they never crash your application.

In `Client` mode, call `disconnect` (ideally in an `ensure` block) so `on_close` runs and OTel spans are flushed and exported.

```
claude_agent.session            (root span — one per query/session)
├── claude_agent.generation     (per AssistantMessage, with model + token usage)
├── claude_agent.tool.Bash      (per tool call, open on ToolUseBlock, close on ToolResultBlock)
├── claude_agent.tool.Read
├── claude_agent.generation
└── ...
```

## Setup with Langfuse

**1. Install the OTel gems** (not bundled with the SDK — you choose your exporter):

```bash
gem install opentelemetry-sdk opentelemetry-exporter-otlp
```

Or add to your Gemfile:

```ruby
gem 'opentelemetry-sdk', '~> 1.4'
gem 'opentelemetry-exporter-otlp', '~> 0.28'
```

**2. Configure the OTel SDK** to export to your Langfuse instance:

```ruby
require 'base64'
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'

# Langfuse authenticates via Basic Auth over OTLP
public_key = ENV['LANGFUSE_PUBLIC_KEY']
secret_key = ENV['LANGFUSE_SECRET_KEY']
auth = Base64.strict_encode64("#{public_key}:#{secret_key}")

# Self-hosted or cloud: https://cloud.langfuse.com (EU) / https://us.cloud.langfuse.com (US)
langfuse_host = ENV.fetch('LANGFUSE_HOST', 'https://cloud.langfuse.com')

OpenTelemetry::SDK.configure do |c|
  c.service_name = 'my-agent-app'
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
```

**3. Create the observer and run a query:**

```ruby
require 'claude_agent_sdk'
require 'claude_agent_sdk/instrumentation'

observer = ClaudeAgentSDK::Instrumentation::OTelObserver.new(
  'langfuse.session.id' => 'my-session-123',  # optional: group traces by session
  'user.id' => 'user-42'                      # optional: tag with user ID
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  observers: [observer],
  allowed_tools: ['Bash', 'Read'],
  permission_mode: 'bypassPermissions'
)

ClaudeAgentSDK.query(prompt: "List files in /tmp", options: options) do |msg|
  puts msg.text if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
end

# For long-running apps, flush before exit:
# OpenTelemetry.tracer_provider.shutdown
```

### Reuse and concurrency

A single `OTelObserver` instance is safe to reuse for **sequential** queries — per-trace state (buffered prompt/output, open spans) is reset at each trace boundary. It holds unsynchronized span state, however, so for **concurrent** sessions (Puma, Sidekiq, threads) pass a callable factory so each query/session gets a fresh instance:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  observers: [-> { ClaudeAgentSDK::Instrumentation::OTelObserver.new }]
)
```

See [docs/rails.md](rails.md) for the Rails-specific pattern.

## Span Attributes

The OTel observer sets attributes using both `gen_ai.*` (OTel GenAI) and OpenInference conventions for maximum backend compatibility:

| Span | Type | Key Attributes |
|------|------|----------------|
| `claude_agent.session` | `agent` | `gen_ai.system`, `gen_ai.request.model`, `session.id`, `input.value`, `output.value`, `gen_ai.usage.cost`, `llm.cost.total` |
| `claude_agent.generation` | `generation` | `gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `output.value` |
| `claude_agent.tool.*` | `tool` | `tool.name`, `input.value`, `output.value` |

Events (`api_retry`, `rate_limit`, `tool_progress`) are recorded on the root span.

The `langfuse.observation.type` attribute is set on each span (`agent`/`generation`/`tool`) to enable Langfuse's **trace flow diagram** (DAG graph visualization).

## Custom Observers

Implement the `Observer` module to build your own instrumentation. Overridable callbacks: `on_user_prompt(prompt)`, `on_message(message)`, `on_error(error)`, `on_close`.

```ruby
class MyObserver
  include ClaudeAgentSDK::Observer

  def on_message(message)
    case message
    when ClaudeAgentSDK::ResultMessage
      puts "Cost: $#{message.total_cost_usd}, Tokens: #{message.usage}"
    end
  end

  def on_error(error)
    puts "Session error: #{error.message}"
  end

  def on_close
    puts "Session ended"
  end
end

options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [MyObserver.new])
```

See [examples/otel_langfuse_example.rb](../examples/otel_langfuse_example.rb) for a complete multi-tool example.
