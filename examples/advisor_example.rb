#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Pairing the main model with a stronger advisor model.
#
# The advisor tool lets Claude consult a second, typically stronger model at
# key decision points — before committing to an approach, when stuck on a
# recurring error, or before declaring a task complete. The advisor receives
# the full conversation and returns guidance that Claude applies before
# continuing.
#
# Notes:
# - Experimental; requires the Anthropic API (not available on Bedrock,
#   Google Cloud's Agent Platform, or Microsoft Foundry).
# - The CLI validates the model pairing: the advisor must be at least as
#   capable as the main model (e.g. a Haiku main accepts an Opus advisor,
#   but an Opus main rejects a Haiku advisor).
# - Advisor calls are billed at the advisor model's rates on top of the
#   main model's usage.
#
# Docs: https://code.claude.com/docs/en/advisor

puts "=== Advisor Example ==="

# Example 1: Haiku main model escalating decisions to an Opus advisor
puts "\n--- Example 1: Haiku main + Opus advisor ---"

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  model: 'haiku',
  advisor_model: 'opus', # alias or full model ID, e.g. 'claude-opus-4-8'
  allowed_tools: ['Read', 'Glob'],
  max_turns: 5
)

ClaudeAgentSDK.query(
  prompt: 'Consult the advisor about the best one-sentence description of this project, then answer.',
  options: options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    message.content.each do |block|
      case block
      when ClaudeAgentSDK::TextBlock
        puts block.text
      when ClaudeAgentSDK::ServerToolUseBlock
        # The advisor runs server-side; its invocation appears as a
        # server_tool_use block named 'advisor'.
        puts "[advisor consulted: #{block.name}]" if block.name == 'advisor'
      when ClaudeAgentSDK::ServerToolResultBlock
        # The advisor's guidance comes back as an advisor_tool_result block.
        puts "[advisor result received]"
      end
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\nCost: $#{message.total_cost_usd}" if message.total_cost_usd
  end
end

puts "\n#{'=' * 50}"

# Example 2: Client session with an advisor configured
puts "\n--- Example 2: Client session with advisor ---"

Async do
  client = ClaudeAgentSDK::Client.new(
    options: ClaudeAgentSDK::ClaudeAgentOptions.new(
      model: 'sonnet',
      advisor_model: 'opus'
    )
  )

  begin
    client.connect
    client.query('Before answering, consult the advisor: what is the riskiest part of parsing untrusted JSON?')

    client.receive_response do |msg|
      case msg
      when ClaudeAgentSDK::AssistantMessage
        msg.content.each do |block|
          puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      when ClaudeAgentSDK::ResultMessage
        puts "\nCost: $#{msg.total_cost_usd}" if msg.total_cost_usd
      end
    end
  ensure
    client.disconnect
  end
end.wait

puts "\nDone!"
