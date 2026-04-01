#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'

# Example: Bare mode for fast, minimal startup
#
# Bare mode (--bare) skips hooks, LSP, plugin sync, attribution,
# auto-memory, keychain reads, and CLAUDE.md auto-discovery.
# Ideal for scripted/programmatic usage where you want fast startup
# and full control over what's loaded.

puts "=== Bare Mode Example ==="

# Minimal bare query — fastest possible startup
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  bare: true,
  permission_mode: 'bypassPermissions'
)

ClaudeAgentSDK.query(prompt: "What is 2 + 2? Reply with just the number.", options: options) do |msg|
  case msg
  when ClaudeAgentSDK::InitMessage
    puts "Session: #{msg.session_id}"
    puts "Model: #{msg.model}"
    puts "Tools: #{msg.tools&.join(', ')}"
  when ClaudeAgentSDK::AssistantMessage
    msg.content.each do |block|
      puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    puts "Done in #{msg.duration_ms}ms, cost: $#{msg.total_cost_usd}"
  end
end

puts "\n--- Bare mode with explicit context ---"

# Bare mode with explicit context — you control what's loaded
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  bare: true,
  system_prompt: 'You are a concise code reviewer. Reply in 2-3 sentences max.',
  add_dirs: [Dir.pwd], # Explicit CLAUDE.md directory
  setting_sources: ['project'], # Load .claude/settings.json
  allowed_tools: %w[Read Grep Glob],
  permission_mode: 'bypassPermissions'
)

ClaudeAgentSDK.query(prompt: "What files are in the current directory?", options: options) do |msg|
  case msg
  when ClaudeAgentSDK::AssistantMessage
    msg.content.each do |block|
      puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\nCost: $#{msg.total_cost_usd}"
  end
end
