#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'
require 'json'

# Requires an authenticated Claude Code CLI. Prints raw SDK data for 60 seconds;
# it does not aggregate statuses or persist application state.
directory = Dir.pwd
hook = lambda do |input, _tool_id, _context|
  data = { hook_event_name: input.hook_event_name, session_id: input.session_id }
  if input.respond_to?(:background_tasks)
    data.merge!(background_tasks: input.background_tasks, session_crons: input.session_crons)
  end
  if input.respond_to?(:agent_id) && input.agent_id
    data.merge!(agent_id: input.agent_id, agent_type: input.agent_type)
    # Metadata can be absent at SubagentStart; check again on later events.
    data[:metadata] = ClaudeAgentSDK.get_subagent_metadata(
      session_id: input.session_id, agent_id: input.agent_id, directory: directory
    )
  end
  puts JSON.generate(data)
  {}
end

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  cwd: directory,
  tools: ['Agent'],
  allowed_tools: ['Agent'],
  forward_subagent_text: true,
  agents: {
    'reviewer' => ClaudeAgentSDK::AgentDefinition.new(
      description: 'Reviews a short statement without using tools.',
      prompt: 'Explain one caveat in the supplied statement. Do not use tools.',
      tools: []
    )
  },
  hooks: %w[SubagentStart SubagentStop Stop].to_h do |event|
    [event, [ClaudeAgentSDK::HookMatcher.new(hooks: [hook])]]
  end
)

Async do |task|
  client = ClaudeAgentSDK::Client.new(options: options)
  begin
    task.with_timeout(60) do
      client.connect
      client.query('Use the reviewer subagent to review: "Retries always make an operation safe."')
      # Keep reading after the parent result: background tasks may still emit events.
      client.receive_messages do |message|
        case message
        when ClaudeAgentSDK::TaskStartedMessage, ClaudeAgentSDK::TaskProgressMessage,
             ClaudeAgentSDK::TaskUpdatedMessage, ClaudeAgentSDK::TaskNotificationMessage,
             ClaudeAgentSDK::BackgroundTasksChangedMessage
          puts JSON.generate(message.data)
        when ClaudeAgentSDK::AssistantMessage
          if message.parent_tool_use_id
            puts JSON.generate(parent_tool_use_id: message.parent_tool_use_id,
                               model: message.model, text: message.text)
          end
        end
      end
    end
  rescue Async::TimeoutError
    warn 'Demo observation window ended; disconnecting (this does not imply task completion).'
  ensure
    client.disconnect
  end
end.wait
