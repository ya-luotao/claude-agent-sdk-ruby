#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Session and lifecycle hook events
#
# The SDK supports 27 hook events. This example demonstrates the
# lifecycle hooks beyond the basic PreToolUse/PostToolUse covered
# in hooks_example.rb and advanced_hooks_example.rb.

puts "=== Lifecycle Hooks Example ==="

Async do
  # SessionStart: fires at session startup, resume, clear, or compact
  session_start = lambda do |input, _id, _ctx|
    puts "[SessionStart] source=#{input.source}, model=#{input.model}"
    # Return additional context to inject into the conversation
    ClaudeAgentSDK::SessionStartHookSpecificOutput.new(
      additional_context: "Session started at #{Time.now}"
    ).to_h
  end

  # SessionEnd: fires when the session ends
  session_end = lambda do |input, _id, _ctx|
    puts "[SessionEnd] reason=#{input.reason}"
    {}
  end

  # Stop: fires when Claude finishes a turn (last_assistant_message available)
  stop = lambda do |input, _id, _ctx|
    puts "[Stop] active=#{input.stop_hook_active}"
    puts "  Last message: #{input.last_assistant_message&.slice(0, 80)}..." if input.last_assistant_message
    {}
  end

  # StopFailure: fires when a stop hook itself fails
  stop_failure = lambda do |input, _id, _ctx|
    puts "[StopFailure] error=#{input.error}, details=#{input.error_details}"
    {}
  end

  # PreCompact: fires before context compaction
  pre_compact = lambda do |input, _id, _ctx|
    puts "[PreCompact] trigger=#{input.trigger}, custom_instructions=#{input.custom_instructions}"
    {}
  end

  # PostCompact: fires after compaction with the summary
  post_compact = lambda do |input, _id, _ctx|
    puts "[PostCompact] trigger=#{input.trigger}"
    puts "  Summary: #{input.compact_summary&.slice(0, 100)}..."
    {}
  end

  # Setup: fires on init or maintenance
  setup = lambda do |input, _id, _ctx|
    puts "[Setup] trigger=#{input.trigger}" # "init" or "maintenance"
    ClaudeAgentSDK::SetupHookSpecificOutput.new(
      additional_context: "Environment: #{RUBY_PLATFORM}"
    ).to_h
  end

  # PermissionDenied: fires when a tool permission is denied
  permission_denied = lambda do |input, _id, _ctx|
    puts "[PermissionDenied] tool=#{input.tool_name}, reason=#{input.reason}"
    # Optionally retry
    ClaudeAgentSDK::PermissionDeniedHookSpecificOutput.new(retry: false).to_h
  end

  # ConfigChange: fires when settings files change
  config_change = lambda do |input, _id, _ctx|
    puts "[ConfigChange] source=#{input.source}, file=#{input.file_path}"
    {}
  end

  # CwdChanged: fires when the working directory changes
  cwd_changed = lambda do |input, _id, _ctx|
    puts "[CwdChanged] #{input.old_cwd} -> #{input.new_cwd}"
    # Optionally return watch paths
    ClaudeAgentSDK::CwdChangedHookSpecificOutput.new(
      watch_paths: [input.new_cwd]
    ).to_h
  end

  # FileChanged: fires when watched files change
  file_changed = lambda do |input, _id, _ctx|
    puts "[FileChanged] #{input.event}: #{input.file_path}"
    ClaudeAgentSDK::FileChangedHookSpecificOutput.new(
      watch_paths: [File.dirname(input.file_path)]
    ).to_h
  end

  # InstructionsLoaded: fires when CLAUDE.md or memory files are loaded
  instructions_loaded = lambda do |input, _id, _ctx|
    puts "[InstructionsLoaded] #{input.memory_type}: #{input.file_path} (#{input.load_reason})"
    {}
  end

  # TaskCreated/TaskCompleted: fires for subagent task lifecycle
  task_created = lambda do |input, _id, _ctx|
    puts "[TaskCreated] #{input.task_id}: #{input.task_subject}"
    {}
  end

  task_completed = lambda do |input, _id, _ctx|
    puts "[TaskCompleted] #{input.task_id}: #{input.task_subject}"
    {}
  end

  # TeammateIdle: fires when a teammate agent becomes idle
  teammate_idle = lambda do |input, _id, _ctx|
    puts "[TeammateIdle] #{input.teammate_name} in team #{input.team_name}"
    {}
  end

  # Elicitation: fires when an MCP server requests user input
  elicitation = lambda do |input, _id, _ctx|
    puts "[Elicitation] #{input.mcp_server_name}: #{input.message}"
    {} # Let the dialog show
  end

  # Build the hooks config — use HookMatcher for each event
  matcher = ->(hooks) { [ClaudeAgentSDK::HookMatcher.new(hooks: hooks)] }

  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    hooks: {
      'SessionStart' => matcher.call([session_start]),
      'SessionEnd' => matcher.call([session_end]),
      'Stop' => matcher.call([stop]),
      'StopFailure' => matcher.call([stop_failure]),
      'PreCompact' => matcher.call([pre_compact]),
      'PostCompact' => matcher.call([post_compact]),
      'Setup' => matcher.call([setup]),
      'PermissionDenied' => matcher.call([permission_denied]),
      'ConfigChange' => matcher.call([config_change]),
      'CwdChanged' => matcher.call([cwd_changed]),
      'FileChanged' => matcher.call([file_changed]),
      'InstructionsLoaded' => matcher.call([instructions_loaded]),
      'TaskCreated' => matcher.call([task_created]),
      'TaskCompleted' => matcher.call([task_completed]),
      'TeammateIdle' => matcher.call([teammate_idle]),
      'Elicitation' => matcher.call([elicitation])
    },
    permission_mode: 'bypassPermissions'
  )

  client = ClaudeAgentSDK::Client.new(options: options)

  begin
    client.connect
    client.query("Say hello in one sentence.")
    client.receive_response do |msg|
      case msg
      when ClaudeAgentSDK::AssistantMessage
        msg.content.each { |b| puts b.text if b.is_a?(ClaudeAgentSDK::TextBlock) }
      when ClaudeAgentSDK::ResultMessage
        puts "Done (#{msg.num_turns} turns)"
      end
    end
  ensure
    client.disconnect
  end
end.wait
