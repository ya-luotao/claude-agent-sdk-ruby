# Observability (OpenTelemetry / Langfuse)

The SDK includes a built-in **observer interface** and an **OpenTelemetry observer** for tracing agent sessions. Span attributes follow the Langfuse and OpenInference conventions, plus a subset of the OTel `gen_ai.*` attributes. Any OTel backend (Jaeger, Datadog, ...) can store and display the spans; one that interprets attributes by the OTel GenAI semantic conventions reads only part of them, as [Span Attributes](#span-attributes) explains.

## Distributed Trace Context (W3C)

When `connect` spawns the CLI and there is an active OTel span, the SDK injects `TRACEPARENT`/`TRACESTATE` (and any other propagator carrier keys, e.g. `BAGGAGE` — which may carry user-defined key/values — uppercased) into the subprocess environment so CLI-side telemetry (`CLAUDE_CODE_ENABLE_TELEMETRY=1`) joins the caller's distributed trace. This requires the `opentelemetry` gem to be loaded with a configured propagator — there is no hard dependency, and it is a no-op otherwise. Explicit `ClaudeAgentOptions#env` keys always win; stale inherited `TRACEPARENT`/`TRACESTATE` is replaced (or unset) only when an active span supersedes it. This works independently of `OTelObserver`: the CLI parents under the caller's surrounding span, not under `claude_agent.session` (which starts at InitMessage, after spawn).

The SDK also carries the active OTel context (including baggage) into the reactor fibers created by `query()` and standalone `Client.open`, their background input/control tasks, and callback worker-thread hops. `OTelObserver` session spans therefore keep the surrounding caller span as their parent in both default `:thread` and opt-in `:inline` mode. For `Client`, keep the intended parent active while connecting and receiving messages: background control callbacks inherit the connection's context, while message observers use the receiving operation's context. Context is captured per operation/task, not when an observer is constructed, so sequential observer reuse does not retain an earlier caller's parent. This uses OTel's scoped context API only when loaded; it does not copy application thread-local state or change callback scheduling.

## How It Works

Register observers via `ClaudeAgentOptions`. The SDK calls `on_user_prompt` when a prompt is sent — the verbatim string for String prompts (`query()` / `Client#query`), and once per `type: 'user'` message with extractable text for Enumerator/streaming input (`query()` stream path and `Client#connect` with an initial enumerable). It calls `on_message` for every parsed message, `on_error` once per error that surfaces to your code (before `on_close` where both fire), and `on_close` when the session ends. Observer errors are silently rescued so they never crash your application.

For multi-turn streaming input note that `OTelObserver` captures one prompt per trace (the first one buffered before each init); prompts queued up-front for later turns may not appear as those traces' `input.value`.

In `Client` mode, call `disconnect` (ideally in an `ensure` block) so `on_close` runs and OTel spans are flushed and exported.

```
claude_agent.session            (root span — one per query/session)
├── claude_agent.generation     (per AssistantMessage, with model; token usage once per API response)
├── claude_agent.tool.Bash      (per tool call, open on ToolUseBlock, close on ToolResultBlock)
├── claude_agent.tool.Read
├── claude_agent.generation
└── ...
```

A session that fails before its first `InitMessage` (the CLI cannot be found or started, or the `initialize` handshake fails or times out) still leaves a span. `OTelObserver` emits a `claude_agent.session` span that records the exception and has error status, and ends it at once, so it is exported even when no `on_close` follows: a `Client#connect` that fails before the handshake never calls it. The span carries the observer's default attributes and, if a prompt had already been sent, `input.value`. It has no model, `session.id` or `claude_code.*` attributes, because the CLI never reported them. Once a trace has started, an error is recorded on its session span instead, and an error that arrives after the trace ended adds no span: the usual one is the `ResultError` raised when the CLI exits non-zero after an error result, which that trace already reports.

## Setup with Langfuse

**1. Install the OTel gems** (not bundled with the SDK — you choose your exporter):

```bash
gem install opentelemetry-sdk opentelemetry-exporter-otlp
```

Or add to your Gemfile:

```ruby
gem 'opentelemetry-sdk', '~> 1.4'
gem 'opentelemetry-exporter-otlp', '~> 0.28'
gem 'base64' # the snippet below requires it; under Bundler, Ruby 3.4+ needs it listed
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

Attribute names follow the Langfuse and OpenInference conventions, plus a subset of the OTel `gen_ai.*` attributes. The tables below list every attribute the observer sets. An attribute whose value the CLI did not report is left out, and `input.value`, `output.value` and `gen_ai.completion` are cut at 4,096 characters.

**`claude_agent.session`**

| Attribute | Value |
|-----------|-------|
| `gen_ai.system` | `anthropic` |
| `gen_ai.request.model`, `llm.model_name` | The model named by the `InitMessage` |
| `session.id` | The CLI session ID |
| `openinference.span.kind` | `AGENT` |
| `langfuse.observation.type` | `agent` |
| `input.mime_type`, `output.mime_type` | `text/plain` |
| `claude_code.version`, `claude_code.cwd`, `claude_code.permission_mode` | From the `InitMessage` |
| Your default attributes | Whatever you passed to `OTelObserver.new`. They are set on this span only |
| `input.value` | The prompt of the trace |
| `output.value` | `ResultMessage#result`, or the last assistant text when the result has none |
| `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cache_creation_input_tokens`, `gen_ai.usage.cache_read_input_tokens` | The four counts of `ResultMessage#usage` as the API reports them, so `input_tokens` leaves cache tokens out |
| `llm.token_count.prompt` | Input, cache-creation and cache-read tokens added up |
| `llm.token_count.completion` | Output tokens |
| `llm.token_count.total` | `llm.token_count.prompt` plus `llm.token_count.completion` |
| `llm.token_count.prompt_details.cache_read`, `llm.token_count.prompt_details.cache_write` | Cache-read and cache-creation tokens |
| `gen_ai.usage.cost`, `llm.cost.total` | The cost increase since the previous result (see below) |
| `claude_agent.duration_ms`, `claude_agent.duration_api_ms`, `claude_agent.num_turns`, `claude_agent.stop_reason` | From the `ResultMessage` |

The span status is error when the `ResultMessage` has `is_error` (the description is its stop reason) or when `on_error` recorded an exception, which also adds an `exception` event. Three more events are recorded on this span: `api_retry` (`attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error`), `rate_limit` (`status`, `rate_limit_type`) and `tool_progress` (`tool_name`, `tool_use_id`, `elapsed_time_seconds`).

**`claude_agent.generation`**

| Attribute | Value |
|-----------|-------|
| `openinference.span.kind` | `LLM` |
| `langfuse.observation.type` | `generation` |
| `gen_ai.response.model`, `llm.model_name` | The model named by the `AssistantMessage` |
| `gen_ai.completion`, `output.value` | The text blocks of the message joined by newlines; an empty string when it has none (a thinking or tool-call message) |
| `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cache_creation_input_tokens`, `gen_ai.usage.cache_read_input_tokens` | The usage of the API response, on the first span of each `message_id` only (see below) |

**`claude_agent.tool.<tool name>`**

| Attribute | Value |
|-----------|-------|
| `openinference.span.kind` | `TOOL` |
| `langfuse.observation.type` | `tool` |
| `tool.name` | The name of the tool |
| `input.value`, `input.mime_type` | The tool input as JSON, and `application/json` |
| `output.value`, `output.mime_type` | The tool result: a String as it is (`text/plain`), structured content as JSON (`application/json`). Both are left out when the result has no content |

The span status is error when the tool result has `is_error`.

**Token usage on generation spans.** The CLI sends one `AssistantMessage` per content block, so an API response with a thinking block and a tool call produces two `claude_agent.generation` spans, and both messages repeat the response's `message_id` and `usage`. The observer sets the four `gen_ai.usage.*` token attributes on the first generation span of each `message_id` and on none of that response's other spans, so a sum over generation spans counts every response once. A message without a `message_id` keeps its usage. That usage is the snapshot taken when the response started: the input, cache-read and cache-creation counts are final, but `gen_ai.usage.output_tokens` holds only the few tokens generated by then, and the response's final output count never reaches the message stream. For authoritative totals, output tokens included, read the session span, which takes them from `ResultMessage#usage`.

`gen_ai.usage.cost` and `llm.cost.total` record the **increase** since the last observed `ResultMessage.total_cost_usd` in the connected session, rather than repeating that cumulative total on every turn's span. The baseline survives per-turn span resets and resets on close, a changed session ID (such as `/clear`), or a decreased counter. The original `ResultMessage` is unchanged.

Missing costs omit both attributes without discarding the last known total; the next reported increment can therefore include an unreported or interrupted turn. The first observation uses the CLI's reported total. If a newer CLI restores historical spend on resume, that first span also includes it: a fresh observer cannot separate spend it never observed. These are CLI cost estimates, not billing records.

**How this compares with the OTel GenAI semantic conventions.** Nine of the attributes above are `gen_ai.*` names. Three are used as the conventions define them: `gen_ai.request.model`, `gen_ai.response.model`, and `gen_ai.usage.output_tokens` on the session span. The other six are deprecated, removed, not defined or defined differently there, and the observer keeps them for the Langfuse mappings they were added for:

- `gen_ai.system` is deprecated in favor of `gen_ai.provider.name`, and `gen_ai.completion` has been removed.
- `gen_ai.usage.cache_creation_input_tokens`, `gen_ai.usage.cache_read_input_tokens` and `gen_ai.usage.cost` are not names the conventions define. The two cache names are the Anthropic API's field names.
- `gen_ai.usage.input_tokens` is the API's `input_tokens`, which leaves cache tokens out, while the conventions say the value should include them. A backend that follows the conventions therefore sees only part of the input of a cached turn: 18 tokens for a recorded turn that consumed 49,974. The inclusive count is `llm.token_count.prompt` on the session span.

The observer sets neither `gen_ai.operation.name` nor `gen_ai.provider.name`. This comparison was made against `opentelemetry-semantic_conventions` 1.43.0; the GenAI conventions are still marked as in development.

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

See [examples/otel_langfuse_example.rb](https://github.com/rubycatco/claude-agent-sdk-ruby/blob/main/examples/otel_langfuse_example.rb) for a complete multi-tool example.
