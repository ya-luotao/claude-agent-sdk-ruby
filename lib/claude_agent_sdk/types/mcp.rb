# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
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
      @tools = if value.is_a?(Array)
                 value.map { |t| t.is_a?(Hash) ? McpToolInfo.new(t) : t }
               else
                 value
               end
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
      @mcp_servers = if value.is_a?(Array)
                       value.map { |s| s.is_a?(Hash) ? McpServerStatus.new(s) : s }
                     else
                       value
                     end
    end

    # Backwards-compatible parse; returns nil for nil input.
    def self.parse(data)
      from_hash(data)
    end
  end

  # MCP Server configurations
  class McpStdioServerConfig < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :command, :args, :env
    attr_reader :type

    inspect_filtered :env

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
    include Type::OptionValue

    strict_attributes

    attr_accessor :url, :headers
    attr_reader :type

    inspect_filtered :headers

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
    include Type::OptionValue

    strict_attributes

    attr_accessor :url, :headers
    attr_reader :type

    inspect_filtered :headers

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
    include Type::OptionValue

    strict_attributes

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
