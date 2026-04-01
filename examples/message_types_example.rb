#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'

# Example: Handling all 24 SDK message types
#
# The Ruby SDK provides typed classes for every message the CLI emits.
# This example shows a comprehensive message handler.

puts "=== Message Types Example ==="

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  permission_mode: 'bypassPermissions',
  allowed_tools: %w[Read Bash Grep Glob]
)

ClaudeAgentSDK.query(prompt: "List the files in the current directory", options: options) do |msg|
  case msg

  # --- Session lifecycle ---
  when ClaudeAgentSDK::InitMessage
    puts "[init] Session #{msg.session_id} started"
    puts "  Model: #{msg.model}, Version: #{msg.claude_code_version}"
    puts "  Tools: #{msg.tools&.length} available"
    puts "  Fast mode: #{msg.fast_mode_state}" if msg.fast_mode_state

  when ClaudeAgentSDK::SessionStateChangedMessage
    puts "[state] Session state: #{msg.state}" # idle, running, requires_action

  # --- Core conversation ---
  when ClaudeAgentSDK::AssistantMessage
    msg.content.each do |block|
      case block
      when ClaudeAgentSDK::TextBlock
        puts "[assistant] #{block.text}"
      when ClaudeAgentSDK::ThinkingBlock
        puts "[thinking] (#{block.thinking.length} chars)"
      when ClaudeAgentSDK::ToolUseBlock
        puts "[tool_use] #{block.name}(#{block.input})"
      end
    end
    puts "[assistant] error: #{msg.error}" if msg.error

  when ClaudeAgentSDK::UserMessage
    content = msg.content.is_a?(String) ? msg.content : '(blocks)'
    puts "[user] #{content}"

  # --- Compaction ---
  when ClaudeAgentSDK::CompactBoundaryMessage
    meta = msg.compact_metadata
    puts "[compact] #{meta&.trigger}: #{meta&.pre_tokens} tokens compacted"
    puts "  Preserved: #{meta.preserved_segment[:head_uuid]}..#{meta.preserved_segment[:tail_uuid]}" if meta&.preserved_segment

  # --- Status updates ---
  when ClaudeAgentSDK::StatusMessage
    puts "[status] #{msg.status || 'clear'}"
    puts "  Permission mode: #{msg.permission_mode}" if msg.permission_mode

  when ClaudeAgentSDK::APIRetryMessage
    puts "[retry] Attempt #{msg.attempt}/#{msg.max_retries} (#{msg.error}, delay: #{msg.retry_delay_ms}ms)"

  # --- Task lifecycle (subagents / background tasks) ---
  when ClaudeAgentSDK::TaskStartedMessage
    puts "[task:start] #{msg.task_id}: #{msg.description}"
    puts "  Workflow: #{msg.workflow_name}" if msg.workflow_name

  when ClaudeAgentSDK::TaskProgressMessage
    puts "[task:progress] #{msg.task_id}: #{msg.summary || msg.description}"

  when ClaudeAgentSDK::TaskNotificationMessage
    puts "[task:done] #{msg.task_id} #{msg.status}: #{msg.summary}"

  # --- Tool progress ---
  when ClaudeAgentSDK::ToolProgressMessage
    puts "[tool:progress] #{msg.tool_name} running (#{msg.elapsed_time_seconds}s)"

  when ClaudeAgentSDK::ToolUseSummaryMessage
    puts "[tool:summary] #{msg.summary}"

  # --- Hook lifecycle ---
  when ClaudeAgentSDK::HookStartedMessage
    puts "[hook:start] #{msg.hook_name} (#{msg.hook_event})"

  when ClaudeAgentSDK::HookProgressMessage
    puts "[hook:progress] #{msg.hook_name}: #{msg.output}"

  when ClaudeAgentSDK::HookResponseMessage
    puts "[hook:done] #{msg.hook_name}: #{msg.outcome} (exit: #{msg.exit_code})"

  # --- Auth ---
  when ClaudeAgentSDK::AuthStatusMessage
    puts "[auth] #{msg.is_authenticating ? 'Authenticating...' : 'Auth complete'}"
    puts "  Error: #{msg.error}" if msg.error

  # --- Files ---
  when ClaudeAgentSDK::FilesPersistedMessage
    puts "[files] #{msg.files&.length || 0} persisted, #{msg.failed&.length || 0} failed"

  # --- Elicitation ---
  when ClaudeAgentSDK::ElicitationCompleteMessage
    puts "[elicitation] #{msg.mcp_server_name}: #{msg.elicitation_id}"

  # --- Local command output ---
  when ClaudeAgentSDK::LocalCommandOutputMessage
    puts "[local] #{msg.content}"

  # --- Prompt suggestions ---
  when ClaudeAgentSDK::PromptSuggestionMessage
    puts "[suggestion] Next: #{msg.suggestion}"

  # --- Rate limits ---
  when ClaudeAgentSDK::RateLimitEvent
    info = msg.rate_limit_info
    puts "[rate_limit] #{info.status} (#{info.rate_limit_type})"

  # --- Streaming events ---
  when ClaudeAgentSDK::StreamEvent
    # Only present when include_partial_messages: true
    puts "[stream] event received"

  # --- Final result ---
  when ClaudeAgentSDK::ResultMessage
    puts "\n[result] #{msg.subtype}"
    puts "  Duration: #{msg.duration_ms}ms (API: #{msg.duration_api_ms}ms)"
    puts "  Turns: #{msg.num_turns}, Cost: $#{msg.total_cost_usd}"
    puts "  Stop reason: #{msg.stop_reason}" if msg.stop_reason
    puts "  Fast mode: #{msg.fast_mode_state}" if msg.fast_mode_state

    msg.model_usage&.each do |model, usage|
      puts "  #{model}: #{usage}"
    end

    if msg.permission_denials&.any?
      puts "  Permission denials:"
      msg.permission_denials.each { |d| puts "    #{d[:tool_name]}: #{d[:tool_use_id]}" }
    end

    puts "  Errors: #{msg.errors.join(', ')}" if msg.errors&.any?
  end
end
