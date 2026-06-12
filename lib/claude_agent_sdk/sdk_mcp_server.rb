# frozen_string_literal: true

require 'mcp'

module ClaudeAgentSDK
  # Recursively convert all hash keys to symbols
  def self.deep_symbolize_keys(obj)
    case obj
    when Hash then obj.transform_keys(&:to_sym).transform_values { |v| deep_symbolize_keys(v) }
    when Array then obj.map { |v| deep_symbolize_keys(v) }
    else obj
    end
  end

  # Like deep_symbolize_keys, but also converts Symbol VALUES to strings so a
  # prebuilt schema written with symbols ({ type: :object, ... }) emits clean
  # wire-format JSON Schema.
  def self.deep_normalize_schema(obj)
    case obj
    when Hash then obj.transform_keys(&:to_sym).transform_values { |v| deep_normalize_schema(v) }
    when Array then obj.map { |v| deep_normalize_schema(v) }
    when Symbol then obj.to_s
    else obj
    end
  end

  # A prebuilt JSON Schema is detected by type == 'object' (String or Symbol)
  # AND a Hash properties value. Deliberately stricter than Python's rule:
  # Ruby's simple-schema idiom uses Symbols as type VALUES, so
  # { type: :string, properties: :string } is a legal simple schema with
  # params literally named type/properties.
  def self.prebuilt_json_schema?(schema)
    return false unless schema.is_a?(Hash)

    type_val = schema[:type] || schema['type']
    props_val = schema[:properties] || schema['properties']
    (type_val.is_a?(String) || type_val.is_a?(Symbol)) && type_val.to_s == 'object' && props_val.is_a?(Hash)
  end

  # Single source of truth for tool input schemas: prebuilt schemas are
  # normalized (symbol keys, string values); simple { name: :type } hashes
  # become a full JSON Schema with every param required (string keys).
  def self.normalize_tool_schema(schema)
    return deep_normalize_schema(schema) if prebuilt_json_schema?(schema)

    if schema.is_a?(Hash)
      properties = schema.to_h { |param, type| [param.to_sym, ruby_type_to_json_schema(type)] }
      result = { type: 'object', properties: properties }
      result[:required] = properties.keys.map(&:to_s) unless properties.empty?
      return result
    end

    { type: 'object', properties: {} }
  end

  def self.ruby_type_to_json_schema(type)
    case type
    when :string, String then { type: 'string' }
    when :integer, Integer then { type: 'integer' }
    when :float, Float, :number then { type: 'number' }
    when :boolean, TrueClass, FalseClass then { type: 'boolean' }
    else { type: 'string' } # Default fallback
    end
  end

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

      # Resources are served as MCP::Resource instances; reads go through
      # the gem's registerable handler (see register_resources_read_handler).
      resource_instances = create_resource_instances(resources)

      # Create dynamic Prompt classes from prompt definitions
      prompt_classes = create_prompt_classes(prompts)

      # Create the official MCP::Server instance
      @mcp_server = MCP::Server.new(
        name: name,
        version: version,
        tools: tool_classes,
        resources: resource_instances,
        prompts: prompt_classes
      )
      register_resources_read_handler
    end

    # Handle a JSON-RPC request
    # @param json_string [String] JSON-RPC request
    # @return [String] JSON-RPC response
    def handle_json(json_string)
      @mcp_server.handle_json(json_string)
    end

    # Route one JSON-RPC request hash (symbol keys, as produced by the
    # transport) through the official MCP::Server. Two sanitations, both
    # empirically required:
    # 1. The gem's JsonRpcHandler rejects string ids not matching
    #    /\A[a-zA-Z0-9_-]+\z/ with {id: nil, error: -32600} (Python echoes
    #    any id verbatim) — swap in a safe id and re-stamp the original on
    #    the response (error envelopes too).
    # 2. The gem rejects messages lacking jsonrpc: '2.0' with -32600; Python
    #    never inspects this field and the CLI's embedded mcp_message shape
    #    is not guaranteed — force it.
    # @param message [Hash] JSON-RPC request hash
    # @return [Hash] JSON-RPC response hash
    def handle_message(message)
      original_id = message[:id]
      response = @mcp_server.handle(message.merge(jsonrpc: '2.0', id: 0))
      response[:id] = original_id if response.is_a?(Hash) && response.key?(:id)
      response
    end

    # List all available tools (for backward compatibility)
    # @return [Array<Hash>] Array of tool definitions
    def list_tools
      @tools.map do |tool|
        entry = {
          name: tool.name,
          description: tool.description,
          inputSchema: convert_input_schema(tool.input_schema)
        }
        entry[:annotations] = tool.annotations if tool.annotations
        entry[:_meta] = tool.meta if tool.meta
        entry
      end
    end

    # Execute a tool by name (backward-compat public API; Query's tools/call
    # dispatch routes through handle_message/the official MCP::Server, which
    # also validates arguments against the tool's inputSchema — this direct
    # path bypasses that validation).
    # Tool-execution failures are reported in-band (isError: true) per the
    # MCP spec and Python parity (the mcp lowlevel server converts handler
    # exceptions to CallToolResult(isError=True)); they must NOT become
    # JSON-RPC protocol errors — the model needs the error text to
    # self-correct.
    # @param name [String] Tool name
    # @param arguments [Hash] Tool arguments
    # @return [Hash] Tool result (with isError: true on failure)
    def call_tool(name, arguments)
      tool = @tools.find { |t| t.name == name }
      return error_tool_result("Tool '#{name}' not found") unless tool

      # Call the tool's handler on a plain thread so the async gem's
      # Fiber scheduler is not visible to user code (which may hit AR/PG).
      result = FiberBoundary.invoke { tool.handler.call(arguments) }

      # Guard before flexible_fetch: it raises on non-Hash inputs.
      content = result.is_a?(Hash) ? ClaudeAgentSDK.flexible_fetch(result, "content", "content") : nil
      return error_tool_result("Tool '#{name}' must return a hash with :content key") unless content

      result
    rescue StandardError => e
      # Bare e.message like Python's str(e) — no prefix.
      error_tool_result(e.message)
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

      # Hop off the Fiber scheduler before invoking user code — same reason
      # as `call_tool` above: reader blocks may touch Thread.current-keyed
      # libraries (ActiveRecord, pg, ...) and must run on a plain thread.
      content = FiberBoundary.invoke { resource.reader.call }

      # Ensure content has the expected format (symbol or string keys; guard
      # before flexible_fetch — it raises on non-Hash inputs)
      contents = content.is_a?(Hash) ? ClaudeAgentSDK.flexible_fetch(content, "contents", "contents") : nil
      raise "Resource '#{uri}' must return a hash with :contents key" if contents.nil?

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

      # Hop off the Fiber scheduler before invoking user code — same reason
      # as `call_tool` above.
      result = FiberBoundary.invoke { prompt.generator.call(arguments) }

      # Ensure result has the expected format (symbol or string keys)
      messages = result.is_a?(Hash) ? ClaudeAgentSDK.flexible_fetch(result, "messages", "messages") : nil
      raise "Prompt '#{name}' must return a hash with :messages key" if messages.nil?

      result
    end

    private

    # Mirrors Python mcp lowlevel Server._make_error_result: error text goes
    # in content with isError: true, returned as a *successful* JSON-RPC
    # result.
    def error_tool_result(text)
      { content: [{ type: "text", text: text }], isError: true }
    end

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
              # Full-schema construction: the gem JSON-round-trips and
              # validates against the draft4 metaschema, so a malformed
              # prebuilt schema raises here (lazily, memoized) instead of
              # producing silent garbage. additionalProperties/enum/
              # description survive. Empty required arrays are stripped —
              # draft4's metaschema mandates non-empty required (Python's
              # modern jsonschema accepts []).
              @input_schema_value ||= begin
                schema = ClaudeAgentSDK.normalize_tool_schema(@tool_def.input_schema)
                schema = schema.except(:required) if schema[:required].is_a?(Array) && schema[:required].empty?
                MCP::Tool::InputSchema.new(schema)
              end
            end

            def annotations_value
              # Raw hash, not MCP::Annotations: the gem's class only accepts
              # audience/priority/last_modified, but SDK annotations carry
              # arbitrary keys (e.g. maxResultSizeChars). Hash#to_h is
              # identity, so Tool.to_h serializes it unchanged.
              @tool_def.annotations
            end

            def meta_value
              @tool_def.meta
            end

            def call(server_context: nil, **args)
              # Filter out server_context and pass remaining args to handler.
              # Hop to a plain thread so user handlers don't see the Fiber scheduler.
              result = FiberBoundary.invoke { @tool_def.handler.call(args) }

              # Guard BEFORE flexible_fetch: on a non-Hash it raises
              # TypeError/NoMethodError, surfacing garbage instead of the
              # friendly message.
              raise "Tool '#{@tool_def.name}' must return a hash with :content key" unless result.is_a?(Hash)

              content = ClaudeAgentSDK.flexible_fetch(result, 'content', 'content')
              raise "Tool '#{@tool_def.name}' must return a hash with :content key" if content.nil?

              is_error = ClaudeAgentSDK.flexible_fetch(result, 'isError', 'is_error')
              structured_content = ClaudeAgentSDK.flexible_fetch(result, 'structuredContent', 'structured_content')

              MCP::Tool::Response.new(
                content,
                error: !!is_error,
                structured_content: structured_content
              )
            end
          end
        end
      end
    end

    # The mcp gem serves resources as MCP::Resource INSTANCES (Resource#to_h
    # drives resources/list) and reads exclusively through the registerable
    # resources_read_handler — the old Class.new(MCP::Resource) approach broke
    # resources/list (Class has no #to_h) and its read method referenced
    # MCP::ResourceContents, a constant that has never existed in any gem
    # version.
    def create_resource_instances(resources)
      resources.map do |resource_def|
        MCP::Resource.new(
          uri: resource_def.uri,
          name: resource_def.name,
          description: resource_def.description,
          mime_type: resource_def.mime_type
        )
      end
    end

    # Register the gem's read hook, delegating to read_resource so the
    # FiberBoundary hop and result validation apply on the handle_json path
    # too. The handler must return the INNER contents array (the gem wraps
    # {contents: ...}); RequestHandlerError keeps the human-readable detail
    # in error.data (a plain raise is swallowed into 'Internal error ...').
    def register_resources_read_handler
      sdk_server = self
      @mcp_server.resources_read_handler do |params|
        uri = params[:uri] || params['uri']
        unless sdk_server.resources.any? { |r| r.uri == uri }
          raise MCP::Server::RequestHandlerError.new(
            "Resource '#{uri}' not found", params, error_type: :internal_error
          )
        end

        ClaudeAgentSDK.flexible_fetch(sdk_server.read_resource(uri), 'contents', 'contents')
      end
    end

    # Prompts via the gem's canonical factory: Prompt.define sets
    # @name_value (exact name, no class-name mangling), @description_value
    # and @arguments_value, so prompts/list and prompts/get work. The
    # template block delegates to get_prompt, preserving the FiberBoundary
    # hop and :messages validation. Inside the block self is the prompt
    # class (instance_exec), so capture the server first.
    def create_prompt_classes(prompts)
      sdk_server = self
      prompts.map do |prompt_def|
        klass = MCP::Prompt.define(
          name: prompt_def.name,
          description: prompt_def.description,
          arguments: build_prompt_arguments(prompt_def.arguments)
        ) do |args|
          sdk_server.get_prompt(prompt_def.name, args || {})
        end
        # The gem passes request[:arguments] (nil when omitted) straight into
        # validate_arguments! -> nil.keys NoMethodError; default it.
        klass.define_singleton_method(:validate_arguments!) { |args| super(args || {}) }
        klass
      end
    end

    # Arguments must be MCP::Prompt::Argument instances: the gem's
    # required-args check calls arg.name/arg.required on each entry.
    def build_prompt_arguments(arguments)
      (arguments || []).map do |arg|
        next arg if arg.is_a?(MCP::Prompt::Argument)

        MCP::Prompt::Argument.new(
          name: ClaudeAgentSDK.flexible_fetch(arg, 'name', 'name').to_s,
          description: ClaudeAgentSDK.flexible_fetch(arg, 'description', 'description'),
          required: !ClaudeAgentSDK.flexible_fetch(arg, 'required', 'required').nil? &&
                    ClaudeAgentSDK.flexible_fetch(arg, 'required', 'required') != false
        )
      end
    end

    def convert_input_schema(schema)
      ClaudeAgentSDK.normalize_tool_schema(schema)
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
  def self.create_tool(name, description, input_schema, annotations: nil, meta: nil, &handler)
    raise ArgumentError, 'Block required for tool handler' unless handler

    # Auto-populate _meta with maxResultSizeChars from annotations if present
    resolved_meta = meta
    if resolved_meta.nil? && annotations
      max_chars = annotations[:maxResultSizeChars] || annotations['maxResultSizeChars']
      resolved_meta = { 'anthropic/maxResultSizeChars' => max_chars } if max_chars
    end

    SdkMcpTool.new(
      name: name,
      description: description,
      input_schema: input_schema,
      handler: handler,
      annotations: annotations,
      meta: resolved_meta
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
