# frozen_string_literal: true

module ClaudeAgentSDK
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
    attr_accessor :content, :parent_tool_use_id

    def initialize(content:, parent_tool_use_id: nil)
      @content = content
      @parent_tool_use_id = parent_tool_use_id
    end
  end

  # Assistant message with content blocks
  class AssistantMessage
    attr_accessor :content, :model, :parent_tool_use_id

    def initialize(content:, model:, parent_tool_use_id: nil)
      @content = content
      @model = model
      @parent_tool_use_id = parent_tool_use_id
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
                  :num_turns, :session_id, :total_cost_usd, :usage, :result

    def initialize(subtype:, duration_ms:, duration_api_ms:, is_error:,
                   num_turns:, session_id:, total_cost_usd: nil, usage: nil, result: nil)
      @subtype = subtype
      @duration_ms = duration_ms
      @duration_api_ms = duration_api_ms
      @is_error = is_error
      @num_turns = num_turns
      @session_id = session_id
      @total_cost_usd = total_cost_usd
      @usage = usage
      @result = result
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
    attr_accessor :matcher, :hooks

    def initialize(matcher: nil, hooks: [])
      @matcher = matcher
      @hooks = hooks
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

  # Claude Agent Options for configuring queries
  class ClaudeAgentOptions
    attr_accessor :allowed_tools, :system_prompt, :mcp_servers, :permission_mode,
                  :continue_conversation, :resume, :max_turns, :disallowed_tools,
                  :model, :permission_prompt_tool_name, :cwd, :cli_path, :settings,
                  :add_dirs, :env, :extra_args, :max_buffer_size, :stderr,
                  :can_use_tool, :hooks, :user, :include_partial_messages,
                  :fork_session, :agents, :setting_sources

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
      setting_sources: nil
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
end
