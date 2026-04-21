#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: OpenTelemetry observability with Langfuse backend
#
# This example shows how to trace Claude Agent SDK calls using OpenTelemetry,
# sending spans to Langfuse for LLM observability.
#
# Prerequisites:
#   gem install opentelemetry-sdk opentelemetry-exporter-otlp
#
# Environment variables:
#   LANGFUSE_PUBLIC_KEY - Your Langfuse public key
#   LANGFUSE_SECRET_KEY - Your Langfuse secret key
#   LANGFUSE_BASE_URL   - Langfuse endpoint (default: https://cloud.langfuse.com)
#
# The same observer pattern works with any OTel backend (Jaeger, Datadog, etc.)
# by configuring a different exporter.

require 'bundler'
Bundler.setup(:default, :instrumentation)

require 'base64'
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'
require 'claude_agent_sdk'
require 'claude_agent_sdk/instrumentation'
require 'async'

# --- Step 1: Configure OpenTelemetry to export to Langfuse ---

public_key = ENV.fetch('LANGFUSE_PUBLIC_KEY') { abort 'Set LANGFUSE_PUBLIC_KEY' }
secret_key = ENV.fetch('LANGFUSE_SECRET_KEY') { abort 'Set LANGFUSE_SECRET_KEY' }
base_url = ENV.fetch('LANGFUSE_BASE_URL', 'https://cloud.langfuse.com')

auth = Base64.strict_encode64("#{public_key}:#{secret_key}")

OpenTelemetry::SDK.configure do |c|
  c.service_name = 'claude-agent-ruby-example'
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "#{base_url}/api/public/otel/v1/traces",
        headers: {
          'Authorization' => "Basic #{auth}",
          'x-langfuse-ingestion-version' => '4'
        }
      )
    )
  )
end

# --- Step 2: Create observer and query ---

observer = ClaudeAgentSDK::Instrumentation::OTelObserver.new
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  observers: [observer]
)

Async do
  puts "Querying Claude with OTel tracing enabled..."
  puts

  ClaudeAgentSDK.query(prompt: "What is 2 + 2? Answer in one sentence.", options: options) do |msg|
    case msg
    when ClaudeAgentSDK::InitMessage
      puts "[init] session=#{msg.session_id} model=#{msg.model}"
    when ClaudeAgentSDK::AssistantMessage
      msg.content.each do |block|
        puts "[assistant] #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
      end
    when ClaudeAgentSDK::ResultMessage
      puts
      puts "[result] cost=$#{msg.total_cost_usd} duration=#{msg.duration_ms}ms turns=#{msg.num_turns}"
    end
  end

  puts
  puts "Done! Check your Langfuse dashboard for the trace."

  # Give the BatchSpanProcessor time to flush
  OpenTelemetry.tracer_provider.shutdown
end.wait
