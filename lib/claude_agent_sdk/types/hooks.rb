# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
  # Type constants for hook events
  HOOK_EVENTS = %w[
    PreToolUse
    PostToolUse
    PostToolUseFailure
    Notification
    UserPromptSubmit
    SessionStart
    SessionEnd
    Stop
    StopFailure
    SubagentStart
    SubagentStop
    PreCompact
    PostCompact
    PermissionRequest
    PermissionDenied
    Setup
    TeammateIdle
    TaskCreated
    TaskCompleted
    Elicitation
    ElicitationResult
    ConfigChange
    WorktreeCreate
    WorktreeRemove
    InstructionsLoaded
    CwdChanged
    FileChanged
  ].freeze

  # Hook matcher configuration
  class HookMatcher < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :matcher, :hooks, :timeout

    def initialize(attributes = {})
      super
      @hooks ||= []
    end
  end

  # Hook context passed to hook callbacks. Dispatched hooks receive the control
  # request ID and a CancellationSignal (including on HookMatcher timeout).
  class HookContext < Type
    attr_accessor :signal, :request_id
  end

  # Base hook input with common fields
  class BaseHookInput < Type
    attr_accessor :session_id, :transcript_path, :cwd, :permission_mode
    attr_reader :hook_event_name
  end

  # PreToolUse hook input
  class PreToolUseHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_use_id, :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PreToolUse'
    end
  end

  # PostToolUse hook input
  class PostToolUseHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_response, :tool_use_id, :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUse'
    end
  end

  # UserPromptSubmit hook input
  class UserPromptSubmitHookInput < BaseHookInput
    attr_accessor :prompt

    def initialize(attributes = {})
      super
      @hook_event_name = 'UserPromptSubmit'
    end
  end

  # Stop hook input
  # Snapshot arrays are passed through unchanged. nil means unavailable;
  # [] means the CLI provided an empty snapshot. They cover the parent
  # session's background work, NOT all foreground and background agents.
  class StopHookInput < BaseHookInput
    attr_accessor :stop_hook_active, :last_assistant_message, :background_tasks, :session_crons

    def initialize(attributes = {})
      super
      @hook_event_name = 'Stop'
      @stop_hook_active = false if @stop_hook_active.nil?
    end
  end

  # SubagentStop hook input
  class SubagentStopHookInput < BaseHookInput
    attr_accessor :stop_hook_active, :agent_id, :agent_transcript_path, :agent_type,
                  :last_assistant_message, :background_tasks, :session_crons

    def initialize(attributes = {})
      super
      @hook_event_name = 'SubagentStop'
      @stop_hook_active = false if @stop_hook_active.nil?
    end
  end

  # PostToolUseFailure hook input
  class PostToolUseFailureHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_use_id, :error, :is_interrupt,
                  :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUseFailure'
    end
  end

  # Notification hook input
  class NotificationHookInput < BaseHookInput
    attr_accessor :message, :title, :notification_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'Notification'
    end
  end

  # SubagentStart hook input
  class SubagentStartHookInput < BaseHookInput
    attr_accessor :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'SubagentStart'
    end
  end

  # PermissionRequest hook input
  class PermissionRequestHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :permission_suggestions, :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PermissionRequest'
    end
  end

  # PreCompact hook input
  class PreCompactHookInput < BaseHookInput
    attr_accessor :trigger, :custom_instructions

    def initialize(attributes = {})
      super
      @hook_event_name = 'PreCompact'
    end
  end

  # SessionStart hook input
  class SessionStartHookInput < BaseHookInput
    attr_accessor :source, :agent_type, :model

    def initialize(attributes = {})
      super
      @hook_event_name = 'SessionStart'
    end
  end

  # SessionEnd hook input
  class SessionEndHookInput < BaseHookInput
    attr_accessor :reason

    def initialize(attributes = {})
      super
      @hook_event_name = 'SessionEnd'
    end
  end

  # Setup hook input
  class SetupHookInput < BaseHookInput
    attr_accessor :trigger

    def initialize(attributes = {})
      super
      @hook_event_name = 'Setup'
    end
  end

  # TeammateIdle hook input
  class TeammateIdleHookInput < BaseHookInput
    attr_accessor :teammate_name, :team_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'TeammateIdle'
    end
  end

  # TaskCompleted hook input
  class TaskCompletedHookInput < BaseHookInput
    attr_accessor :task_id, :task_subject, :task_description, :teammate_name, :team_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'TaskCompleted'
    end
  end

  # ConfigChange hook input
  class ConfigChangeHookInput < BaseHookInput
    attr_accessor :source, :file_path

    def initialize(attributes = {})
      super
      @hook_event_name = 'ConfigChange'
    end
  end

  # WorktreeCreate hook input
  class WorktreeCreateHookInput < BaseHookInput
    attr_accessor :name

    def initialize(attributes = {})
      super
      @hook_event_name = 'WorktreeCreate'
    end
  end

  # WorktreeRemove hook input
  class WorktreeRemoveHookInput < BaseHookInput
    attr_accessor :worktree_path

    def initialize(attributes = {})
      super
      @hook_event_name = 'WorktreeRemove'
    end
  end

  # StopFailure hook input
  class StopFailureHookInput < BaseHookInput
    attr_accessor :error, :error_details, :last_assistant_message

    def initialize(attributes = {})
      super
      @hook_event_name = 'StopFailure'
    end
  end

  # PostCompact hook input
  class PostCompactHookInput < BaseHookInput
    attr_accessor :trigger, :compact_summary

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostCompact'
    end
  end

  # PermissionDenied hook input
  class PermissionDeniedHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_use_id, :reason, :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PermissionDenied'
    end
  end

  # TaskCreated hook input
  class TaskCreatedHookInput < BaseHookInput
    attr_accessor :task_id, :task_subject, :task_description, :teammate_name, :team_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'TaskCreated'
    end
  end

  # Elicitation hook input
  class ElicitationHookInput < BaseHookInput
    attr_accessor :mcp_server_name, :message, :mode, :url,
                  :elicitation_id, :requested_schema

    def initialize(attributes = {})
      super
      @hook_event_name = 'Elicitation'
    end
  end

  # ElicitationResult hook input
  class ElicitationResultHookInput < BaseHookInput
    attr_accessor :mcp_server_name, :elicitation_id, :mode, :action, :content

    def initialize(attributes = {})
      super
      @hook_event_name = 'ElicitationResult'
    end
  end

  # InstructionsLoaded hook input
  class InstructionsLoadedHookInput < BaseHookInput
    attr_accessor :file_path, :memory_type, :load_reason, :globs, :trigger_file_path

    def initialize(attributes = {})
      super
      @hook_event_name = 'InstructionsLoaded'
    end
  end

  # CwdChanged hook input
  class CwdChangedHookInput < BaseHookInput
    attr_accessor :old_cwd, :new_cwd

    def initialize(attributes = {})
      super
      @hook_event_name = 'CwdChanged'
    end
  end

  # FileChanged hook input
  class FileChangedHookInput < BaseHookInput
    attr_accessor :file_path, :event

    def initialize(attributes = {})
      super
      @hook_event_name = 'FileChanged'
    end
  end

  # Fallback for hook events the SDK does not yet model. Carries the wire
  # event name and the complete raw payload so no fields are lost (Python
  # passes hook input through as a raw dict, so unknown events lose
  # nothing there).
  class UnknownHookInput < BaseHookInput
    attr_accessor :raw_input

    def initialize(attributes = {})
      super
      # Direct assignment: BaseHookInput exposes hook_event_name as
      # attr_reader only, and Type#assign_attribute silently drops keys
      # without public setters.
      @hook_event_name = attributes[:hook_event_name] || attributes['hook_event_name']
    end
  end

  # Setup hook specific output
  class SetupHookSpecificOutput < Type
    strict_attributes

    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'Setup'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PreToolUse hook specific output
  class PreToolUseHookSpecificOutput < Type
    strict_attributes

    attr_accessor :permission_decision, :permission_decision_reason,
                  :updated_input, :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PreToolUse'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:permissionDecision] = @permission_decision if @permission_decision
      result[:permissionDecisionReason] = @permission_decision_reason if @permission_decision_reason
      result[:updatedInput] = @updated_input if @updated_input
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PostToolUse hook specific output.
  #
  # `updated_tool_output` (CLI 2.1.110+) replaces the tool's output entirely
  # — works for any tool, MCP or built-in. `updated_mcp_tool_output` is the
  # legacy MCP-only field that pre-dates the unified one; the CLI still
  # honors it, so both are emitted when set. Mirrors Python's
  # `PostToolUseHookSpecificOutput`.
  class PostToolUseHookSpecificOutput < Type
    strict_attributes

    attr_accessor :additional_context, :updated_mcp_tool_output, :updated_tool_output
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUse'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result[:updatedToolOutput] = @updated_tool_output unless @updated_tool_output.nil?
      result[:updatedMCPToolOutput] = @updated_mcp_tool_output if @updated_mcp_tool_output
      result
    end
  end

  # PostToolUseFailure hook specific output
  class PostToolUseFailureHookSpecificOutput < Type
    strict_attributes

    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUseFailure'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # UserPromptSubmit hook specific output
  class UserPromptSubmitHookSpecificOutput < Type
    strict_attributes

    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'UserPromptSubmit'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # Notification hook specific output
  class NotificationHookSpecificOutput < Type
    strict_attributes

    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'Notification'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # SubagentStart hook specific output
  class SubagentStartHookSpecificOutput < Type
    strict_attributes

    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'SubagentStart'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PermissionRequest hook specific output
  class PermissionRequestHookSpecificOutput < Type
    strict_attributes

    attr_accessor :decision
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PermissionRequest'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:decision] = @decision if @decision
      result
    end
  end

  # SessionStart hook specific output
  class SessionStartHookSpecificOutput < Type
    strict_attributes

    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'SessionStart'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PermissionDenied hook specific output
  class PermissionDeniedHookSpecificOutput < Type
    strict_attributes

    attr_accessor :retry
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PermissionDenied'
      @retry = false if @retry.nil?
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:retry] = @retry unless @retry.nil?
      result
    end
  end

  # CwdChanged hook specific output
  class CwdChangedHookSpecificOutput < Type
    strict_attributes

    attr_accessor :watch_paths
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'CwdChanged'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:watchPaths] = @watch_paths if @watch_paths
      result
    end
  end

  # FileChanged hook specific output
  class FileChangedHookSpecificOutput < Type
    strict_attributes

    attr_accessor :watch_paths
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'FileChanged'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:watchPaths] = @watch_paths if @watch_paths
      result
    end
  end

  # Async hook JSON output
  class AsyncHookJSONOutput < Type
    strict_attributes

    attr_accessor :async, :async_timeout

    def initialize(attributes = {})
      super
      @async = true if @async.nil?
    end

    def to_h
      result = { async: @async }
      result[:asyncTimeout] = @async_timeout if @async_timeout
      result
    end
  end

  # Sync hook JSON output
  class SyncHookJSONOutput < Type
    strict_attributes

    attr_accessor :continue, :suppress_output, :stop_reason, :decision,
                  :system_message, :reason, :hook_specific_output

    def initialize(attributes = {})
      super
      @continue = true if @continue.nil?
      @suppress_output = false if @suppress_output.nil?
    end

    def to_h
      result = { continue: @continue }
      result[:suppressOutput] = @suppress_output if @suppress_output
      result[:stopReason] = @stop_reason if @stop_reason
      result[:decision] = @decision if @decision
      result[:systemMessage] = @system_message if @system_message
      result[:reason] = @reason if @reason
      result[:hookSpecificOutput] = @hook_specific_output.to_h if @hook_specific_output
      result
    end
  end
end
