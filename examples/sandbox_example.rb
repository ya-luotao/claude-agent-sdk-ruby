#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'

# Example: Full sandbox configuration
#
# Sandbox settings control how Claude Code commands are isolated.
# This example shows all available options including filesystem
# restrictions, network domain allowlists, and violation handling.

puts "=== Sandbox Settings Example ==="

# Basic sandbox — just enable it
basic = ClaudeAgentSDK::SandboxSettings.new(
  enabled: true,
  auto_allow_bash_if_sandboxed: true
)

puts "Basic sandbox: enabled=#{basic.enabled}"

# Full sandbox with network + filesystem restrictions
network = ClaudeAgentSDK::SandboxNetworkConfig.new(
  allowed_domains: ['api.github.com', 'rubygems.org'],
  allow_managed_domains_only: false,
  allow_local_binding: true,
  http_proxy_port: 8080
)

filesystem = ClaudeAgentSDK::SandboxFilesystemConfig.new(
  allow_write: ['/tmp/output', '/var/data'],
  deny_write: ['/etc', '/usr'],
  deny_read: ['/etc/secrets', '/home/user/.ssh'],
  allow_read: ['/etc/hosts'] # Re-allow specific paths within deny_read
)

sandbox = ClaudeAgentSDK::SandboxSettings.new(
  enabled: true,
  fail_if_unavailable: true, # Exit with error if sandbox can't start
  auto_allow_bash_if_sandboxed: true,
  allow_unsandboxed_commands: false, # Block dangerouslyDisableSandbox
  excluded_commands: ['sudo'],
  network: network,
  filesystem: filesystem,
  ignore_violations: {
    'network' => ['metrics.internal:9090'],
    'file' => ['/tmp/cache/*']
  },
  enable_weaker_nested_sandbox: false,
  enable_weaker_network_isolation: false, # macOS: trustd access for Go CLIs
  ripgrep: { command: '/usr/local/bin/rg', args: ['--hidden'] }
)

puts "\nFull sandbox config:"
puts JSON.pretty_generate(sandbox.to_h)

# Use in a query
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  sandbox: sandbox,
  permission_mode: 'acceptEdits'
)

puts "\nRunning sandboxed query..."
ClaudeAgentSDK.query(prompt: "List files in /tmp", options: options) do |msg|
  case msg
  when ClaudeAgentSDK::AssistantMessage
    msg.content.each do |block|
      puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    puts "Done (#{msg.num_turns} turns, $#{msg.total_cost_usd})"
  end
end
