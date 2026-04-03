#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: multi-turn session with tool use, traced to self-hosted Langfuse via OTel.
#
# This exercises the full observer span lifecycle:
#   - claude_agent.session (root)
#   - claude_agent.generation (per assistant turn)
#   - claude_agent.tool.Bash / claude_agent.tool.Read (open/close per tool call)
#   - Events: tool_progress, api_retry (if they occur)
#
# Usage:
#   LANGFUSE_PUBLIC_KEY=pk-lf-... LANGFUSE_SECRET_KEY=sk-lf-... ruby examples/test_langfuse_otel.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'base64'
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'
require 'claude_agent_sdk'
require 'claude_agent_sdk/instrumentation'
require 'async'

# --- Config ---
LANGFUSE_HOST = ENV.fetch('LANGFUSE_HOST', 'https://langfuse.dev.navchain.com')
public_key    = ENV.fetch('LANGFUSE_PUBLIC_KEY') { abort "Set LANGFUSE_PUBLIC_KEY (from #{LANGFUSE_HOST}/settings)" }
secret_key    = ENV.fetch('LANGFUSE_SECRET_KEY') { abort "Set LANGFUSE_SECRET_KEY (from #{LANGFUSE_HOST}/settings)" }

auth = Base64.strict_encode64("#{public_key}:#{secret_key}")
endpoint = "#{LANGFUSE_HOST}/api/public/otel/v1/traces"

puts "Langfuse: #{endpoint}"
puts '-' * 60

# --- OTel setup ---
OpenTelemetry::SDK.configure do |c|
  c.service_name = 'claude-agent-sdk-ruby-test'
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: endpoint,
        headers: {
          'Authorization' => "Basic #{auth}",
          'x-langfuse-ingestion-version' => '4'
        }
      )
    )
  )
end

session_id = "otel-test-#{Time.now.to_i}"

observer = ClaudeAgentSDK::Instrumentation::OTelObserver.new(
  'langfuse.session.id' => session_id,
  'user.id' => 'sdk-test-user'
)

# Allow Bash + Read + Write tools so Claude can actually use them.
# bypassPermissions avoids interactive prompts during the test.
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  observers: [observer],
  allowed_tools: %w[Bash Read Write Glob Grep],
  permission_mode: 'bypassPermissions',
  max_turns: 8
)

# Helper to print messages
def print_message(msg)
  case msg
  when ClaudeAgentSDK::InitMessage
    puts "[init] session=#{msg.session_id} model=#{msg.model}"
  when ClaudeAgentSDK::AssistantMessage
    msg.content.each do |block|
      case block
      when ClaudeAgentSDK::TextBlock
        puts "[assistant] #{block.text}"
      when ClaudeAgentSDK::ToolUseBlock
        puts "[tool_use] #{block.name}(#{block.input.to_s[0..80]}...)"
      end
    end
  when ClaudeAgentSDK::UserMessage
    if msg.content.is_a?(Array)
      msg.content.each do |block|
        if block.is_a?(ClaudeAgentSDK::ToolResultBlock)
          status = block.is_error ? 'ERROR' : 'ok'
          puts "[tool_result] #{block.tool_use_id} [#{status}] #{block.content.to_s[0..80]}"
        end
      end
    end
  when ClaudeAgentSDK::ToolProgressMessage
    puts "[progress] #{msg.tool_name} #{msg.elapsed_time_seconds}s"
  when ClaudeAgentSDK::ResultMessage
    puts
    puts "[result] cost=$#{msg.total_cost_usd} duration=#{msg.duration_ms}ms " \
         "turns=#{msg.num_turns} stop=#{msg.stop_reason}"
    if msg.usage
      puts "[usage]  in=#{msg.usage[:input_tokens]} out=#{msg.usage[:output_tokens]}"
    end
  end
end

# --- Multi-step prompt that forces tool use ---
prompt = <<~PROMPT
  Do the following steps, using tools for each:
  1. Run `uname -s` with Bash and tell me the OS.
  2. Run `ls /tmp | head -5` with Bash and list what you see.
  3. Run `ruby -e "puts 6 * 7"` with Bash and report the result.
  4. Summarize all three results in a short paragraph.
PROMPT

Async do
  puts
  puts "Prompt: #{prompt.strip}"
  puts '-' * 60

  ClaudeAgentSDK.query(prompt: prompt, options: options) do |msg|
    print_message(msg)
  end

  puts
  puts '-' * 60
  puts 'Flushing OTel spans...'
  OpenTelemetry.tracer_provider.shutdown
  puts "Done! Check #{LANGFUSE_HOST} for session: #{session_id}"
end.wait
