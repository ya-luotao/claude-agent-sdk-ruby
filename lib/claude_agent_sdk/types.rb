# frozen_string_literal: true

module ClaudeAgentSDK
  # Type constants for permission modes
  PERMISSION_MODES = %w[default acceptEdits plan bypassPermissions dontAsk auto].freeze

  # Type constants for setting sources
  SETTING_SOURCES = %w[user project local].freeze

  # Effort levels for `ClaudeAgentOptions#effort`. The CLI (Claude Code 2.1.111+)
  # accepts these values; the set of *supported* levels is model-dependent
  # (e.g. `xhigh` is only supported on Opus 4.7 and falls back to `high` on
  # Opus 4.6 / Sonnet 4.6). An Integer is also accepted and forwarded verbatim.
  EFFORT_LEVELS = %w[low medium high xhigh max].freeze

  # Type constants for permission update destinations
  PERMISSION_UPDATE_DESTINATIONS = %w[userSettings projectSettings localSettings session].freeze

  # Type constants for permission behaviors
  PERMISSION_BEHAVIORS = %w[allow deny ask].freeze

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

  # Type constants for assistant message errors
  ASSISTANT_MESSAGE_ERRORS = %w[authentication_failed billing_error rate_limit invalid_request server_error max_output_tokens unknown].freeze

  # Type constants for SDK beta features
  # Available beta features that can be enabled via the betas option
  SDK_BETAS = %w[context-1m-2025-08-07].freeze

  # Base class for all types.
  class Type
    def self.wrap(object)
      case object
      when self
        object
      else
        new(object)
      end
    end

    def self.from_hash(hash)
      return unless hash.is_a?(Hash)

      new(hash)
    end

    def initialize(attributes = {})
      assign_attributes(attributes) if attributes
      super()
    end

    def [](name)
      read_attribute(name)
    end

    def []=(name, value)
      assign_attribute(name, value)
    end

    # Subclasses should override this to return a hash representation of the object.
    def to_h
      {}
    end

    private

    # Allow camelCase attribute access
    def method_missing(method_name, ...)
      normalized = normalize_name(method_name)

      if normalized != method_name.to_s && respond_to?(normalized)
        public_send(normalized, ...)
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      normalized = normalize_name(method_name)
      (normalized != method_name.to_s && respond_to?(normalized)) || super
    end

    def assign_attributes(attributes)
      raise ArgumentError, "When assigning attributes, you must pass a hash as an argument, #{attributes.inspect} passed." unless attributes.respond_to?(:each_pair)

      return if attributes.empty?

      attributes.each_pair { |name, value| assign_attribute(name, value) }
    end

    def assign_attribute(name, value)
      setter = :"#{normalize_name(name)}="
      public_send(setter, value) if respond_to?(setter)
    end

    def read_attribute(name)
      getter = normalize_name(name)
      public_send(getter) if respond_to?(getter)
    end

    def normalize_name(name)
      name = name.dup.to_s
      name.gsub!(/(?<=[A-Z])(?=[A-Z][a-z])|(?<=[a-z\d])(?=[A-Z])/, "_")
      name.tr!("-", "_")
      name.downcase!
      name
    end

    FALSE_VALUES = [
      false, 0,
      "0", :"0",
      "f", :f,
      "F", :F,
      "false", :false,
      "FALSE", :FALSE,
      "off", :off,
      "OFF", :OFF,
    ].to_set.freeze

    private_constant :FALSE_VALUES

    def coerce_boolean(value)
      return if value.nil?

      if value == ""
        nil
      else
        !FALSE_VALUES.include?(value)
      end
    end
  end

  # Content Blocks

  # Text content block
  class TextBlock < Type
    attr_accessor :text
  end

  # Thinking content block
  class ThinkingBlock < Type
    attr_accessor :thinking, :signature
  end

  # Tool use content block
  class ToolUseBlock < Type
    attr_accessor :id, :name, :input
  end

  # Tool result content block
  class ToolResultBlock < Type
    attr_accessor :tool_use_id, :content, :is_error
  end

  # Generic content block for types the SDK doesn't explicitly handle (e.g., "document", "image").
  # Preserves the raw hash data for forward compatibility with newer CLI versions.
  class UnknownBlock < Type
    attr_accessor :type, :data
  end

  # Message Types

  # User message
  class UserMessage < Type
    attr_accessor :content, :uuid, :parent_tool_use_id, :tool_use_result

    # Concatenated text of this message. Handles both String content
    # (plain-text user prompt) and Array-of-blocks content (typed content).
    # Returns "" when there is no text.
    def text
      case content
      when String then content
      when Array then content.grep(TextBlock).map(&:text).join("\n\n")
      else ''
      end
    end

    alias to_s text
  end

  # Assistant message with content blocks
  class AssistantMessage < Type
    attr_accessor :content, :model, :parent_tool_use_id, :error, :usage,
                  :message_id, :stop_reason, :session_id, :uuid

    # Concatenated text across every TextBlock in this message's content.
    # Returns "" when the message has no text (e.g., a pure tool_use turn).
    def text
      Array(content).grep(TextBlock).map(&:text).join("\n\n")
    end

    alias to_s text
  end

  # System message with metadata.
  # When constructed from a raw CLI hash, the whole hash is stored in `#data`
  # unless the caller explicitly provides a `:data` entry.
  class SystemMessage < Type
    attr_accessor :subtype, :data

    def initialize(attributes = {})
      super
      @data ||= attributes if attributes.is_a?(Hash)
    end
  end

  # Init system message (emitted at session start and after /clear)
  class InitMessage < SystemMessage
    attr_accessor :uuid, :session_id, :agents, :api_key_source, :betas,
                  :claude_code_version, :cwd, :tools, :mcp_servers, :model,
                  :permission_mode, :slash_commands, :output_style, :skills, :plugins,
                  :fast_mode_state # "off", "cooldown", or "on"
  end

  # Compact boundary system message (emitted after context compaction completes)
  class CompactBoundaryMessage < SystemMessage
    attr_accessor :uuid, :session_id
    attr_reader :compact_metadata

    def compact_metadata=(value)
      @compact_metadata = value.is_a?(Hash) ? CompactMetadata.new(value) : value
    end
  end

  # Metadata about a compaction event
  class CompactMetadata < Type
    attr_accessor :pre_tokens, :post_tokens, :trigger, :custom_instructions, :preserved_segment
  end

  # Status system message (compacting status, permission mode changes)
  class StatusMessage < SystemMessage
    attr_accessor :uuid, :session_id, :status, :permission_mode
  end

  # API retry system message
  class APIRetryMessage < SystemMessage
    attr_accessor :uuid, :session_id, :attempt, :max_retries, :retry_delay_ms, :error_status, :error
  end

  # Local command output system message
  class LocalCommandOutputMessage < SystemMessage
    attr_accessor :uuid, :session_id, :content
  end

  # Hook started system message
  class HookStartedMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event
  end

  # Hook progress system message
  class HookProgressMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event, :stdout, :stderr, :output
  end

  # Hook response system message
  class HookResponseMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event,
                  :output, :stdout, :stderr, :exit_code,
                  :outcome # "success", "error", or "cancelled"
  end

  # Session state changed system message
  class SessionStateChangedMessage < SystemMessage
    attr_accessor :uuid, :session_id,
                  :state # "idle", "running", or "requires_action"
  end

  # Files persisted system message
  class FilesPersistedMessage < SystemMessage
    attr_accessor :uuid, :session_id, :files, :failed, :processed_at
  end

  # Elicitation complete system message
  class ElicitationCompleteMessage < SystemMessage
    attr_accessor :uuid, :session_id, :mcp_server_name, :elicitation_id
  end

  # Task lifecycle notification statuses
  TASK_NOTIFICATION_STATUSES = %w[completed failed stopped].freeze

  # Typed usage data for task progress and notifications
  class TaskUsage < Type
    attr_accessor :total_tokens, :tool_uses, :duration_ms

    def initialize(attributes = {})
      super
      @total_tokens ||= 0
      @tool_uses    ||= 0
      @duration_ms  ||= 0
    end
  end

  # Task started system message (subagent/background task started)
  class TaskStartedMessage < SystemMessage
    attr_accessor :task_id, :description, :uuid, :session_id, :tool_use_id, :task_type,
                  :workflow_name, :prompt
  end

  # Task progress system message (periodic update from a running task)
  class TaskProgressMessage < SystemMessage
    attr_accessor :task_id, :description, :usage, :uuid, :session_id, :tool_use_id, :last_tool_name, :summary
  end

  # Task notification system message (task completed/failed/stopped)
  class TaskNotificationMessage < SystemMessage
    attr_accessor :task_id, :status, :output_file, :summary, :uuid, :session_id, :tool_use_id, :usage
  end

  # Result message with cost and usage information
  class ResultMessage < Type
    attr_accessor :subtype, :duration_ms, :duration_api_ms, :is_error,
                  :num_turns, :session_id, :stop_reason, :total_cost_usd, :usage,
                  :result, :structured_output,
                  :model_usage,        # Hash of { model_name => usage_data }
                  :permission_denials, # Array of { tool_name:, tool_use_id:, tool_input: }
                  :errors,             # Array of error strings (present on error subtypes)
                  :uuid,
                  :fast_mode_state     # "off", "cooldown", or "on"
  end

  # Stream event for partial message updates
  class StreamEvent < Type
    attr_accessor :uuid, :session_id, :event, :parent_tool_use_id
  end

  # Tool progress message (type: 'tool_progress')
  class ToolProgressMessage < Type
    attr_accessor :uuid, :session_id, :tool_use_id, :tool_name, :parent_tool_use_id,
                  :elapsed_time_seconds, :task_id
  end

  # Auth status message (type: 'auth_status')
  class AuthStatusMessage < Type
    attr_accessor :uuid, :session_id, :is_authenticating, :output, :error
  end

  # Tool use summary message (type: 'tool_use_summary')
  class ToolUseSummaryMessage < Type
    attr_accessor :uuid, :session_id, :summary, :preceding_tool_use_ids
  end

  # Prompt suggestion message (type: 'prompt_suggestion')
  class PromptSuggestionMessage < Type
    attr_accessor :uuid, :session_id, :suggestion
  end

  # Type constants for rate limit statuses
  RATE_LIMIT_STATUSES = %w[allowed allowed_warning rejected].freeze

  # Type constants for rate limit types
  RATE_LIMIT_TYPES = %w[five_hour seven_day seven_day_opus seven_day_sonnet overage].freeze

  # Rate limit info with typed fields
  class RateLimitInfo < Type
    attr_accessor :status, :resets_at, :rate_limit_type, :utilization,
                  :overage_status, :overage_resets_at, :overage_disabled_reason, :raw

    def initialize(attributes = {})
      super
      @raw ||= {}
    end
  end

  # Rate limit event emitted when rate limit info changes
  class RateLimitEvent < Type
    attr_accessor :uuid, :session_id, :raw_data
    attr_reader :rate_limit_info

    def initialize(attributes = {})
      super
      @rate_limit_info ||= RateLimitInfo.new
    end

    def rate_limit_info=(value)
      @rate_limit_info = value.is_a?(Hash) ? RateLimitInfo.new(value.merge(raw: value)) : value
    end

    # Backward-compatible accessor returning the full raw event payload
    def data
      @raw_data || {}
    end
  end

  # Thinking configuration types

  # Adaptive thinking: uses a default budget of 32000 tokens
  class ThinkingConfigAdaptive < Type
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'adaptive'
    end
  end

  # Enabled thinking: uses a user-specified budget
  class ThinkingConfigEnabled < Type
    attr_accessor :budget_tokens
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'enabled'
    end
  end

  # Disabled thinking: sets thinking tokens to 0
  class ThinkingConfigDisabled < Type
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'disabled'
    end
  end

  # Agent definition configuration
  class AgentDefinition < Type
    attr_accessor :description, :prompt, :tools, :disallowed_tools, :model, :skills, :memory, :mcp_servers,
                  :initial_prompt, :max_turns, :background, :effort, :permission_mode
  end

  # Permission rule value
  class PermissionRuleValue < Type
    attr_accessor :tool_name, :rule_content
  end

  # Permission update configuration
  class PermissionUpdate < Type
    attr_accessor :type, :rules, :behavior, :mode, :directories, :destination

    def to_h
      result = { type: @type }
      result[:destination] = @destination if @destination

      case @type
      when 'addRules', 'replaceRules', 'removeRules'
        if @rules
          result[:rules] = @rules.map do |rule|
            {
              toolName: rule.tool_name,
              ruleContent: rule.rule_content
            }
          end
        end
        result[:behavior] = @behavior if @behavior
      when 'setMode'
        result[:mode] = @mode if @mode
      when 'addDirectories', 'removeDirectories'
        result[:directories] = @directories if @directories
      end

      result
    end
  end

  # Tool permission context
  class ToolPermissionContext < Type
    attr_accessor :signal, :suggestions, :tool_use_id, :agent_id

    def initialize(attributes = {})
      super
      @suggestions ||= []
    end
  end

  # Permission results
  class PermissionResultAllow < Type
    attr_accessor :updated_input, :updated_permissions
    attr_reader :behavior

    def initialize(attributes = {})
      super
      @behavior = 'allow'
    end
  end

  class PermissionResultDeny < Type
    attr_accessor :message, :interrupt
    attr_reader :behavior

    def initialize(attributes = {})
      super
      @behavior = 'deny'
      @message ||= ''
      @interrupt = false if @interrupt.nil?
    end
  end

  # Hook matcher configuration
  class HookMatcher < Type
    attr_accessor :matcher, :hooks, :timeout

    def initialize(attributes = {})
      super
      @hooks ||= []
    end
  end

  # Hook context passed to hook callbacks
  class HookContext < Type
    attr_accessor :signal
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
  class StopHookInput < BaseHookInput
    attr_accessor :stop_hook_active, :last_assistant_message

    def initialize(attributes = {})
      super
      @hook_event_name = 'Stop'
      @stop_hook_active = false if @stop_hook_active.nil?
    end
  end

  # SubagentStop hook input
  class SubagentStopHookInput < BaseHookInput
    attr_accessor :stop_hook_active, :agent_id, :agent_transcript_path, :agent_type,
                  :last_assistant_message

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

  # Setup hook specific output
  class SetupHookSpecificOutput < Type
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

  # PostToolUse hook specific output
  class PostToolUseHookSpecificOutput < Type
    attr_accessor :additional_context, :updated_mcp_tool_output
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUse'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result[:updatedMCPToolOutput] = @updated_mcp_tool_output if @updated_mcp_tool_output
      result
    end
  end

  # PostToolUseFailure hook specific output
  class PostToolUseFailureHookSpecificOutput < Type
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

  # MCP status response types

  # MCP server connection status values
  MCP_SERVER_CONNECTION_STATUSES = %w[connected failed needs-auth pending disabled].freeze

  # MCP server info (name and version)
  class McpServerInfo < Type
    attr_accessor :name, :version
  end

  # MCP tool annotation hints
  class McpToolAnnotations < Type
    attr_accessor :read_only, :destructive, :open_world

    # Backwards-compatible parse; returns nil for nil input.
    def self.parse(data)
      from_hash(data)
    end
  end

  # MCP tool info (name, description, annotations)
  class McpToolInfo < Type
    attr_accessor :name, :description
    attr_reader :annotations

    def annotations=(value)
      @annotations = value.is_a?(Hash) ? McpToolAnnotations.new(value) : value
    end

    # Backwards-compatible parse; returns nil for nil input.
    def self.parse(data)
      from_hash(data)
    end
  end

  # Output-only serializable version of McpSdkServerConfig (without live instance)
  # Returned in MCP status responses
  class McpSdkServerConfigStatus < Type
    attr_accessor :name
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'sdk'
    end

    def to_h
      { type: @type, name: @name }
    end
  end

  # Claude.ai proxy MCP server config
  # Output-only type that appears in status responses for servers proxied through Claude.ai
  class McpClaudeAIProxyServerConfig < Type
    attr_accessor :url, :id
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'claudeai-proxy'
    end

    def to_h
      { type: @type, url: @url, id: @id }
    end
  end

  # Status of a single MCP server connection
  class McpServerStatus < Type
    attr_accessor :name, :status, :error, :scope
    attr_reader :server_info, :config, :tools

    def server_info=(value)
      @server_info = value.is_a?(Hash) ? McpServerInfo.new(value) : value
    end

    def tools=(value)
      @tools = value.is_a?(Array) ? value.map { |t| t.is_a?(Hash) ? McpToolInfo.new(t) : t } : value
    end

    def config=(value)
      @config = self.class.parse_config(value) || value
    end

    # Backwards-compatible parse; normalizes camelCase `serverInfo` and
    # polymorphically builds the nested `config`.
    def self.parse(data)
      from_hash(data)
    end

    def self.parse_config(config)
      return nil unless config.is_a?(Hash) && config[:type]

      case config[:type]
      when 'claudeai-proxy'
        McpClaudeAIProxyServerConfig.new(url: config[:url], id: config[:id])
      when 'sdk'
        McpSdkServerConfigStatus.new(name: config[:name])
      else
        config
      end
    end
  end

  # Response from get_mcp_status containing all server statuses
  class McpStatusResponse < Type
    attr_reader :mcp_servers

    def mcp_servers=(value)
      @mcp_servers = value.is_a?(Array) ? value.map { |s| s.is_a?(Hash) ? McpServerStatus.new(s) : s } : value
    end

    # Backwards-compatible parse; returns nil for nil input.
    def self.parse(data)
      from_hash(data)
    end
  end

  # MCP Server configurations
  class McpStdioServerConfig < Type
    attr_accessor :command, :args, :env
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'stdio'
    end

    def to_h
      result = { type: @type, command: @command }
      result[:args] = @args if @args
      result[:env] = @env if @env
      result
    end
  end

  class McpSSEServerConfig < Type
    attr_accessor :url, :headers
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'sse'
    end

    def to_h
      result = { type: @type, url: @url }
      result[:headers] = @headers if @headers
      result
    end
  end

  class McpHttpServerConfig < Type
    attr_accessor :url, :headers
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'http'
    end

    def to_h
      result = { type: @type, url: @url }
      result[:headers] = @headers if @headers
      result
    end
  end

  class McpSdkServerConfig < Type
    attr_accessor :name, :instance
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'sdk'
    end

    def to_h
      { type: @type, name: @name, instance: @instance }
    end
  end

  # SDK Plugin configuration
  class SdkPluginConfig < Type
    attr_accessor :path
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'local'
    end

    def to_h
      { type: @type, path: @path }
    end
  end

  # Sandbox network configuration
  class SandboxNetworkConfig < Type
    attr_accessor :allowed_domains, :allow_managed_domains_only,
                  :allow_unix_sockets, :allow_all_unix_sockets, :allow_local_binding,
                  :http_proxy_port, :socks_proxy_port

    def to_h
      result = {}
      result[:allowedDomains] = @allowed_domains if @allowed_domains
      result[:allowManagedDomainsOnly] = @allow_managed_domains_only unless @allow_managed_domains_only.nil?
      result[:allowUnixSockets] = @allow_unix_sockets unless @allow_unix_sockets.nil?
      result[:allowAllUnixSockets] = @allow_all_unix_sockets unless @allow_all_unix_sockets.nil?
      result[:allowLocalBinding] = @allow_local_binding unless @allow_local_binding.nil?
      result[:httpProxyPort] = @http_proxy_port if @http_proxy_port
      result[:socksProxyPort] = @socks_proxy_port if @socks_proxy_port
      result
    end
  end

  # Sandbox filesystem configuration
  class SandboxFilesystemConfig < Type
    attr_accessor :allow_write, :deny_write, :deny_read, :allow_read, :allow_managed_read_paths_only

    def to_h
      result = {}
      result[:allowWrite] = @allow_write if @allow_write
      result[:denyWrite] = @deny_write if @deny_write
      result[:denyRead] = @deny_read if @deny_read
      result[:allowRead] = @allow_read if @allow_read
      result[:allowManagedReadPathsOnly] = @allow_managed_read_paths_only unless @allow_managed_read_paths_only.nil?
      result
    end
  end

  # Sandbox settings for isolated command execution
  class SandboxSettings < Type
    attr_accessor :enabled, :fail_if_unavailable, :auto_allow_bash_if_sandboxed,
                  :excluded_commands, :allow_unsandboxed_commands, :network, :filesystem,
                  :ignore_violations, :enable_weaker_nested_sandbox,
                  :enable_weaker_network_isolation, :ripgrep

    def to_h
      result = {}
      result[:enabled] = @enabled unless @enabled.nil?
      result[:failIfUnavailable] = @fail_if_unavailable unless @fail_if_unavailable.nil?
      result[:autoAllowBashIfSandboxed] = @auto_allow_bash_if_sandboxed unless @auto_allow_bash_if_sandboxed.nil?
      result[:excludedCommands] = @excluded_commands if @excluded_commands
      result[:allowUnsandboxedCommands] = @allow_unsandboxed_commands unless @allow_unsandboxed_commands.nil?
      result[:network] = @network.is_a?(SandboxNetworkConfig) ? @network.to_h : @network if @network
      result[:filesystem] = @filesystem.is_a?(SandboxFilesystemConfig) ? @filesystem.to_h : @filesystem if @filesystem
      result[:ignoreViolations] = @ignore_violations if @ignore_violations
      result[:enableWeakerNestedSandbox] = @enable_weaker_nested_sandbox unless @enable_weaker_nested_sandbox.nil?
      result[:enableWeakerNetworkIsolation] = @enable_weaker_network_isolation unless @enable_weaker_network_isolation.nil?
      result[:ripgrep] = @ripgrep if @ripgrep
      result
    end
  end

  # Result of a session fork operation
  class ForkSessionResult < Type
    attr_accessor :session_id
  end

  # API-side task budget in tokens.
  # When set, the model is made aware of its remaining token budget so it can
  # pace tool use and wrap up before the limit.
  class TaskBudget < Type
    attr_accessor :total

    def to_h
      { total: @total }
    end
  end

  # System prompt file configuration — loads system prompt from a file path
  class SystemPromptFile < Type
    attr_accessor :path
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'file'
    end

    def to_h
      { type: @type, path: @path }
    end
  end

  # System prompt preset configuration
  class SystemPromptPreset < Type
    attr_reader :type
    attr_accessor :preset, :append, :exclude_dynamic_sections

    def initialize(attributes = {})
      super
      @type = 'preset'
    end

    def to_h
      result = { type: @type, preset: @preset }
      result[:append] = @append if @append
      result[:exclude_dynamic_sections] = @exclude_dynamic_sections unless @exclude_dynamic_sections.nil?
      result
    end
  end

  # Tools preset configuration
  class ToolsPreset < Type
    attr_reader :type
    attr_accessor :preset

    def initialize(attributes = {})
      super
      @type = 'preset'
    end

    def to_h
      { type: @type, preset: @preset }
    end
  end

  # Claude Agent Options for configuring queries
  class ClaudeAgentOptions < Type
    attr_accessor :allowed_tools, :system_prompt, :mcp_servers, :permission_mode,
                  :continue_conversation, :resume, :session_id, :max_turns, :disallowed_tools,
                  :model, :permission_prompt_tool_name, :cwd, :cli_path, :settings,
                  :add_dirs, :env, :extra_args, :max_buffer_size, :stderr,
                  :can_use_tool, :hooks, :user, :include_partial_messages,
                  :fork_session, :agents, :setting_sources,
                  :output_format, :max_budget_usd, :max_thinking_tokens,
                  :fallback_model, :plugins, :debug_stderr,
                  :betas, :tools, :sandbox, :enable_file_checkpointing, :append_allowed_tools,
                  :thinking, :effort, :bare, :observers, :task_budget

    def initialize(attributes = {})
      self.fork_session = false
      self.continue_conversation = false
      self.include_partial_messages = false
      self.enable_file_checkpointing = false

      super(merge_with_defaults(attributes || {}))

      # Non-nil defaults for options that need them.
      self.env              ||= {}
      self.extra_args       ||= {}
      self.mcp_servers      ||= {}
      self.add_dirs         ||= []
      self.observers        ||= []
      self.allowed_tools    ||= []
      self.disallowed_tools ||= []
    end

    def dup_with(**changes)
      new_options = self.dup
      changes.each { |key, value| new_options[key] = value }
      new_options
    end

    def bare?
      !!bare
    end

    def bare=(value)
      @bare = coerce_boolean(value)
    end

    def fork_session?
      !!fork_session
    end

    def fork_session=(value)
      @fork_session = coerce_boolean(value)
    end

    def enable_file_checkpointing?
      !!enable_file_checkpointing
    end

    def enable_file_checkpointing=(value)
      @enable_file_checkpointing = coerce_boolean(value)
    end

    def include_partial_messages?
      !!include_partial_messages
    end

    def include_partial_messages=(value)
      @include_partial_messages = coerce_boolean(value)
    end

    def continue_conversation?
      !!continue_conversation
    end

    def continue_conversation=(value)
      @continue_conversation = coerce_boolean(value)
    end

    private

    # Merge caller-provided attributes with configured defaults.
    # Only keys the caller explicitly passed are treated as overrides;
    # method-signature defaults ([], {}, false) are NOT present unless the caller wrote them.
    def merge_with_defaults(attributes)
      return attributes unless defined?(ClaudeAgentSDK) && ClaudeAgentSDK.respond_to?(:default_options)

      defaults = ClaudeAgentSDK.default_options
      return attributes unless defaults.any?

      # Start from configured defaults (deep dup hashes to prevent mutation)
      result = defaults.transform_values { |v| v.is_a?(Hash) ? v.dup : v }
      attributes.each do |key, value|
        default_val = result[key]
        result[key] = if value.nil?
                        default_val # nil means "no preference" — keep the configured default
                      elsif default_val.is_a?(Hash) && value.is_a?(Hash)
                        default_val.merge(value)
                      else
                        value
                      end
      end
      result
    end
  end

  # SDK MCP Tool definition
  class SdkMcpTool < Type
    attr_accessor :name, :description, :input_schema, :handler, :annotations, :meta
  end

  # SDK MCP Resource definition
  class SdkMcpResource < Type
    attr_accessor :uri, :name, :description, :mime_type, :reader
  end

  # SDK MCP Prompt definition
  class SdkMcpPrompt < Type
    attr_accessor :name, :description, :arguments, :generator
  end
end
