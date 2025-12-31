# frozen_string_literal: true

module ClaudeAgentSDK
  # Type constants for permission modes
  PERMISSION_MODES = %w[default acceptEdits plan bypassPermissions].freeze

  # Type constants for setting sources
  SETTING_SOURCES = %w[user project local].freeze

  # Type constants for permission update destinations
  PERMISSION_UPDATE_DESTINATIONS = %w[userSettings projectSettings localSettings session].freeze

  # Type constants for permission behaviors
  PERMISSION_BEHAVIORS = %w[allow deny ask].freeze

  # Type constants for hook events
  HOOK_EVENTS = %w[PreToolUse PostToolUse UserPromptSubmit Stop SubagentStop PreCompact].freeze

  # Type constants for assistant message errors
  ASSISTANT_MESSAGE_ERRORS = %w[authentication_failed billing_error rate_limit invalid_request server_error unknown].freeze

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

  # Message Types

  # User message
  class UserMessage
    attr_accessor :content, :uuid, :parent_tool_use_id

    def initialize(content:, uuid: nil, parent_tool_use_id: nil)
      @content = content
      @uuid = uuid # Unique identifier for rewind support (v0.1.17+)
      @parent_tool_use_id = parent_tool_use_id
    end
  end

  # Assistant message with content blocks
  class AssistantMessage
    attr_accessor :content, :model, :parent_tool_use_id, :error

    def initialize(content:, model:, parent_tool_use_id: nil, error: nil)
      @content = content
      @model = model
      @parent_tool_use_id = parent_tool_use_id
      @error = error # One of: authentication_failed, billing_error, rate_limit, invalid_request, server_error, unknown
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

  # Result message with cost and usage information
  class ResultMessage
    attr_accessor :subtype, :duration_ms, :duration_api_ms, :is_error,
                  :num_turns, :session_id, :total_cost_usd, :usage, :result, :structured_output

    def initialize(subtype:, duration_ms:, duration_api_ms:, is_error:,
                   num_turns:, session_id:, total_cost_usd: nil, usage: nil, result: nil, structured_output: nil)
      @subtype = subtype
      @duration_ms = duration_ms
      @duration_api_ms = duration_api_ms
      @is_error = is_error
      @num_turns = num_turns
      @session_id = session_id
      @total_cost_usd = total_cost_usd
      @usage = usage
      @result = result
      @structured_output = structured_output # Structured output when output_format is specified
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

  # Agent definition configuration
  class AgentDefinition
    attr_accessor :description, :prompt, :tools, :model

    def initialize(description:, prompt:, tools: nil, model: nil)
      @description = description
      @prompt = prompt
      @tools = tools
      @model = model
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
    attr_accessor :hook_event_name, :tool_name, :tool_input

    def initialize(hook_event_name: 'PreToolUse', tool_name: nil, tool_input: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @tool_name = tool_name
      @tool_input = tool_input
    end
  end

  # PostToolUse hook input
  class PostToolUseHookInput < BaseHookInput
    attr_accessor :hook_event_name, :tool_name, :tool_input, :tool_response

    def initialize(hook_event_name: 'PostToolUse', tool_name: nil, tool_input: nil, tool_response: nil, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @tool_name = tool_name
      @tool_input = tool_input
      @tool_response = tool_response
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
    attr_accessor :hook_event_name, :stop_hook_active

    def initialize(hook_event_name: 'Stop', stop_hook_active: false, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @stop_hook_active = stop_hook_active
    end
  end

  # SubagentStop hook input
  class SubagentStopHookInput < BaseHookInput
    attr_accessor :hook_event_name, :stop_hook_active

    def initialize(hook_event_name: 'SubagentStop', stop_hook_active: false, **base_args)
      super(**base_args)
      @hook_event_name = hook_event_name
      @stop_hook_active = stop_hook_active
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

  # PreToolUse hook specific output
  class PreToolUseHookSpecificOutput
    attr_accessor :hook_event_name, :permission_decision, :permission_decision_reason, :updated_input

    def initialize(permission_decision: nil, permission_decision_reason: nil, updated_input: nil)
      @hook_event_name = 'PreToolUse'
      @permission_decision = permission_decision # 'allow', 'deny', or 'ask'
      @permission_decision_reason = permission_decision_reason
      @updated_input = updated_input
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:permissionDecision] = @permission_decision if @permission_decision
      result[:permissionDecisionReason] = @permission_decision_reason if @permission_decision_reason
      result[:updatedInput] = @updated_input if @updated_input
      result
    end
  end

  # PostToolUse hook specific output
  class PostToolUseHookSpecificOutput
    attr_accessor :hook_event_name, :additional_context

    def initialize(additional_context: nil)
      @hook_event_name = 'PostToolUse'
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

    def initialize(path:)
      @type = 'plugin'
      @path = path
    end

    def to_h
      { type: @type, path: @path }
    end
  end

  # Sandbox network configuration
  class SandboxNetworkConfig
    attr_accessor :allow_unix_sockets, :allow_all_unix_sockets, :allow_local_binding,
                  :http_proxy_port, :socks_proxy_port

    def initialize(
      allow_unix_sockets: nil,
      allow_all_unix_sockets: nil,
      allow_local_binding: nil,
      http_proxy_port: nil,
      socks_proxy_port: nil
    )
      @allow_unix_sockets = allow_unix_sockets
      @allow_all_unix_sockets = allow_all_unix_sockets
      @allow_local_binding = allow_local_binding
      @http_proxy_port = http_proxy_port
      @socks_proxy_port = socks_proxy_port
    end

    def to_h
      result = {}
      result[:allowUnixSockets] = @allow_unix_sockets unless @allow_unix_sockets.nil?
      result[:allowAllUnixSockets] = @allow_all_unix_sockets unless @allow_all_unix_sockets.nil?
      result[:allowLocalBinding] = @allow_local_binding unless @allow_local_binding.nil?
      result[:httpProxyPort] = @http_proxy_port if @http_proxy_port
      result[:socksProxyPort] = @socks_proxy_port if @socks_proxy_port
      result
    end
  end

  # Sandbox ignore violations configuration
  class SandboxIgnoreViolations
    attr_accessor :file, :network

    def initialize(file: nil, network: nil)
      @file = file # Array of file paths to ignore
      @network = network # Array of network patterns to ignore
    end

    def to_h
      result = {}
      result[:file] = @file if @file
      result[:network] = @network if @network
      result
    end
  end

  # Sandbox settings for isolated command execution
  class SandboxSettings
    attr_accessor :enabled, :auto_allow_bash_if_sandboxed, :excluded_commands,
                  :allow_unsandboxed_commands, :network, :ignore_violations,
                  :enable_weaker_nested_sandbox

    def initialize(
      enabled: nil,
      auto_allow_bash_if_sandboxed: nil,
      excluded_commands: nil,
      allow_unsandboxed_commands: nil,
      network: nil,
      ignore_violations: nil,
      enable_weaker_nested_sandbox: nil
    )
      @enabled = enabled
      @auto_allow_bash_if_sandboxed = auto_allow_bash_if_sandboxed
      @excluded_commands = excluded_commands # Array of commands to exclude
      @allow_unsandboxed_commands = allow_unsandboxed_commands
      @network = network # SandboxNetworkConfig instance
      @ignore_violations = ignore_violations # SandboxIgnoreViolations instance
      @enable_weaker_nested_sandbox = enable_weaker_nested_sandbox
    end

    def to_h
      result = {}
      result[:enabled] = @enabled unless @enabled.nil?
      result[:autoAllowBashIfSandboxed] = @auto_allow_bash_if_sandboxed unless @auto_allow_bash_if_sandboxed.nil?
      result[:excludedCommands] = @excluded_commands if @excluded_commands
      result[:allowUnsandboxedCommands] = @allow_unsandboxed_commands unless @allow_unsandboxed_commands.nil?
      if @network
        result[:network] = @network.is_a?(SandboxNetworkConfig) ? @network.to_h : @network
      end
      if @ignore_violations
        result[:ignoreViolations] = @ignore_violations.is_a?(SandboxIgnoreViolations) ? @ignore_violations.to_h : @ignore_violations
      end
      result[:enableWeakerNestedSandbox] = @enable_weaker_nested_sandbox unless @enable_weaker_nested_sandbox.nil?
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
                  # Options added to match Python SDK
                  :output_format, :max_budget_usd, :max_thinking_tokens,
                  :fallback_model, :plugins, :debug_stderr,
                  # New options from Python SDK v0.1.12+
                  :betas, :tools, :sandbox, :enable_file_checkpointing, :append_allowed_tools

    def initialize(
      allowed_tools: [],
      system_prompt: nil,
      mcp_servers: {},
      permission_mode: nil,
      continue_conversation: false,
      resume: nil,
      max_turns: nil,
      disallowed_tools: [],
      model: nil,
      permission_prompt_tool_name: nil,
      cwd: nil,
      cli_path: nil,
      settings: nil,
      add_dirs: [],
      env: {},
      extra_args: {},
      max_buffer_size: nil,
      stderr: nil,
      can_use_tool: nil,
      hooks: nil,
      user: nil,
      include_partial_messages: false,
      fork_session: false,
      agents: nil,
      setting_sources: nil,
      # Options added to match Python SDK
      output_format: nil,
      max_budget_usd: nil,
      max_thinking_tokens: nil,
      fallback_model: nil,
      plugins: nil,
      debug_stderr: nil,
      # New options from Python SDK v0.1.12+
      betas: nil,
      tools: nil,
      sandbox: nil,
      enable_file_checkpointing: false,
      append_allowed_tools: nil
    )
      @allowed_tools = allowed_tools
      @system_prompt = system_prompt
      @mcp_servers = mcp_servers
      @permission_mode = permission_mode
      @continue_conversation = continue_conversation
      @resume = resume
      @max_turns = max_turns
      @disallowed_tools = disallowed_tools
      @model = model
      @permission_prompt_tool_name = permission_prompt_tool_name
      @cwd = cwd
      @cli_path = cli_path
      @settings = settings
      @add_dirs = add_dirs
      @env = env
      @extra_args = extra_args
      @max_buffer_size = max_buffer_size
      @stderr = stderr
      @can_use_tool = can_use_tool
      @hooks = hooks
      @user = user
      @include_partial_messages = include_partial_messages
      @fork_session = fork_session
      @agents = agents
      @setting_sources = setting_sources
      # Options added to match Python SDK
      @output_format = output_format # JSON schema for structured output
      @max_budget_usd = max_budget_usd # Spending cap in dollars
      @max_thinking_tokens = max_thinking_tokens # Extended thinking token budget
      @fallback_model = fallback_model # Backup model if primary unavailable
      @plugins = plugins # Array of SdkPluginConfig
      @debug_stderr = debug_stderr # Debug output file object/path
      # New options from Python SDK v0.1.12+
      @betas = betas # Array of beta feature strings (e.g., ["context-1m-2025-08-07"])
      @tools = tools # Base tools selection: Array, empty array [], or ToolsPreset
      @sandbox = sandbox # SandboxSettings instance for isolated command execution
      @enable_file_checkpointing = enable_file_checkpointing # Enable file checkpointing for rewind support
      @append_allowed_tools = append_allowed_tools # Array of tools to append to allowed_tools
    end

    def dup_with(**changes)
      new_options = self.dup
      changes.each { |key, value| new_options.send("#{key}=", value) }
      new_options
    end
  end

  # SDK MCP Tool definition
  class SdkMcpTool
    attr_accessor :name, :description, :input_schema, :handler

    def initialize(name:, description:, input_schema:, handler:)
      @name = name
      @description = description
      @input_schema = input_schema
      @handler = handler
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
