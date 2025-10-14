#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Interactive client usage
Async do
  client = ClaudeAgentSDK::Client.new

  begin
    puts "Connecting to Claude..."
    client.connect
    puts "Connected!\n"

    # First query
    puts "=== Query 1: What is Ruby? ==="
    client.query("What is Ruby programming language in one sentence?")

    client.receive_response do |msg|
      if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
        msg.content.each do |block|
          puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      elsif msg.is_a?(ClaudeAgentSDK::ResultMessage)
        puts "\nCost: $#{msg.total_cost_usd}\n" if msg.total_cost_usd
      end
    end

    # Second query
    puts "\n=== Query 2: What is Python? ==="
    client.query("What is Python programming language in one sentence?")

    client.receive_response do |msg|
      if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
        msg.content.each do |block|
          puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
        end
      elsif msg.is_a?(ClaudeAgentSDK::ResultMessage)
        puts "\nCost: $#{msg.total_cost_usd}\n" if msg.total_cost_usd
      end
    end

  ensure
    puts "\nDisconnecting..."
    client.disconnect
    puts "Disconnected!"
  end
end.wait
