# frozen_string_literal: true

module ClaudeAgentSDK
  # Type constants for permission modes
  PERMISSION_MODES = %w[default acceptEdits plan bypassPermissions dontAsk auto].freeze

  # Type constants for setting sources
  SETTING_SOURCES = %w[user project local].freeze

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

  # Content Blocks

  # Text content block
  class TextBlock
    attr_accessor :text

    def initialize(text:)
      @text = text
    end
  end

  # Thinking content block
  class ThinkingBlock
    attr_accessor :thinking, :signature

    def initialize(thinking:, signature:)
      @thinking = thinking
      @signature = signature
    end
  end

  # Tool use content block
  class ToolUseBlock
    attr_accessor :id, :name, :input

    def initialize(id:, name:, input:)
      @id = id
      @name = name
      @input = input
    end
  end

  # Tool result content block
  class ToolResultBlock
    attr_accessor :tool_use_id, :content, :is_error

    def initialize(tool_use_id:, content: nil, is_error: nil)
      @tool_use_id = tool_use_id
      @content = content
      @is_error = is_error
    end
  end

  # Generic content block for types the SDK doesn't explicitly handle (e.g., "document", "image").
  # Preserves the raw hash data for forward compatibility with newer CLI versions.
  class UnknownBlock
    attr_accessor :type, :data

    def initialize(type:, data:)
      @type = type
      @data = data
    end
  end

  # Message Types

  # User message
  class UserMessage
    attr_accessor :content, :uuid, :parent_tool_use_id, :tool_use_result

    def initialize(content:, uuid: nil, parent_tool_use_id: nil, tool_use_result: nil)
      @content = content
      @uuid = uuid # Unique identifier for rewind support
      @parent_tool_use_id = parent_tool_use_id
      @tool_use_result = tool_use_result # Tool result data when message is a tool response
    end
  end

  # Assistant message with content blocks
  class AssistantMessage
    attr_accessor :content, :model, :parent_tool_use_id, :error, :usage

    def initialize(content:, model:, parent_tool_use_id: nil, error: nil, usage: nil)
      @content = content
      @model = model
      @parent_tool_use_id = parent_tool_use_id
      @error = error # One of: authentication_failed, billing_error, rate_limit, invalid_request, server_error, unknown
      @usage = usage # Token usage info from the API response
    end
  end

  # System message with metadata
  class SystemMessage
    attr_accessor :subtype, :data

    def initialize(subtype:, data:)
      @subtype = subtype
      @data = data
    end
  end

  # Init system message (emitted at session start and after /clear)
  class InitMessage < SystemMessage
    attr_accessor :uuid, :session_id, :agents, :api_key_source, :betas,
                  :claude_code_version, :cwd, :tools, :mcp_servers, :model,
                  :permission_mode, :slash_commands, :output_style, :skills, :plugins,
                  :fast_mode_state

    def initialize(subtype:, data:, uuid: nil, session_id: nil, agents: nil,
                   api_key_source: nil, betas: nil, claude_code_version: nil,
                   cwd: nil, tools: nil, mcp_servers: nil, model: nil,
                   permission_mode: nil, slash_commands: nil, output_style: nil,
                   skills: nil, plugins: nil, fast_mode_state: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @agents = agents
      @api_key_source = api_key_source
      @betas = betas
      @claude_code_version = claude_code_version
      @cwd = cwd
      @tools = tools
      @mcp_servers = mcp_servers
      @model = model
      @permission_mode = permission_mode
      @slash_commands = slash_commands
      @output_style = output_style
      @skills = skills
      @plugins = plugins
      @fast_mode_state = fast_mode_state # "off", "cooldown", or "on"
    end
  end

  # Compact boundary system message (emitted after context compaction completes)
  class CompactBoundaryMessage < SystemMessage
    attr_accessor :uuid, :session_id, :compact_metadata

    def initialize(subtype:, data:, uuid: nil, session_id: nil, compact_metadata: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @compact_metadata = compact_metadata
    end
  end

  # Metadata about a compaction event
  class CompactMetadata
    attr_accessor :pre_tokens, :post_tokens, :trigger, :custom_instructions, :preserved_segment

    def initialize(pre_tokens: nil, post_tokens: nil, trigger: nil, custom_instructions: nil, preserved_segment: nil)
      @pre_tokens = pre_tokens
      @post_tokens = post_tokens
      @trigger = trigger # "manual" or "auto"
      @custom_instructions = custom_instructions
      @preserved_segment = preserved_segment # Hash with head_uuid, anchor_uuid, tail_uuid
    end

    def self.from_hash(hash)
      return nil unless hash.is_a?(Hash)

      preserved = hash[:preserved_segment] || hash['preserved_segment'] ||
                  hash[:preservedSegment] || hash['preservedSegment']

      new(
        pre_tokens: hash[:pre_tokens] || hash['pre_tokens'] || hash[:preTokens] || hash['preTokens'],
        post_tokens: hash[:post_tokens] || hash['post_tokens'] || hash[:postTokens] || hash['postTokens'],
        trigger: hash[:trigger] || hash['trigger'],
        custom_instructions: hash[:custom_instructions] || hash['custom_instructions'] ||
                             hash[:customInstructions] || hash['customInstructions'],
        preserved_segment: preserved
      )
    end
  end

  # Status system message (compacting status, permission mode changes)
  class StatusMessage < SystemMessage
    attr_accessor :uuid, :session_id, :status, :permission_mode

    def initialize(subtype:, data:, uuid: nil, session_id: nil, status: nil, permission_mode: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @status = status # "compacting" or nil
      @permission_mode = permission_mode
    end
  end

  # API retry system message
  class APIRetryMessage < SystemMessage
    attr_accessor :uuid, :session_id, :attempt, :max_retries, :retry_delay_ms, :error_status, :error

    def initialize(subtype:, data:, uuid: nil, session_id: nil, attempt: nil, max_retries: nil,
                   retry_delay_ms: nil, error_status: nil, error: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @attempt = attempt
      @max_retries = max_retries
      @retry_delay_ms = retry_delay_ms
      @error_status = error_status
      @error = error
    end
  end

  # Local command output system message
  class LocalCommandOutputMessage < SystemMessage
    attr_accessor :uuid, :session_id, :content

    def initialize(subtype:, data:, uuid: nil, session_id: nil, content: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @content = content
    end
  end

  # Hook started system message
  class HookStartedMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event

    def initialize(subtype:, data:, uuid: nil, session_id: nil, hook_id: nil, hook_name: nil, hook_event: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @hook_id = hook_id
      @hook_name = hook_name
      @hook_event = hook_event
    end
  end

  # Hook progress system message
  class HookProgressMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event, :stdout, :stderr, :output

    def initialize(subtype:, data:, uuid: nil, session_id: nil, hook_id: nil, hook_name: nil,
                   hook_event: nil, stdout: nil, stderr: nil, output: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @hook_id = hook_id
      @hook_name = hook_name
      @hook_event = hook_event
      @stdout = stdout
      @stderr = stderr
      @output = output
    end
  end

  # Hook response system message
  class HookResponseMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event,
                  :output, :stdout, :stderr, :exit_code, :outcome

    def initialize(subtype:, data:, uuid: nil, session_id: nil, hook_id: nil, hook_name: nil,
                   hook_event: nil, output: nil, stdout: nil, stderr: nil, exit_code: nil, outcome: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @hook_id = hook_id
      @hook_name = hook_name
      @hook_event = hook_event
      @output = output
      @stdout = stdout
      @stderr = stderr
      @exit_code = exit_code
      @outcome = outcome # "success", "error", or "cancelled"
    end
  end

  # Session state changed system message
  class SessionStateChangedMessage < SystemMessage
    attr_accessor :uuid, :session_id, :state

    def initialize(subtype:, data:, uuid: nil, session_id: nil, state: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @state = state # "idle", "running", or "requires_action"
    end
  end

  # Files persisted system message
  class FilesPersistedMessage < SystemMessage
    attr_accessor :uuid, :session_id, :files, :failed, :processed_at

    def initialize(subtype:, data:, uuid: nil, session_id: nil, files: nil, failed: nil, processed_at: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @files = files # Array of { filename:, file_id: }
      @failed = failed # Array of { filename:, error: }
      @processed_at = processed_at
    end
  end

  # Elicitation complete system message
  class ElicitationCompleteMessage < SystemMessage
    attr_accessor :uuid, :session_id, :mcp_server_name, :elicitation_id

    def initialize(subtype:, data:, uuid: nil, session_id: nil, mcp_server_name: nil, elicitation_id: nil)
      super(subtype: subtype, data: data)
      @uuid = uuid
      @session_id = session_id
      @mcp_server_name = mcp_server_name
      @elicitation_id = elicitation_id
    end
  end

  # Task lifecycle notification statuses
  TASK_NOTIFICATION_STATUSES = %w[completed failed stopped].freeze

  # Typed usage data for task progress and notifications
  class TaskUsage
    attr_accessor :total_tokens, :tool_uses, :duration_ms

    def initialize(total_tokens: 0, tool_uses: 0, duration_ms: 0)
      @total_tokens = total_tokens
      @tool_uses = tool_uses
      @duration_ms = duration_ms
    end

    def self.from_hash(hash)
      return nil unless hash.is_a?(Hash)

      new(
        total_tokens: hash[:total_tokens] || hash['total_tokens'] || hash[:totalTokens] || hash['totalTokens'] || 0,
        tool_uses: hash[:tool_uses] || hash['tool_uses'] || hash[:toolUses] || hash['toolUses'] || 0,
        duration_ms: hash[:duration_ms] || hash['duration_ms'] || hash[:durationMs] || hash['durationMs'] || 0
      )
    end
  end

  # Task started system message (subagent/background task started)
  class TaskStartedMessage < SystemMessage
    attr_accessor :task_id, :description, :uuid, :session_id, :tool_use_id, :task_type,
                  :workflow_name, :prompt

    def initialize(subtype:, data:, task_id:, description:, uuid:, session_id:,
                   tool_use_id: nil, task_type: nil, workflow_name: nil, prompt: nil)
      super(subtype: subtype, data: data)
      @task_id = task_id
      @description = description
      @uuid = uuid
      @session_id = session_id
      @tool_use_id = tool_use_id
      @task_type = task_type
      @workflow_name = workflow_name
      @prompt = prompt
    end
  end

  # Task progress system message (periodic update from a running task)
  class TaskProgressMessage < SystemMessage
    attr_accessor :task_id, :description, :usage, :uuid, :session_id, :tool_use_id, :last_tool_name, :summary

    def initialize(subtype:, data:, task_id:, description:, usage:, uuid:, session_id:,
                   tool_use_id: nil, last_tool_name: nil, summary: nil)
      super(subtype: subtype, data: data)
      @task_id = task_id
      @description = description
      @usage = usage
      @uuid = uuid
      @session_id = session_id
      @tool_use_id = tool_use_id
      @last_tool_name = last_tool_name
      @summary = summary
    end
  end

  # Task notification system message (task completed/failed/stopped)
  class TaskNotificationMessage < SystemMessage
    attr_accessor :task_id, :status, :output_file, :summary, :uuid, :session_id, :tool_use_id, :usage

    def initialize(subtype:, data:, task_id:, status:, output_file:, summary:, uuid:, session_id:,
                   tool_use_id: nil, usage: nil)
      super(subtype: subtype, data: data)
      @task_id = task_id
      @status = status
      @output_file = output_file
      @summary = summary
      @uuid = uuid
      @session_id = session_id
      @tool_use_id = tool_use_id
      @usage = usage
    end
  end

  # Result message with cost and usage information
  class ResultMessage
    attr_accessor :subtype, :duration_ms, :duration_api_ms, :is_error,
                  :num_turns, :session_id, :stop_reason, :total_cost_usd, :usage,
                  :result, :structured_output, :model_usage, :permission_denials, :errors,
                  :uuid, :fast_mode_state

    def initialize(subtype:, duration_ms:, duration_api_ms:, is_error:,
                   num_turns:, session_id:, stop_reason: nil, total_cost_usd: nil,
                   usage: nil, result: nil, structured_output: nil,
                   model_usage: nil, permission_denials: nil, errors: nil,
                   uuid: nil, fast_mode_state: nil)
      @subtype = subtype
      @duration_ms = duration_ms
      @duration_api_ms = duration_api_ms
      @is_error = is_error
      @num_turns = num_turns
      @session_id = session_id
      @stop_reason = stop_reason
      @total_cost_usd = total_cost_usd
      @usage = usage
      @result = result
      @structured_output = structured_output
      @model_usage = model_usage # Hash of { model_name => usage_data }
      @permission_denials = permission_denials # Array of { tool_name:, tool_use_id:, tool_input: }
      @errors = errors # Array of error strings (present on error subtypes)
      @uuid = uuid
      @fast_mode_state = fast_mode_state # "off", "cooldown", or "on"
    end
  end

  # Stream event for partial message updates
  class StreamEvent
    attr_accessor :uuid, :session_id, :event, :parent_tool_use_id

    def initialize(uuid:, session_id:, event:, parent_tool_use_id: nil)
      @uuid = uuid
      @session_id = session_id
      @event = event
      @parent_tool_use_id = parent_tool_use_id
    end
  end

  # Tool progress message (type: 'tool_progress')
  class ToolProgressMessage
    attr_accessor :uuid, :session_id, :tool_use_id, :tool_name, :parent_tool_use_id,
                  :elapsed_time_seconds, :task_id

    def initialize(uuid: nil, session_id: nil, tool_use_id: nil, tool_name: nil,
                   parent_tool_use_id: nil, elapsed_time_seconds: nil, task_id: nil)
      @uuid = uuid
      @session_id = session_id
      @tool_use_id = tool_use_id
      @tool_name = tool_name
      @parent_tool_use_id = parent_tool_use_id
      @elapsed_time_seconds = elapsed_time_seconds
      @task_id = task_id
    end
  end

  # Auth status message (type: 'auth_status')
  class AuthStatusMessage
    attr_accessor :uuid, :session_id, :is_authenticating, :output, :error

    def initialize(uuid: nil, session_id: nil, is_authenticating: nil, output: nil, error: nil)
      @uuid = uuid
      @session_id = session_id
      @is_authenticating = is_authenticating
      @output = output
      @error = error
    end
  end

  # Tool use summary message (type: 'tool_use_summary')
  class ToolUseSummaryMessage
    attr_accessor :uuid, :session_id, :summary, :preceding_tool_use_ids

    def initialize(uuid: nil, session_id: nil, summary: nil, preceding_tool_use_ids: nil)
      @uuid = uuid
      @session_id = session_id
      @summary = summary
      @preceding_tool_use_ids = preceding_tool_use_ids
    end
  end

  # Prompt suggestion message (type: 'prompt_suggestion')
  class PromptSuggestionMessage
    attr_accessor :uuid, :session_id, :suggestion

    def initialize(uuid: nil, session_id: nil, suggestion: nil)
      @uuid = uuid
      @session_id = session_id
      @suggestion = suggestion
    end
  end

  # Type constants for rate limit statuses
  RATE_LIMIT_STATUSES = %w[allowed allowed_warning rejected].freeze

  # Type constants for rate limit types
  RATE_LIMIT_TYPES = %w[five_hour seven_day seven_day_opus seven_day_sonnet overage].freeze

  # Rate limit info with typed fields
  class RateLimitInfo
    attr_accessor :status, :resets_at, :rate_limit_type, :utilization,
                  :overage_status, :overage_resets_at, :overage_disabled_reason, :raw

    def initialize(status:, resets_at: nil, rate_limit_type: nil, utilization: nil,
                   overage_status: nil, overage_resets_at: nil, overage_disabled_reason: nil, raw: {})
      @status = status
      @resets_at = resets_at
      @rate_limit_type = rate_limit_type
      @utilization = utilization
      @overage_status = overage_status
      @overage_resets_at = overage_resets_at
      @overage_disabled_reason = overage_disabled_reason
      @raw = raw
    end
  end

  # Rate limit event emitted when rate limit info changes
  class RateLimitEvent
    attr_accessor :rate_limit_info, :uuid, :session_id

    def initialize(rate_limit_info:, uuid:, session_id:, raw_data: nil)
      @rate_limit_info = rate_limit_info
      @uuid = uuid
      @session_id = session_id
      @raw_data = raw_data
    end

    # Backward-compatible accessor returning the full raw event payload
    def data
      @raw_data || {}
    end
  end

  # Thinking configuration types

  # Adaptive thinking: uses a default budget of 32000 tokens
  class ThinkingConfigAdaptive
    attr_accessor :type

    def initialize
      @type = 'adaptive'
    end
  end

  # Enabled thinking: uses a user-specified budget
  class ThinkingConfigEnabled
    attr_accessor :type, :budget_tokens

    def initialize(budget_tokens:)
      @type = 'enabled'
      @budget_tokens = budget_tokens
    end
  end

  # Disabled thinking: sets thinking tokens to 0
  class ThinkingConfigDisabled
    attr_accessor :type

    def initialize
      @type = 'disabled'
    end
  end

  # Agent definition configuration
  class AgentDefinition
    attr_accessor :description, :prompt, :tools, :model, :skills, :memory, :mcp_servers

    def initialize(description:, prompt:, tools: nil, model: nil, skills: nil, memory: nil, mcp_servers: nil)
      @description = description
      @prompt = prompt
      @tools = tools
      @model = model
      @skills = skills # Array of skill names
      @memory = memory # One of: 'user', 'project', 'local'
      @mcp_servers = mcp_servers # Array of server names or config hashes
    end
  end

  # Permission rule value
  class PermissionRuleValue
    attr_accessor :tool_name, :rule_content

    def initialize(tool_name:, rule_content: nil)
      @tool_name = tool_name
      @rule_content = rule_content
    end
  end

  # Permission update configuration
  class PermissionUpdate
    attr_accessor :type, :rules, :behavior, :mode, :directories, :destination

    def initialize(type:, rules: nil, behavior: nil, mode: nil, directories: nil, destination: nil)
      @type = type
      @rules = rules
      @behavior = behavior
      @mode = mode
      @directories = directories
      @destination = destination
    end

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
  class ToolPermissionContext
    attr_accessor :signal, :suggestions

    def initialize(signal: nil, suggestions: [])
      @signal = signal
      @suggestions = suggestions
    end
  end

  # Permission results
  class PermissionResultAllow
    attr_accessor :behavior, :updated_input, :updated_permissions

    def initialize(updated_input: nil, updated_permissions: nil)
      @behavior = 'allow'
      @updated_input = updated_input
      @updated_permissions = updated_permissions
    end
  end

  class PermissionResultDeny
    attr_accessor :behavior, :message, :interrupt

    def initialize(message: '', interrupt: false)
      @behavior = 'deny'
      @message = message
      @interrupt = interrupt
    end
  end

  # Hook matcher configuration
  class HookMatcher
    attr_accessor :matcher, :hooks, :timeout

    def initialize(matcher: nil, hooks: [], timeout: nil)
      @matcher = matcher
      @hooks = hooks
      @timeout = timeout # Timeout in seconds for hook execution
    end
  end

  # Hook context passed to hook callbacks
  class HookContext
    attr_accessor :signal

    def initialize(signal: nil)
      @signal = signal
    end
  end

  # Base hook input with common fields
  class BaseHookInput
    attr_accessor :session_id, :transcript_path, :cwd, :permission_mode

    def initialize(session_id: nil, transcript_path: nil, cwd: nil, permission_mode: nil)
      @session_id = session_id
      @transcript_path = transcript_path
      @cwd = cwd
      @permission_mode = permission_mode
    end
  end

  # PreToolUse hook input
  class PreToolUseHookInput < BaseHookInput
    attr_accessor :hook_event_name, :tool_name, :tool_input, :tool_use_id, :agent_id, :agent_type

    def initialize(hook_event_name: 'PreToolUse', tool_name: nil, tool_input: nil, tool_use_id: nil,
                   agent_id: nil, agent_type: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @tool_name = tool_name
      @tool_input = tool_input
      @tool_use_id = tool_use_id
      @agent_id = agent_id
      @agent_type = agent_type
    end
  end

  # PostToolUse hook input
  class PostToolUseHookInput < BaseHookInput
    attr_accessor :hook_event_name, :tool_name, :tool_input, :tool_response, :tool_use_id, :agent_id, :agent_type

    def initialize(hook_event_name: 'PostToolUse', tool_name: nil, tool_input: nil, tool_response: nil,
                   tool_use_id: nil, agent_id: nil, agent_type: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @tool_name = tool_name
      @tool_input = tool_input
      @tool_response = tool_response
      @tool_use_id = tool_use_id
      @agent_id = agent_id
      @agent_type = agent_type
    end
  end

  # UserPromptSubmit hook input
  class UserPromptSubmitHookInput < BaseHookInput
    attr_accessor :hook_event_name, :prompt

    def initialize(hook_event_name: 'UserPromptSubmit', prompt: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @prompt = prompt
    end
  end

  # Stop hook input
  class StopHookInput < BaseHookInput
    attr_accessor :hook_event_name, :stop_hook_active, :last_assistant_message

    def initialize(hook_event_name: 'Stop', stop_hook_active: false, last_assistant_message: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @stop_hook_active = stop_hook_active
      @last_assistant_message = last_assistant_message
    end
  end

  # SubagentStop hook input
  class SubagentStopHookInput < BaseHookInput
    attr_accessor :hook_event_name, :stop_hook_active, :agent_id, :agent_transcript_path, :agent_type,
                  :last_assistant_message

    def initialize(hook_event_name: 'SubagentStop', stop_hook_active: false, agent_id: nil,
                   agent_transcript_path: nil, agent_type: nil, last_assistant_message: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @stop_hook_active = stop_hook_active
      @agent_id = agent_id
      @agent_transcript_path = agent_transcript_path
      @agent_type = agent_type
      @last_assistant_message = last_assistant_message
    end
  end

  # PostToolUseFailure hook input
  class PostToolUseFailureHookInput < BaseHookInput
    attr_accessor :hook_event_name, :tool_name, :tool_input, :tool_use_id, :error, :is_interrupt,
                  :agent_id, :agent_type

    def initialize(hook_event_name: 'PostToolUseFailure', tool_name: nil, tool_input: nil, tool_use_id: nil,
                   error: nil, is_interrupt: nil, agent_id: nil, agent_type: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @tool_name = tool_name
      @tool_input = tool_input
      @tool_use_id = tool_use_id
      @error = error
      @is_interrupt = is_interrupt
      @agent_id = agent_id
      @agent_type = agent_type
    end
  end

  # Notification hook input
  class NotificationHookInput < BaseHookInput
    attr_accessor :hook_event_name, :message, :title, :notification_type

    def initialize(hook_event_name: 'Notification', message: nil, title: nil, notification_type: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @message = message
      @title = title
      @notification_type = notification_type
    end
  end

  # SubagentStart hook input
  class SubagentStartHookInput < BaseHookInput
    attr_accessor :hook_event_name, :agent_id, :agent_type

    def initialize(hook_event_name: 'SubagentStart', agent_id: nil, agent_type: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @agent_id = agent_id
      @agent_type = agent_type
    end
  end

  # PermissionRequest hook input
  class PermissionRequestHookInput < BaseHookInput
    attr_accessor :hook_event_name, :tool_name, :tool_input, :permission_suggestions, :agent_id, :agent_type

    def initialize(hook_event_name: 'PermissionRequest', tool_name: nil, tool_input: nil, permission_suggestions: nil,
                   agent_id: nil, agent_type: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @tool_name = tool_name
      @tool_input = tool_input
      @permission_suggestions = permission_suggestions
      @agent_id = agent_id
      @agent_type = agent_type
    end
  end

  # PreCompact hook input
  class PreCompactHookInput < BaseHookInput
    attr_accessor :hook_event_name, :trigger, :custom_instructions

    def initialize(hook_event_name: 'PreCompact', trigger: nil, custom_instructions: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @trigger = trigger
      @custom_instructions = custom_instructions
    end
  end

  # SessionStart hook input
  class SessionStartHookInput < BaseHookInput
    attr_accessor :hook_event_name, :source, :agent_type, :model

    def initialize(hook_event_name: 'SessionStart', source: nil, agent_type: nil, model: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @source = source # "startup", "resume", "clear", "compact"
      @agent_type = agent_type
      @model = model
    end
  end

  # SessionEnd hook input
  class SessionEndHookInput < BaseHookInput
    attr_accessor :hook_event_name, :reason

    def initialize(hook_event_name: 'SessionEnd', reason: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @reason = reason
    end
  end

  # Setup hook input
  class SetupHookInput < BaseHookInput
    attr_accessor :hook_event_name, :trigger

    def initialize(hook_event_name: 'Setup', trigger: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @trigger = trigger # "init" or "maintenance"
    end
  end

  # TeammateIdle hook input
  class TeammateIdleHookInput < BaseHookInput
    attr_accessor :hook_event_name, :teammate_name, :team_name

    def initialize(hook_event_name: 'TeammateIdle', teammate_name: nil, team_name: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @teammate_name = teammate_name
      @team_name = team_name
    end
  end

  # TaskCompleted hook input
  class TaskCompletedHookInput < BaseHookInput
    attr_accessor :hook_event_name, :task_id, :task_subject, :task_description, :teammate_name, :team_name

    def initialize(hook_event_name: 'TaskCompleted', task_id: nil, task_subject: nil, task_description: nil,
                   teammate_name: nil, team_name: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @task_id = task_id
      @task_subject = task_subject
      @task_description = task_description
      @teammate_name = teammate_name
      @team_name = team_name
    end
  end

  # ConfigChange hook input
  class ConfigChangeHookInput < BaseHookInput
    attr_accessor :hook_event_name, :source, :file_path

    def initialize(hook_event_name: 'ConfigChange', source: nil, file_path: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @source = source # "user_settings", "project_settings", "local_settings", "policy_settings", "skills"
      @file_path = file_path
    end
  end

  # WorktreeCreate hook input
  class WorktreeCreateHookInput < BaseHookInput
    attr_accessor :hook_event_name, :name

    def initialize(hook_event_name: 'WorktreeCreate', name: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @name = name
    end
  end

  # WorktreeRemove hook input
  class WorktreeRemoveHookInput < BaseHookInput
    attr_accessor :hook_event_name, :worktree_path

    def initialize(hook_event_name: 'WorktreeRemove', worktree_path: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @worktree_path = worktree_path
    end
  end

  # StopFailure hook input
  class StopFailureHookInput < BaseHookInput
    attr_accessor :hook_event_name, :error, :error_details, :last_assistant_message

    def initialize(hook_event_name: 'StopFailure', error: nil, error_details: nil,
                   last_assistant_message: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @error = error
      @error_details = error_details
      @last_assistant_message = last_assistant_message
    end
  end

  # PostCompact hook input
  class PostCompactHookInput < BaseHookInput
    attr_accessor :hook_event_name, :trigger, :compact_summary

    def initialize(hook_event_name: 'PostCompact', trigger: nil, compact_summary: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @trigger = trigger # "manual" or "auto"
      @compact_summary = compact_summary
    end
  end

  # PermissionDenied hook input
  class PermissionDeniedHookInput < BaseHookInput
    attr_accessor :hook_event_name, :tool_name, :tool_input, :tool_use_id, :reason, :agent_id, :agent_type

    def initialize(hook_event_name: 'PermissionDenied', tool_name: nil, tool_input: nil, tool_use_id: nil,
                   reason: nil, agent_id: nil, agent_type: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @tool_name = tool_name
      @tool_input = tool_input
      @tool_use_id = tool_use_id
      @reason = reason
      @agent_id = agent_id
      @agent_type = agent_type
    end
  end

  # TaskCreated hook input
  class TaskCreatedHookInput < BaseHookInput
    attr_accessor :hook_event_name, :task_id, :task_subject, :task_description, :teammate_name, :team_name

    def initialize(hook_event_name: 'TaskCreated', task_id: nil, task_subject: nil, task_description: nil,
                   teammate_name: nil, team_name: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @task_id = task_id
      @task_subject = task_subject
      @task_description = task_description
      @teammate_name = teammate_name
      @team_name = team_name
    end
  end

  # Elicitation hook input
  class ElicitationHookInput < BaseHookInput
    attr_accessor :hook_event_name, :mcp_server_name, :message, :mode, :url,
                  :elicitation_id, :requested_schema

    def initialize(hook_event_name: 'Elicitation', mcp_server_name: nil, message: nil, mode: nil,
                   url: nil, elicitation_id: nil, requested_schema: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @mcp_server_name = mcp_server_name
      @message = message
      @mode = mode
      @url = url
      @elicitation_id = elicitation_id
      @requested_schema = requested_schema
    end
  end

  # ElicitationResult hook input
  class ElicitationResultHookInput < BaseHookInput
    attr_accessor :hook_event_name, :mcp_server_name, :elicitation_id, :mode, :action, :content

    def initialize(hook_event_name: 'ElicitationResult', mcp_server_name: nil, elicitation_id: nil,
                   mode: nil, action: nil, content: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @mcp_server_name = mcp_server_name
      @elicitation_id = elicitation_id
      @mode = mode
      @action = action
      @content = content
    end
  end

  # InstructionsLoaded hook input
  class InstructionsLoadedHookInput < BaseHookInput
    attr_accessor :hook_event_name, :file_path, :memory_type, :load_reason, :globs, :trigger_file_path

    def initialize(hook_event_name: 'InstructionsLoaded', file_path: nil, memory_type: nil,
                   load_reason: nil, globs: nil, trigger_file_path: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @file_path = file_path
      @memory_type = memory_type
      @load_reason = load_reason
      @globs = globs
      @trigger_file_path = trigger_file_path
    end
  end

  # CwdChanged hook input
  class CwdChangedHookInput < BaseHookInput
    attr_accessor :hook_event_name, :old_cwd, :new_cwd

    def initialize(hook_event_name: 'CwdChanged', old_cwd: nil, new_cwd: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @old_cwd = old_cwd
      @new_cwd = new_cwd
    end
  end

  # FileChanged hook input
  class FileChangedHookInput < BaseHookInput
    attr_accessor :hook_event_name, :file_path, :event

    def initialize(hook_event_name: 'FileChanged', file_path: nil, event: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @file_path = file_path
      @event = event # "change", "add", or "unlink"
    end
  end

  # Setup hook specific output
  class SetupHookSpecificOutput
    attr_accessor :hook_event_name, :additional_context

    def initialize(additional_context: nil)
      @hook_event_name = 'Setup'
      @additional_context = additional_context
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PreToolUse hook specific output
  class PreToolUseHookSpecificOutput
    attr_accessor :hook_event_name, :permission_decision, :permission_decision_reason,
                  :updated_input, :additional_context

    def initialize(permission_decision: nil, permission_decision_reason: nil, updated_input: nil,
                   additional_context: nil)
      @hook_event_name = 'PreToolUse'
      @permission_decision = permission_decision # 'allow', 'deny', or 'ask'
      @permission_decision_reason = permission_decision_reason
      @updated_input = updated_input
      @additional_context = additional_context
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
  class PostToolUseHookSpecificOutput
    attr_accessor :hook_event_name, :additional_context, :updated_mcp_tool_output

    def initialize(additional_context: nil, updated_mcp_tool_output: nil)
      @hook_event_name = 'PostToolUse'
      @additional_context = additional_context
      @updated_mcp_tool_output = updated_mcp_tool_output
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result[:updatedMCPToolOutput] = @updated_mcp_tool_output if @updated_mcp_tool_output
      result
    end
  end

  # PostToolUseFailure hook specific output
  class PostToolUseFailureHookSpecificOutput
    attr_accessor :hook_event_name, :additional_context

    def initialize(additional_context: nil)
      @hook_event_name = 'PostToolUseFailure'
      @additional_context = additional_context
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # UserPromptSubmit hook specific output
  class UserPromptSubmitHookSpecificOutput
    attr_accessor :hook_event_name, :additional_context

    def initialize(additional_context: nil)
      @hook_event_name = 'UserPromptSubmit'
      @additional_context = additional_context
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # Notification hook specific output
  class NotificationHookSpecificOutput
    attr_accessor :hook_event_name, :additional_context

    def initialize(additional_context: nil)
      @hook_event_name = 'Notification'
      @additional_context = additional_context
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # SubagentStart hook specific output
  class SubagentStartHookSpecificOutput
    attr_accessor :hook_event_name, :additional_context

    def initialize(additional_context: nil)
      @hook_event_name = 'SubagentStart'
      @additional_context = additional_context
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PermissionRequest hook specific output
  class PermissionRequestHookSpecificOutput
    attr_accessor :hook_event_name, :decision

    def initialize(decision: nil)
      @hook_event_name = 'PermissionRequest'
      @decision = decision
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:decision] = @decision if @decision
      result
    end
  end

  # SessionStart hook specific output
  class SessionStartHookSpecificOutput
    attr_accessor :hook_event_name, :additional_context

    def initialize(additional_context: nil)
      @hook_event_name = 'SessionStart'
      @additional_context = additional_context
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PermissionDenied hook specific output
  class PermissionDeniedHookSpecificOutput
    attr_accessor :hook_event_name, :retry

    def initialize(retry_: false)
      @hook_event_name = 'PermissionDenied'
      @retry = retry_
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:retry] = @retry unless @retry.nil?
      result
    end
  end

  # CwdChanged hook specific output
  class CwdChangedHookSpecificOutput
    attr_accessor :hook_event_name, :watch_paths

    def initialize(watch_paths: nil)
      @hook_event_name = 'CwdChanged'
      @watch_paths = watch_paths
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:watchPaths] = @watch_paths if @watch_paths
      result
    end
  end

  # FileChanged hook specific output
  class FileChangedHookSpecificOutput
    attr_accessor :hook_event_name, :watch_paths

    def initialize(watch_paths: nil)
      @hook_event_name = 'FileChanged'
      @watch_paths = watch_paths
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:watchPaths] = @watch_paths if @watch_paths
      result
    end
  end

  # Async hook JSON output
  class AsyncHookJSONOutput
    attr_accessor :async, :async_timeout

    def initialize(async: true, async_timeout: nil)
      @async = async
      @async_timeout = async_timeout
    end

    def to_h
      result = { async: @async }
      result[:asyncTimeout] = @async_timeout if @async_timeout
      result
    end
  end

  # Sync hook JSON output
  class SyncHookJSONOutput
    attr_accessor :continue, :suppress_output, :stop_reason, :decision,
                  :system_message, :reason, :hook_specific_output

    def initialize(continue: true, suppress_output: false, stop_reason: nil, decision: nil,
                   system_message: nil, reason: nil, hook_specific_output: nil)
      @continue = continue
      @suppress_output = suppress_output
      @stop_reason = stop_reason
      @decision = decision
      @system_message = system_message
      @reason = reason
      @hook_specific_output = hook_specific_output
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
  class McpServerInfo
    attr_accessor :name, :version

    def initialize(name:, version: nil)
      @name = name
      @version = version
    end
  end

  # MCP tool annotation hints
  class McpToolAnnotations
    attr_accessor :read_only, :destructive, :open_world

    def initialize(read_only: nil, destructive: nil, open_world: nil)
      @read_only = read_only
      @destructive = destructive
      @open_world = open_world
    end

    def self.parse(data)
      return nil unless data

      new(
        read_only: data.key?(:readOnly) ? data[:readOnly] : data[:read_only],
        destructive: data[:destructive],
        open_world: data.key?(:openWorld) ? data[:openWorld] : data[:open_world]
      )
    end
  end

  # MCP tool info (name, description, annotations)
  class McpToolInfo
    attr_accessor :name, :description, :annotations

    def initialize(name:, description: nil, annotations: nil)
      @name = name
      @description = description
      @annotations = annotations
    end

    def self.parse(data)
      new(
        name: data[:name],
        description: data[:description],
        annotations: McpToolAnnotations.parse(data[:annotations])
      )
    end
  end

  # Output-only serializable version of McpSdkServerConfig (without live instance)
  # Returned in MCP status responses
  class McpSdkServerConfigStatus
    attr_accessor :type, :name

    def initialize(type: 'sdk', name:)
      @type = type
      @name = name
    end

    def to_h
      { type: @type, name: @name }
    end
  end

  # Claude.ai proxy MCP server config
  # Output-only type that appears in status responses for servers proxied through Claude.ai
  class McpClaudeAIProxyServerConfig
    attr_accessor :type, :url, :id

    def initialize(type: 'claudeai-proxy', url:, id:)
      @type = type
      @url = url
      @id = id
    end

    def to_h
      { type: @type, url: @url, id: @id }
    end
  end

  # Status of a single MCP server connection
  class McpServerStatus
    attr_accessor :name, :status, :server_info, :error, :config, :scope, :tools

    def initialize(name:, status:, server_info: nil, error: nil, config: nil, scope: nil, tools: nil)
      @name = name
      @status = status
      @server_info = server_info
      @error = error
      @config = config
      @scope = scope
      @tools = tools
    end

    def self.parse(data)
      server_info = (McpServerInfo.new(name: data[:serverInfo][:name], version: data[:serverInfo][:version]) if data[:serverInfo])
      tools = data[:tools]&.map { |t| McpToolInfo.parse(t) }
      config = parse_config(data[:config])

      new(
        name: data[:name],
        status: data[:status],
        server_info: server_info,
        error: data[:error],
        config: config,
        scope: data[:scope],
        tools: tools
      )
    end

    def self.parse_config(config)
      return config unless config.is_a?(Hash) && config[:type]

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
  class McpStatusResponse
    attr_accessor :mcp_servers

    def initialize(mcp_servers:)
      @mcp_servers = mcp_servers
    end

    def self.parse(data)
      servers = (data[:mcpServers] || []).map { |s| McpServerStatus.parse(s) }
      new(mcp_servers: servers)
    end
  end

  # MCP Server configurations
  class McpStdioServerConfig
    attr_accessor :type, :command, :args, :env

    def initialize(command:, args: nil, env: nil, type: 'stdio')
      @type = type
      @command = command
      @args = args
      @env = env
    end

    def to_h
      result = { type: @type, command: @command }
      result[:args] = @args if @args
      result[:env] = @env if @env
      result
    end
  end

  class McpSSEServerConfig
    attr_accessor :type, :url, :headers

    def initialize(url:, headers: nil)
      @type = 'sse'
      @url = url
      @headers = headers
    end

    def to_h
      result = { type: @type, url: @url }
      result[:headers] = @headers if @headers
      result
    end
  end

  class McpHttpServerConfig
    attr_accessor :type, :url, :headers

    def initialize(url:, headers: nil)
      @type = 'http'
      @url = url
      @headers = headers
    end

    def to_h
      result = { type: @type, url: @url }
      result[:headers] = @headers if @headers
      result
    end
  end

  class McpSdkServerConfig
    attr_accessor :type, :name, :instance

    def initialize(name:, instance:)
      @type = 'sdk'
      @name = name
      @instance = instance
    end

    def to_h
      { type: @type, name: @name, instance: @instance }
    end
  end

  # SDK Plugin configuration
  class SdkPluginConfig
    attr_accessor :type, :path

    def initialize(path:, type: 'local')
      raise ArgumentError, "unsupported plugin type: #{type}" unless %w[local plugin].include?(type)

      @type = 'local'
      @path = path
    end

    def to_h
      { type: @type, path: @path }
    end
  end

  # Sandbox network configuration
  class SandboxNetworkConfig
    attr_accessor :allowed_domains, :allow_managed_domains_only,
                  :allow_unix_sockets, :allow_all_unix_sockets, :allow_local_binding,
                  :http_proxy_port, :socks_proxy_port

    def initialize(
      allowed_domains: nil,
      allow_managed_domains_only: nil,
      allow_unix_sockets: nil,
      allow_all_unix_sockets: nil,
      allow_local_binding: nil,
      http_proxy_port: nil,
      socks_proxy_port: nil
    )
      @allowed_domains = allowed_domains # Array of domain strings
      @allow_managed_domains_only = allow_managed_domains_only
      @allow_unix_sockets = allow_unix_sockets # macOS only: Array of socket paths
      @allow_all_unix_sockets = allow_all_unix_sockets
      @allow_local_binding = allow_local_binding
      @http_proxy_port = http_proxy_port
      @socks_proxy_port = socks_proxy_port
    end

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
  class SandboxFilesystemConfig
    attr_accessor :allow_write, :deny_write, :deny_read, :allow_read, :allow_managed_read_paths_only

    def initialize(allow_write: nil, deny_write: nil, deny_read: nil, allow_read: nil,
                   allow_managed_read_paths_only: nil)
      @allow_write = allow_write # Array of paths to allow writing
      @deny_write = deny_write   # Array of paths to deny writing
      @deny_read = deny_read     # Array of paths to deny reading
      @allow_read = allow_read   # Array of paths to re-allow reading within denyRead
      @allow_managed_read_paths_only = allow_managed_read_paths_only
    end

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
  class SandboxSettings
    attr_accessor :enabled, :fail_if_unavailable, :auto_allow_bash_if_sandboxed,
                  :excluded_commands, :allow_unsandboxed_commands, :network, :filesystem,
                  :ignore_violations, :enable_weaker_nested_sandbox,
                  :enable_weaker_network_isolation, :ripgrep

    def initialize(
      enabled: nil,
      fail_if_unavailable: nil,
      auto_allow_bash_if_sandboxed: nil,
      excluded_commands: nil,
      allow_unsandboxed_commands: nil,
      network: nil,
      filesystem: nil,
      ignore_violations: nil,
      enable_weaker_nested_sandbox: nil,
      enable_weaker_network_isolation: nil,
      ripgrep: nil
    )
      @enabled = enabled
      @fail_if_unavailable = fail_if_unavailable
      @auto_allow_bash_if_sandboxed = auto_allow_bash_if_sandboxed
      @excluded_commands = excluded_commands # Array of commands to exclude
      @allow_unsandboxed_commands = allow_unsandboxed_commands
      @network = network # SandboxNetworkConfig instance
      @filesystem = filesystem # SandboxFilesystemConfig instance
      @ignore_violations = ignore_violations # Hash of { category => [patterns] }
      @enable_weaker_nested_sandbox = enable_weaker_nested_sandbox
      @enable_weaker_network_isolation = enable_weaker_network_isolation # macOS only
      @ripgrep = ripgrep # Hash with :command and optional :args
    end

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

  # System prompt preset configuration
  class SystemPromptPreset
    attr_accessor :type, :preset, :append

    def initialize(preset:, append: nil)
      @type = 'preset'
      @preset = preset
      @append = append
    end

    def to_h
      result = { type: @type, preset: @preset }
      result[:append] = @append if @append
      result
    end
  end

  # Tools preset configuration
  class ToolsPreset
    attr_accessor :type, :preset

    def initialize(preset:)
      @type = 'preset'
      @preset = preset
    end

    def to_h
      { type: @type, preset: @preset }
    end
  end

  # Claude Agent Options for configuring queries
  class ClaudeAgentOptions
    attr_accessor :allowed_tools, :system_prompt, :mcp_servers, :permission_mode,
                  :continue_conversation, :resume, :max_turns, :disallowed_tools,
                  :model, :permission_prompt_tool_name, :cwd, :cli_path, :settings,
                  :add_dirs, :env, :extra_args, :max_buffer_size, :stderr,
                  :can_use_tool, :hooks, :user, :include_partial_messages,
                  :fork_session, :agents, :setting_sources,
                  :output_format, :max_budget_usd, :max_thinking_tokens,
                  :fallback_model, :plugins, :debug_stderr,
                  :betas, :tools, :sandbox, :enable_file_checkpointing, :append_allowed_tools,
                  :thinking, :effort, :bare, :observers

    # Non-nil defaults for options that need them.
    # Keys absent from here default to nil.
    OPTION_DEFAULTS = {
      allowed_tools: [], disallowed_tools: [], add_dirs: [],
      mcp_servers: {}, env: {}, extra_args: {},
      continue_conversation: false, include_partial_messages: false,
      fork_session: false, enable_file_checkpointing: false,
      observers: []
    }.freeze

    # Valid option names derived from attr_accessor declarations.
    VALID_OPTIONS = instance_methods.grep(/=\z/).map { |m| m.to_s.chomp('=').to_sym }.freeze

    # Using **kwargs lets us distinguish "caller passed allowed_tools: []"
    # from "caller omitted allowed_tools" — critical for correct merge with
    # configured defaults.
    def initialize(**kwargs)
      unknown = kwargs.keys - VALID_OPTIONS
      raise ArgumentError, "unknown keyword#{'s' if unknown.size > 1}: #{unknown.join(', ')}" if unknown.any?

      merged = merge_with_defaults(kwargs)
      OPTION_DEFAULTS.merge(merged).each do |key, value|
        instance_variable_set(:"@#{key}", value)
      end
    end

    def dup_with(**changes)
      new_options = self.dup
      changes.each { |key, value| new_options.send(:"#{key}=", value) }
      new_options
    end

    private

    # Merge caller-provided kwargs with configured defaults.
    # Only keys the caller explicitly passed are treated as overrides;
    # method-signature defaults ([], {}, false) are NOT in kwargs unless the caller wrote them.
    def merge_with_defaults(kwargs)
      return OPTION_DEFAULTS.merge(kwargs) unless defined?(ClaudeAgentSDK) && ClaudeAgentSDK.respond_to?(:default_options)

      defaults = ClaudeAgentSDK.default_options
      return OPTION_DEFAULTS.merge(kwargs) unless defaults.any?

      # Start from configured defaults (deep dup hashes to prevent mutation)
      result = defaults.transform_values { |v| v.is_a?(Hash) ? v.dup : v }
      kwargs.each do |key, value|
        default_val = result[key]
        result[key] = if value.nil?
                        default_val # nil means "no preference" — keep the configured default
                      elsif default_val.is_a?(Hash) && value.is_a?(Hash)
                        default_val.merge(value)
                      else
                        value
                      end
      end
      OPTION_DEFAULTS.merge(result)
    end
  end

  # SDK MCP Tool definition
  class SdkMcpTool
    attr_accessor :name, :description, :input_schema, :handler, :annotations

    def initialize(name:, description:, input_schema:, handler:, annotations: nil)
      @name = name
      @description = description
      @input_schema = input_schema
      @handler = handler
      @annotations = annotations # MCP tool annotations (e.g., { title: '...', readOnlyHint: true })
    end
  end

  # SDK MCP Resource definition
  class SdkMcpResource
    attr_accessor :uri, :name, :description, :mime_type, :reader

    def initialize(uri:, name:, description: nil, mime_type: nil, reader:)
      @uri = uri
      @name = name
      @description = description
      @mime_type = mime_type
      @reader = reader
    end
  end

  # SDK MCP Prompt definition
  class SdkMcpPrompt
    attr_accessor :name, :description, :arguments, :generator

    def initialize(name:, description: nil, arguments: nil, generator:)
      @name = name
      @description = description
      @arguments = arguments
      @generator = generator
    end
  end
end
