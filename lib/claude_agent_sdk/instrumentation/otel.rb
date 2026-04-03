# frozen_string_literal: true

require 'json'
require_relative '../observer'

module ClaudeAgentSDK
  module Instrumentation
    # OpenTelemetry observer that emits spans for Claude Agent SDK messages.
    #
    # Uses standard gen_ai.* semantic conventions recognized by Langfuse, Datadog,
    # Jaeger, and other OTel-compatible backends.
    #
    # Requires the `opentelemetry-api` gem at runtime. Users must configure
    # `opentelemetry-sdk` and an exporter (e.g., `opentelemetry-exporter-otlp`)
    # themselves before creating this observer.
    #
    # @example With Langfuse via OTLP
    #   require 'opentelemetry/sdk'
    #   require 'opentelemetry/exporter/otlp'
    #   require 'claude_agent_sdk/instrumentation'
    #
    #   OpenTelemetry::SDK.configure do |c|
    #     c.service_name = 'my-app'
    #     c.add_span_processor(
    #       OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
    #         OpenTelemetry::Exporter::OTLP::Exporter.new(
    #           endpoint: 'https://cloud.langfuse.com/api/public/otel/v1/traces',
    #           headers: { 'Authorization' => "Basic #{auth}" }
    #         )
    #       )
    #     )
    #   end
    #
    #   observer = ClaudeAgentSDK::Instrumentation::OTelObserver.new
    #   options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer])
    #   ClaudeAgentSDK.query(prompt: "Hello", options: options) { |msg| ... }
    class OTelObserver
      include ClaudeAgentSDK::Observer

      TRACER_NAME = 'claude_agent_sdk'
      MAX_ATTRIBUTE_LENGTH = 4096

      def initialize(tracer_name: TRACER_NAME, **default_attributes)
        require 'opentelemetry'
        @tracer = OpenTelemetry.tracer_provider.tracer(
          tracer_name,
          defined?(ClaudeAgentSDK::VERSION) ? ClaudeAgentSDK::VERSION : '0.0.0'
        )
        @default_attributes = default_attributes
        @root_span = nil
        @root_context = nil
        @tool_spans = {} # tool_use_id => span
        @first_user_input = nil # capture first user prompt for trace input
        @last_assistant_text = nil # capture last assistant text for trace output
      end

      def on_message(message)
        case message
        when ClaudeAgentSDK::InitMessage
          start_trace(message)
        when ClaudeAgentSDK::AssistantMessage
          handle_assistant(message)
        when ClaudeAgentSDK::UserMessage
          handle_user(message)
        when ClaudeAgentSDK::ResultMessage
          end_trace(message)
        when ClaudeAgentSDK::APIRetryMessage
          record_retry_event(message)
        when ClaudeAgentSDK::RateLimitEvent
          record_rate_limit_event(message)
        when ClaudeAgentSDK::ToolProgressMessage
          record_tool_progress_event(message)
        end
      end

      def on_error(error)
        return unless @root_span

        @root_span.record_exception(error)
        @root_span.status = OpenTelemetry::Trace::Status.error(error.message)
      end

      def on_close
        @tool_spans.each_value(&:finish)
        @tool_spans.clear
        @root_span&.finish
        @root_span = nil
        @root_context = nil
      end

      private

      def start_trace(message)
        attrs = {
          # gen_ai semantic conventions (recognized by Langfuse, Datadog, etc.)
          'gen_ai.system' => 'anthropic',
          'gen_ai.request.model' => message.model,
          # OpenInference conventions (recognized by Langfuse, Arize)
          'openinference.span.kind' => 'AGENT',
          'llm.model_name' => message.model,
          'input.mime_type' => 'text/plain',
          'output.mime_type' => 'text/plain',
          # Session tracking
          'session.id' => message.session_id
        }.merge(@default_attributes)

        attrs['claude_code.version'] = message.claude_code_version if message.respond_to?(:claude_code_version) && message.claude_code_version
        attrs['claude_code.cwd'] = message.cwd if message.respond_to?(:cwd) && message.cwd
        attrs['claude_code.permission_mode'] = message.permission_mode if message.respond_to?(:permission_mode) && message.permission_mode

        @root_span = @tracer.start_span('claude_agent.session', attributes: compact_attrs(attrs))
        @root_context = OpenTelemetry::Trace.context_with_span(@root_span)
      end

      def handle_assistant(message)
        return unless @root_context

        # Extract text content for gen_ai.completion
        text_parts = []
        tool_use_blocks = []

        (message.content || []).each do |block|
          case block
          when ClaudeAgentSDK::TextBlock
            text_parts << block.text
          when ClaudeAgentSDK::ToolUseBlock
            tool_use_blocks << block
          end
        end

        # Track last assistant text for trace output
        combined_text = text_parts.join("\n")
        @last_assistant_text = combined_text unless combined_text.empty?

        # Create generation span
        usage = message.usage || {}
        input_tokens = usage[:input_tokens] || usage['input_tokens']
        output_tokens = usage[:output_tokens] || usage['output_tokens']
        attrs = {
          'gen_ai.response.model' => message.model,
          'gen_ai.usage.input_tokens' => input_tokens,
          'gen_ai.usage.output_tokens' => output_tokens,
          'gen_ai.completion' => truncate(combined_text)
        }

        OpenTelemetry::Context.with_current(@root_context) do
          span = @tracer.start_span('claude_agent.generation', attributes: compact_attrs(attrs))
          span.finish
        end

        # Start tool spans for any ToolUseBlocks
        tool_use_blocks.each { |block| start_tool_span(block) }
      end

      def handle_user(message)
        return unless @root_context

        content = message.content

        # Capture first user input for trace-level input (shown in Langfuse UI)
        if @first_user_input.nil?
          @first_user_input = if content.is_a?(String)
                                content
                              elsif content.is_a?(Array)
                                content.filter_map { |b| b.text if b.is_a?(ClaudeAgentSDK::TextBlock) }.join("\n")
                              end
          @root_span.set_attribute('input.value', truncate(@first_user_input)) if @first_user_input && !@first_user_input.empty?
        end

        return unless content.is_a?(Array)

        content.each do |block|
          case block
          when ClaudeAgentSDK::ToolResultBlock
            end_tool_span(block)
          end
        end
      end

      def end_trace(message)
        return unless @root_span

        usage = message.usage || {}
        input_tokens = usage[:input_tokens] || usage['input_tokens']
        output_tokens = usage[:output_tokens] || usage['output_tokens']
        total_tokens = (input_tokens || 0) + (output_tokens || 0) if input_tokens || output_tokens

        # Set trace output (last assistant response — shown in Langfuse UI)
        # ResultMessage.result has the final text; fall back to last tracked assistant text
        trace_output = message.result || @last_assistant_text

        attrs = {
          # gen_ai conventions
          'gen_ai.usage.cost' => message.total_cost_usd,
          'gen_ai.usage.input_tokens' => input_tokens,
          'gen_ai.usage.output_tokens' => output_tokens,
          # OpenInference conventions (Langfuse maps these to usage/cost)
          'llm.token_count.prompt' => input_tokens,
          'llm.token_count.completion' => output_tokens,
          'llm.token_count.total' => total_tokens,
          'llm.cost.total' => message.total_cost_usd,
          # Trace output (Langfuse shows this in the trace detail view)
          'output.value' => truncate(trace_output),
          # Session metadata
          'claude_agent.duration_ms' => message.duration_ms,
          'claude_agent.duration_api_ms' => message.duration_api_ms,
          'claude_agent.num_turns' => message.num_turns,
          'claude_agent.stop_reason' => message.stop_reason
        }

        @root_span.status = OpenTelemetry::Trace::Status.error(message.stop_reason || 'error') if message.is_error

        @root_span.add_attributes(compact_attrs(attrs))
        @root_span.finish
        @root_span = nil
        @root_context = nil
      end

      def start_tool_span(block)
        return unless @root_context

        attrs = {
          'tool.name' => block.name,
          'tool.input' => truncate(safe_json(block.input))
        }

        OpenTelemetry::Context.with_current(@root_context) do
          span = @tracer.start_span("claude_agent.tool.#{block.name}", attributes: compact_attrs(attrs))
          @tool_spans[block.id] = span
        end
      end

      def end_tool_span(block)
        span = @tool_spans.delete(block.tool_use_id)
        return unless span

        span.set_attribute('tool.output', truncate(block.content.to_s))
        span.status = OpenTelemetry::Trace::Status.error('tool error') if block.is_error
        span.finish
      end

      def record_retry_event(message)
        return unless @root_span

        @root_span.add_event('api_retry', attributes: compact_attrs(
          'attempt' => message.attempt,
          'max_retries' => message.max_retries,
          'retry_delay_ms' => message.retry_delay_ms,
          'error_status' => message.error_status,
          'error' => message.error
        ))
      end

      def record_rate_limit_event(message)
        return unless @root_span

        info = message.rate_limit_info
        attrs = {}
        if info
          attrs['status'] = info.status if info.respond_to?(:status)
          attrs['rate_limit_type'] = info.rate_limit_type if info.respond_to?(:rate_limit_type)
        end
        @root_span.add_event('rate_limit', attributes: compact_attrs(attrs))
      end

      def record_tool_progress_event(message)
        return unless @root_span

        @root_span.add_event('tool_progress', attributes: compact_attrs(
          'tool_name' => message.tool_name,
          'tool_use_id' => message.tool_use_id,
          'elapsed_time_seconds' => message.elapsed_time_seconds
        ))
      end

      # Remove nil values from attributes hash (OTel rejects nil attribute values)
      def compact_attrs(attrs)
        attrs.compact
      end

      def truncate(str)
        return nil unless str

        str.length > MAX_ATTRIBUTE_LENGTH ? str[0...MAX_ATTRIBUTE_LENGTH] : str
      end

      def safe_json(obj)
        JSON.generate(obj)
      rescue StandardError
        obj.to_s
      end
    end
  end
end
