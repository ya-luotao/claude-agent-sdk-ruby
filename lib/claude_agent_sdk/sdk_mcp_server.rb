# frozen_string_literal: true

module ClaudeAgentSDK
  # SDK MCP Server - runs in-process within your Ruby application
  #
  # Unlike external MCP servers that run as separate processes, SDK MCP servers
  # run directly in your application's process, providing better performance
  # and simpler deployment.
  class SdkMcpServer
    attr_reader :name, :version, :tools

    def initialize(name:, version: '1.0.0', tools: [])
      @name = name
      @version = version
      @tools = tools
      @tool_map = tools.each_with_object({}) { |tool, hash| hash[tool.name] = tool }
    end

    # List all available tools
    # @return [Array<Hash>] Array of tool definitions
    def list_tools
      @tools.map do |tool|
        {
          name: tool.name,
          description: tool.description,
          inputSchema: convert_input_schema(tool.input_schema)
        }
      end
    end

    # Execute a tool by name
    # @param name [String] Tool name
    # @param arguments [Hash] Tool arguments
    # @return [Hash] Tool result
    def call_tool(name, arguments)
      tool = @tool_map[name]
      raise "Tool '#{name}' not found" unless tool

      # Call the tool's handler
      result = tool.handler.call(arguments)

      # Ensure result has the expected format
      unless result.is_a?(Hash) && result[:content]
        raise "Tool '#{name}' must return a hash with :content key"
      end

      result
    end

    private

    def convert_input_schema(schema)
      # If it's already a proper JSON schema, return it
      if schema.is_a?(Hash) && schema[:type] && schema[:properties]
        return schema
      end

      # Simple schema: hash mapping parameter names to types
      if schema.is_a?(Hash)
        properties = {}
        schema.each do |param_name, param_type|
          properties[param_name] = type_to_json_schema(param_type)
        end

        return {
          type: 'object',
          properties: properties,
          required: properties.keys
        }
      end

      # Default fallback
      { type: 'object', properties: {} }
    end

    def type_to_json_schema(type)
      case type
      when :string, String
        { type: 'string' }
      when :integer, Integer
        { type: 'integer' }
      when :float, Float
        { type: 'number' }
      when :boolean, TrueClass, FalseClass
        { type: 'boolean' }
      when :number
        { type: 'number' }
      else
        { type: 'string' } # Default fallback
      end
    end
  end

  # Helper function to create a tool definition
  #
  # @param name [String] Unique identifier for the tool
  # @param description [String] Human-readable description
  # @param input_schema [Hash] Schema defining input parameters
  # @param handler [Proc] Block that implements the tool logic
  # @return [SdkMcpTool] Tool definition
  #
  # @example Simple tool
  #   tool = create_tool('greet', 'Greet a user', { name: :string }) do |args|
  #     { content: [{ type: 'text', text: "Hello, #{args[:name]}!" }] }
  #   end
  #
  # @example Tool with multiple parameters
  #   tool = create_tool('add', 'Add two numbers', { a: :number, b: :number }) do |args|
  #     result = args[:a] + args[:b]
  #     { content: [{ type: 'text', text: "Result: #{result}" }] }
  #   end
  #
  # @example Tool with error handling
  #   tool = create_tool('divide', 'Divide numbers', { a: :number, b: :number }) do |args|
  #     if args[:b] == 0
  #       { content: [{ type: 'text', text: 'Error: Division by zero' }], is_error: true }
  #     else
  #       result = args[:a] / args[:b]
  #       { content: [{ type: 'text', text: "Result: #{result}" }] }
  #     end
  #   end
  def self.create_tool(name, description, input_schema, &handler)
    raise ArgumentError, 'Block required for tool handler' unless handler

    SdkMcpTool.new(
      name: name,
      description: description,
      input_schema: input_schema,
      handler: handler
    )
  end

  # Create an SDK MCP server
  #
  # @param name [String] Unique identifier for the server
  # @param version [String] Server version (default: '1.0.0')
  # @param tools [Array<SdkMcpTool>] List of tool definitions
  # @return [Hash] MCP server configuration for ClaudeAgentOptions
  #
  # @example Simple calculator server
  #   add_tool = ClaudeAgentSDK.create_tool('add', 'Add numbers', { a: :number, b: :number }) do |args|
  #     { content: [{ type: 'text', text: "Sum: #{args[:a] + args[:b]}" }] }
  #   end
  #
  #   calculator = ClaudeAgentSDK.create_sdk_mcp_server(
  #     name: 'calculator',
  #     version: '2.0.0',
  #     tools: [add_tool]
  #   )
  #
  #   options = ClaudeAgentOptions.new(
  #     mcp_servers: { calc: calculator },
  #     allowed_tools: ['mcp__calc__add']
  #   )
  def self.create_sdk_mcp_server(name:, version: '1.0.0', tools: [])
    server = SdkMcpServer.new(name: name, version: version, tools: tools)

    # Return configuration for ClaudeAgentOptions
    {
      type: 'sdk',
      name: name,
      instance: server
    }
  end
end
