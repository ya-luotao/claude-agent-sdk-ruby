# frozen_string_literal: true

require 'mcp'

module ClaudeAgentSDK
  # SDK MCP Server - wraps official MCP::Server with block-based API
  #
  # Unlike external MCP servers that run as separate processes, SDK MCP servers
  # run directly in your application's process, providing better performance
  # and simpler deployment.
  #
  # This class wraps the official MCP Ruby SDK and provides a simpler block-based
  # API for defining tools, resources, and prompts.
  class SdkMcpServer
    attr_reader :name, :version, :tools, :resources, :prompts, :mcp_server

    def initialize(name:, version: '1.0.0', tools: [], resources: [], prompts: [])
      @name = name
      @version = version
      @tools = tools
      @resources = resources
      @prompts = prompts

      # Create dynamic Tool classes from tool definitions
      tool_classes = create_tool_classes(tools)

      # Create dynamic Resource classes from resource definitions
      resource_classes = create_resource_classes(resources)

      # Create dynamic Prompt classes from prompt definitions
      prompt_classes = create_prompt_classes(prompts)

      # Create the official MCP::Server instance
      @mcp_server = MCP::Server.new(
        name: name,
        version: version,
        tools: tool_classes,
        resources: resource_classes,
        prompts: prompt_classes
      )
    end

    # Handle a JSON-RPC request
    # @param json_string [String] JSON-RPC request
    # @return [String] JSON-RPC response
    def handle_json(json_string)
      @mcp_server.handle_json(json_string)
    end

    # List all available tools (for backward compatibility)
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

    # Execute a tool by name (for backward compatibility)
    # @param name [String] Tool name
    # @param arguments [Hash] Tool arguments
    # @return [Hash] Tool result
    def call_tool(name, arguments)
      tool = @tools.find { |t| t.name == name }
      raise "Tool '#{name}' not found" unless tool

      # Call the tool's handler
      result = tool.handler.call(arguments)

      # Ensure result has the expected format
      unless result.is_a?(Hash) && result[:content]
        raise "Tool '#{name}' must return a hash with :content key"
      end

      result
    end

    # List all available resources (for backward compatibility)
    # @return [Array<Hash>] Array of resource definitions
    def list_resources
      @resources.map do |resource|
        {
          uri: resource.uri,
          name: resource.name,
          description: resource.description,
          mimeType: resource.mime_type
        }.compact
      end
    end

    # Read a resource by URI (for backward compatibility)
    # @param uri [String] Resource URI
    # @return [Hash] Resource content
    def read_resource(uri)
      resource = @resources.find { |r| r.uri == uri }
      raise "Resource '#{uri}' not found" unless resource

      # Call the resource's reader
      content = resource.reader.call

      # Ensure content has the expected format
      unless content.is_a?(Hash) && content[:contents]
        raise "Resource '#{uri}' must return a hash with :contents key"
      end

      content
    end

    # List all available prompts (for backward compatibility)
    # @return [Array<Hash>] Array of prompt definitions
    def list_prompts
      @prompts.map do |prompt|
        {
          name: prompt.name,
          description: prompt.description,
          arguments: prompt.arguments
        }.compact
      end
    end

    # Get a prompt by name (for backward compatibility)
    # @param name [String] Prompt name
    # @param arguments [Hash] Arguments to fill in the prompt template
    # @return [Hash] Prompt with filled-in arguments
    def get_prompt(name, arguments = {})
      prompt = @prompts.find { |p| p.name == name }
      raise "Prompt '#{name}' not found" unless prompt

      # Call the prompt's generator
      result = prompt.generator.call(arguments)

      # Ensure result has the expected format
      unless result.is_a?(Hash) && result[:messages]
        raise "Prompt '#{name}' must return a hash with :messages key"
      end

      result
    end

    private

    # Create dynamic Tool classes from tool definitions
    def create_tool_classes(tools)
      tools.map do |tool_def|
        # Create a new class that extends MCP::Tool
        Class.new(MCP::Tool) do
          @tool_def = tool_def

          class << self
            attr_reader :tool_def

            def name_value
              @tool_def.name
            end

            def description_value
              @tool_def.description
            end

            def input_schema_value
              schema = convert_schema(@tool_def.input_schema)
              MCP::Tool::InputSchema.new(
                properties: schema[:properties] || {},
                required: schema[:required] || []
              )
            end

            def call(server_context: nil, **args)
              # Filter out server_context and pass remaining args to handler
              result = @tool_def.handler.call(args)

              unless result.is_a?(Hash) && (result[:content] || result['content'])
                raise "Tool '#{@tool_def.name}' must return a hash with :content key"
              end

              content = result[:content] || result['content']

              is_error = result[:isError]
              is_error = result['isError'] if is_error.nil?
              is_error = result[:is_error] if is_error.nil?
              is_error = result['is_error'] if is_error.nil?

              structured_content = result[:structuredContent]
              structured_content = result['structuredContent'] if structured_content.nil?
              structured_content = result[:structured_content] if structured_content.nil?
              structured_content = result['structured_content'] if structured_content.nil?

              MCP::Tool::Response.new(
                content,
                error: !!is_error,
                structured_content: structured_content
              )
            end

            private

            def convert_schema(schema)
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
                  required: properties.keys.map(&:to_s)
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
        end
      end
    end

    # Create dynamic Resource classes from resource definitions
    def create_resource_classes(resources)
      resources.map do |resource_def|
        # Create a new class that extends MCP::Resource
        Class.new(MCP::Resource) do
          @resource_def = resource_def

          class << self
            attr_reader :resource_def

            def uri
              @resource_def.uri
            end

            def name
              @resource_def.name
            end

            def description
              @resource_def.description
            end

            def mime_type
              @resource_def.mime_type
            end

            def read
              result = @resource_def.reader.call

              # Convert to MCP format
              result[:contents].map do |content|
                MCP::ResourceContents.new(
                  uri: content[:uri],
                  mime_type: content[:mimeType] || content[:mime_type],
                  text: content[:text]
                )
              end
            end
          end
        end
      end
    end

    # Create dynamic Prompt classes from prompt definitions
    def create_prompt_classes(prompts)
      prompts.map do |prompt_def|
        # Create a new class that extends MCP::Prompt
        Class.new(MCP::Prompt) do
          @prompt_def = prompt_def

          class << self
            attr_reader :prompt_def

            def name
              @prompt_def.name
            end

            def description
              @prompt_def.description
            end

            def arguments
              @prompt_def.arguments || []
            end

            def get(**args)
              result = @prompt_def.generator.call(args)

              # Convert to MCP format
              {
                messages: result[:messages].map do |msg|
                  {
                    role: msg[:role],
                    content: msg[:content]
                  }
                end
              }
            end
          end
        end
      end
    end

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

  # Helper function to create a resource definition
  #
  # @param uri [String] Unique identifier for the resource (e.g., "file:///path/to/file")
  # @param name [String] Human-readable name
  # @param description [String, nil] Optional description
  # @param mime_type [String, nil] Optional MIME type (e.g., "text/plain", "application/json")
  # @param reader [Proc] Block that returns the resource content
  # @return [SdkMcpResource] Resource definition
  #
  # @example File resource
  #   resource = create_resource(
  #     uri: 'file:///config/settings.json',
  #     name: 'Application Settings',
  #     description: 'Current application configuration',
  #     mime_type: 'application/json'
  #   ) do
  #     content = File.read('/path/to/settings.json')
  #     {
  #       contents: [{
  #         uri: 'file:///config/settings.json',
  #         mimeType: 'application/json',
  #         text: content
  #       }]
  #     }
  #   end
  #
  # @example Database resource
  #   resource = create_resource(
  #     uri: 'db://users/count',
  #     name: 'User Count',
  #     description: 'Total number of registered users'
  #   ) do
  #     count = User.count
  #     {
  #       contents: [{
  #         uri: 'db://users/count',
  #         mimeType: 'text/plain',
  #         text: count.to_s
  #       }]
  #     }
  #   end
  def self.create_resource(uri:, name:, description: nil, mime_type: nil, &reader)
    raise ArgumentError, 'Block required for resource reader' unless reader

    SdkMcpResource.new(
      uri: uri,
      name: name,
      description: description,
      mime_type: mime_type,
      reader: reader
    )
  end

  # Helper function to create a prompt definition
  #
  # @param name [String] Unique identifier for the prompt
  # @param description [String, nil] Optional description
  # @param arguments [Array<Hash>, nil] Optional argument definitions
  # @param generator [Proc] Block that generates prompt messages
  # @return [SdkMcpPrompt] Prompt definition
  #
  # @example Simple prompt
  #   prompt = create_prompt(
  #     name: 'code_review',
  #     description: 'Review code for best practices'
  #   ) do |args|
  #     {
  #       messages: [
  #         {
  #           role: 'user',
  #           content: {
  #             type: 'text',
  #             text: 'Please review this code for best practices and suggest improvements.'
  #           }
  #         }
  #       ]
  #     }
  #   end
  #
  # @example Prompt with arguments
  #   prompt = create_prompt(
  #     name: 'git_commit',
  #     description: 'Generate a git commit message',
  #     arguments: [
  #       { name: 'changes', description: 'Description of changes', required: true }
  #     ]
  #   ) do |args|
  #     {
  #       messages: [
  #         {
  #           role: 'user',
  #           content: {
  #             type: 'text',
  #             text: "Generate a concise git commit message for: #{args[:changes]}"
  #           }
  #         }
  #       ]
  #     }
  #   end
  def self.create_prompt(name:, description: nil, arguments: nil, &generator)
    raise ArgumentError, 'Block required for prompt generator' unless generator

    SdkMcpPrompt.new(
      name: name,
      description: description,
      arguments: arguments,
      generator: generator
    )
  end

  # Create an SDK MCP server
  #
  # @param name [String] Unique identifier for the server
  # @param version [String] Server version (default: '1.0.0')
  # @param tools [Array<SdkMcpTool>] List of tool definitions
  # @param resources [Array<SdkMcpResource>] List of resource definitions
  # @param prompts [Array<SdkMcpPrompt>] List of prompt definitions
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
  #
  # @example Server with resources and prompts
  #   config_resource = ClaudeAgentSDK.create_resource(
  #     uri: 'config://app',
  #     name: 'App Config'
  #   ) { { contents: [{ uri: 'config://app', text: 'config data' }] } }
  #
  #   review_prompt = ClaudeAgentSDK.create_prompt(
  #     name: 'review',
  #     description: 'Code review'
  #   ) { { messages: [{ role: 'user', content: { type: 'text', text: 'Review this' } }] } }
  #
  #   server = ClaudeAgentSDK.create_sdk_mcp_server(
  #     name: 'dev-tools',
  #     resources: [config_resource],
  #     prompts: [review_prompt]
  #   )
  def self.create_sdk_mcp_server(name:, version: '1.0.0', tools: [], resources: [], prompts: [])
    server = SdkMcpServer.new(
      name: name,
      version: version,
      tools: tools,
      resources: resources,
      prompts: prompts
    )

    # Return configuration for ClaudeAgentOptions
    {
      type: 'sdk',
      name: name,
      instance: server
    }
  end
end
