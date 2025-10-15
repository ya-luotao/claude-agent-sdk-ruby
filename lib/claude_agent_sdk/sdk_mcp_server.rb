# frozen_string_literal: true

module ClaudeAgentSDK
  # SDK MCP Server - runs in-process within your Ruby application
  #
  # Unlike external MCP servers that run as separate processes, SDK MCP servers
  # run directly in your application's process, providing better performance
  # and simpler deployment.
  #
  # Supports:
  # - Tools: Executable functions that Claude can call
  # - Resources: Data sources that can be read (files, databases, APIs, etc.)
  # - Prompts: Reusable prompt templates with arguments
  class SdkMcpServer
    attr_reader :name, :version, :tools, :resources, :prompts

    def initialize(name:, version: '1.0.0', tools: [], resources: [], prompts: [])
      @name = name
      @version = version
      @tools = tools
      @resources = resources
      @prompts = prompts
      @tool_map = tools.each_with_object({}) { |tool, hash| hash[tool.name] = tool }
      @resource_map = resources.each_with_object({}) { |res, hash| hash[res.uri] = res }
      @prompt_map = prompts.each_with_object({}) { |prompt, hash| hash[prompt.name] = prompt }
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

    # List all available resources
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

    # Read a resource by URI
    # @param uri [String] Resource URI
    # @return [Hash] Resource content
    def read_resource(uri)
      resource = @resource_map[uri]
      raise "Resource '#{uri}' not found" unless resource

      # Call the resource's reader
      content = resource.reader.call

      # Ensure content has the expected format
      unless content.is_a?(Hash) && content[:contents]
        raise "Resource '#{uri}' must return a hash with :contents key"
      end

      content
    end

    # List all available prompts
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

    # Get a prompt by name
    # @param name [String] Prompt name
    # @param arguments [Hash] Arguments to fill in the prompt template
    # @return [Hash] Prompt with filled-in arguments
    def get_prompt(name, arguments = {})
      prompt = @prompt_map[name]
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
