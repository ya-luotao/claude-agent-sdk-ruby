# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::SdkMcpServer do
  describe '#initialize' do
    it 'creates a server with name and version' do
      server = described_class.new(name: 'test-server', version: '1.0.0', tools: [])
      expect(server.name).to eq('test-server')
      expect(server.version).to eq('1.0.0')
    end

    it 'defaults version to 1.0.0' do
      server = described_class.new(name: 'test-server')
      expect(server.version).to eq('1.0.0')
    end

    it 'accepts tools array' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'test_tool',
        description: 'Test',
        input_schema: {},
        handler: ->(_) { {} }
      )
      server = described_class.new(name: 'test', tools: [tool])
      expect(server.tools).to eq([tool])
    end
  end

  describe '#list_tools' do
    it 'returns empty array for no tools' do
      server = described_class.new(name: 'test')
      expect(server.list_tools).to eq([])
    end

    it 'includes annotations in tool listing when present' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'read_file',
        description: 'Read a file',
        input_schema: { path: :string },
        handler: ->(_) { { content: [] } },
        annotations: { title: 'File Reader', readOnlyHint: true }
      )
      server = described_class.new(name: 'test', tools: [tool])

      tools = server.list_tools
      expect(tools.first[:annotations]).to eq({ title: 'File Reader', readOnlyHint: true })
    end

    it 'omits annotations when nil' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'test',
        description: 'Test',
        input_schema: {},
        handler: ->(_) { { content: [] } }
      )
      server = described_class.new(name: 'test', tools: [tool])

      tools = server.list_tools
      expect(tools.first.key?(:annotations)).to eq(false)
    end

    it 'returns tool definitions with JSON schemas' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'add',
        description: 'Add numbers',
        input_schema: { a: :number, b: :number },
        handler: ->(_) { {} }
      )
      server = described_class.new(name: 'calc', tools: [tool])

      tools = server.list_tools
      expect(tools.length).to eq(1)
      expect(tools.first[:name]).to eq('add')
      expect(tools.first[:description]).to eq('Add numbers')
      expect(tools.first[:inputSchema][:type]).to eq('object')
      expect(tools.first[:inputSchema][:properties]).to have_key(:a)
      expect(tools.first[:inputSchema][:properties][:a][:type]).to eq('number')
    end

    it 'converts Ruby types to JSON schema types' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'test',
        description: 'Test',
        input_schema: {
          str: :string,
          num: :number,
          int: :integer,
          bool: :boolean
        },
        handler: ->(_) { {} }
      )
      server = described_class.new(name: 'test', tools: [tool])

      schema = server.list_tools.first[:inputSchema]
      expect(schema[:properties][:str][:type]).to eq('string')
      expect(schema[:properties][:num][:type]).to eq('number')
      expect(schema[:properties][:int][:type]).to eq('integer')
      expect(schema[:properties][:bool][:type]).to eq('boolean')
    end

    it 'handles pre-formatted JSON schemas with symbol keys' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'test',
        description: 'Test',
        input_schema: {
          type: 'object',
          properties: { custom: { type: 'string' } }
        },
        handler: ->(_) { {} }
      )
      server = described_class.new(name: 'test', tools: [tool])

      schema = server.list_tools.first[:inputSchema]
      expect(schema[:type]).to eq('object')
      expect(schema[:properties][:custom][:type]).to eq('string')
    end

    it 'handles pre-formatted JSON schemas with string keys (e.g. from RubyLLM)' do
      # Libraries like RubyLLM deep-stringify schema keys. The SDK must detect
      # these as pre-built schemas and normalize to symbol keys, not interpret each
      # top-level key ("type", "properties", "required", etc.) as a parameter name.
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'save_memory',
        description: 'Save a fact to memory',
        input_schema: {
          'type' => 'object',
          'properties' => { 'fact' => { 'type' => 'string', 'description' => 'The fact to remember' } },
          'required' => ['fact'],
          'additionalProperties' => false
        },
        handler: ->(_) { {} }
      )
      server = described_class.new(name: 'test', tools: [tool])

      schema = server.list_tools.first[:inputSchema]
      expect(schema[:type]).to eq('object')
      expect(schema[:properties].keys).to(
        eq([:fact]), 'Schema must expose only the declared parameter, not leak schema meta-keys'
      )
      expect(schema[:properties][:fact][:type]).to eq('string')
      expect(schema[:properties][:fact][:description]).to eq('The fact to remember')
      expect(schema[:required]).to eq(['fact'])
      expect(schema[:additionalProperties]).to eq(false)
    end

    it 'does not treat a simple schema with params named type and properties as pre-built' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'test',
        description: 'Test',
        input_schema: { type: :string, properties: :string },
        handler: ->(_) { {} }
      )
      server = described_class.new(name: 'test', tools: [tool])

      schema = server.list_tools.first[:inputSchema]
      expect(schema[:type]).to eq('object')
      expect(schema[:properties]).to have_key(:type)
      expect(schema[:properties]).to have_key(:properties)
      expect(schema[:properties][:type][:type]).to eq('string')
    end
  end

  describe '#call_tool' do
    it 'executes tool handler with arguments' do
      handler = lambda do |args|
        result = args[:a] + args[:b]
        { content: [{ type: 'text', text: "Result: #{result}" }] }
      end

      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'add',
        description: 'Add',
        input_schema: {},
        handler: handler
      )

      server = described_class.new(name: 'calc', tools: [tool])
      result = server.call_tool('add', { a: 5, b: 3 })

      expect(result[:content]).to be_an(Array)
      expect(result[:content].first[:text]).to eq('Result: 8')
    end

    it 'returns an in-band isError result for unknown tool' do
      server = described_class.new(name: 'test')
      result = server.call_tool('unknown', {})

      expect(result[:isError]).to be(true)
      expect(result[:content].first[:text]).to eq("Tool 'unknown' not found")
    end

    it 'passes through error results' do
      handler = lambda do |args|
        if args[:n] < 0
          { content: [{ type: 'text', text: 'Error: negative number' }], is_error: true }
        else
          { content: [{ type: 'text', text: 'OK' }] }
        end
      end

      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'sqrt',
        description: 'Square root',
        input_schema: {},
        handler: handler
      )

      server = described_class.new(name: 'math', tools: [tool])
      result = server.call_tool('sqrt', { n: -1 })

      expect(result[:is_error]).to eq(true)
      expect(result[:content].first[:text]).to include('Error')
    end

    it 'returns an in-band isError result if handler returns invalid format' do
      handler = ->(_) { 'invalid' } # Should return hash with :content

      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'bad',
        description: 'Bad',
        input_schema: {},
        handler: handler
      )

      server = described_class.new(name: 'test', tools: [tool])
      result = server.call_tool('bad', {})

      expect(result[:isError]).to be(true)
      expect(result[:content].first[:text]).to match(/must return a hash with :content key/)
    end

    it 'converts handler exceptions to in-band isError results (never JSON-RPC errors)' do
      handler = ->(_) { raise 'database connection refused' }
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'db', description: 'DB', input_schema: {}, handler: handler
      )

      server = described_class.new(name: 'test', tools: [tool])
      result = server.call_tool('db', {})

      expect(result[:isError]).to be(true)
      # Bare message like Python's str(e) — no prefix.
      expect(result[:content].first[:text]).to eq('database connection refused')
    end

    it 'accepts string-keyed handler results' do
      handler = ->(_) { { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] } }
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'stringy', description: 'S', input_schema: {}, handler: handler
      )

      server = described_class.new(name: 'test', tools: [tool])
      result = server.call_tool('stringy', {})

      expect(result['content'].first['text']).to eq('ok')
      expect(result[:isError]).to be_nil
    end
  end

  describe '#read_resource and #get_prompt key flexibility' do
    it 'accepts string-keyed resource reader results' do
      resource = ClaudeAgentSDK.create_resource(uri: 'res://a', name: 'A') do
        { 'contents' => [{ 'uri' => 'res://a', 'text' => 'data' }] }
      end
      server = described_class.new(name: 'srv', resources: [resource])

      result = server.read_resource('res://a')
      expect(result['contents'].first['text']).to eq('data')
    end

    it 'accepts string-keyed prompt generator results' do
      prompt = ClaudeAgentSDK.create_prompt(name: 'greet') do |_args|
        { 'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'hi' } }] }
      end
      server = described_class.new(name: 'srv', prompts: [prompt])

      result = server.get_prompt('greet')
      expect(result['messages'].first['role']).to eq('user')
    end

    it 'still raises the friendly message for malformed results' do
      resource = ClaudeAgentSDK.create_resource(uri: 'res://bad', name: 'Bad') { 'not a hash' }
      server = described_class.new(name: 'srv', resources: [resource])

      expect { server.read_resource('res://bad') }
        .to raise_error(/must return a hash with :contents key/)
    end
  end

  describe '#handle_json full surface (M9/L5 e2e)' do
    def build_full_server
      tool = ClaudeAgentSDK.create_tool(
        'greet', 'Greet',
        { type: :object, properties: { name: { type: :string } },
          required: ['name'], additionalProperties: false }
      ) do |args|
        { content: [{ type: 'text', text: "Hi #{args[:name] || args['name']}" }] }
      end
      resource = ClaudeAgentSDK.create_resource(
        uri: 'config://app', name: 'App Config', description: 'cfg', mime_type: 'text/plain'
      ) do
        { contents: [{ uri: 'config://app', mimeType: 'text/plain', text: 'hello' }] }
      end
      prompt = ClaudeAgentSDK.create_prompt(
        name: 'codeReview', description: 'Review code',
        arguments: [{ name: 'changes', description: 'desc', required: true }]
      ) do |args|
        { messages: [{ role: 'user', content: { type: 'text', text: "Review: #{args[:changes] || args['changes']}" } }] }
      end
      described_class.new(name: 'demo', tools: [tool], resources: [resource], prompts: [prompt])
    end

    def rpc(server, method, params = nil, id: 1)
      req = { jsonrpc: '2.0', id: id, method: method }
      req[:params] = params if params
      JSON.parse(server.handle_json(JSON.generate(req)), symbolize_names: true)
    end

    let(:server) { build_full_server }

    it 'serves resources/list (instances, not classes)' do
      expect(rpc(server, 'resources/list').dig(:result, :resources)).to eq(
        [{ uri: 'config://app', name: 'App Config', description: 'cfg', mimeType: 'text/plain' }]
      )
    end

    it 'serves resources/read through the registered handler' do
      expect(rpc(server, 'resources/read', { uri: 'config://app' }).dig(:result, :contents)).to eq(
        [{ uri: 'config://app', mimeType: 'text/plain', text: 'hello' }]
      )
    end

    it 'reports unknown resources with readable error data' do
      res = rpc(server, 'resources/read', { uri: 'config://missing' })
      expect(res.dig(:error, :code)).to eq(-32_603)
      expect(res.dig(:error, :data).to_s).to match(%r{Resource 'config://missing' not found})
    end

    it 'serves prompts/list with exact name, description and arguments' do
      expect(rpc(server, 'prompts/list').dig(:result, :prompts)).to eq(
        [{ name: 'codeReview', description: 'Review code',
           arguments: [{ name: 'changes', description: 'desc', required: true }] }]
      )
    end

    it 'serves prompts/get' do
      res = rpc(server, 'prompts/get', { name: 'codeReview', arguments: { changes: 'x' } })
      expect(res.dig(:result, :messages)).to eq(
        [{ role: 'user', content: { type: 'text', text: 'Review: x' } }]
      )
    end

    it 'reports missing required prompt arguments, including when arguments is omitted' do
      res = rpc(server, 'prompts/get', { name: 'codeReview', arguments: {} })
      expect(res.dig(:error, :data).to_s).to match(/Missing required arguments: changes/)

      res = rpc(server, 'prompts/get', { name: 'codeReview' })
      expect(res.dig(:error, :data).to_s).to match(/Missing required arguments: changes/)
    end

    it 'emits prebuilt symbol-keyed schemas intact through tools/list (L5)' do
      schema = rpc(server, 'tools/list').dig(:result, :tools, 0, :inputSchema)
      expect(schema[:properties].keys).to eq([:name])
      expect(schema[:properties][:name][:type]).to eq('string')
      expect(schema[:required]).to eq(['name'])
      expect(schema[:additionalProperties]).to eq(false)
    end

    it 'accepts valid tools/call against a prebuilt symbol schema (L5)' do
      res = rpc(server, 'tools/call', { name: 'greet', arguments: { name: 'Bob' } })
      expect(res.dig(:result, :content, 0, :text)).to eq('Hi Bob')
      expect(res.dig(:result, :isError)).to eq(false)

      missing = rpc(server, 'tools/call', { name: 'greet', arguments: {} })
      expect(missing.dig(:result, :isError)).to eq(true)
      expect(missing.dig(:result, :content, 0, :text)).to match(/Missing required arguments: name/)
    end

    it 'emits the same clean schema via the Query-path list_tools (L5)' do
      schema = server.list_tools.first[:inputSchema]
      expect(schema[:properties].keys).to eq([:name])
      expect(schema[:required]).to eq(['name'])
      expect(schema[:additionalProperties]).to eq(false)
    end

    it 'emits annotations and _meta through handle_json tools/list' do
      tool = ClaudeAgentSDK.create_tool('annotated', 'A', {}) { |_| { content: [] } }
      tool.annotations = { maxResultSizeChars: 100 }
      tool.meta = { 'anthropic/maxResultSizeChars': 100 }
      server2 = described_class.new(name: 'demo2', tools: [tool])

      tools = rpc(server2, 'tools/list').dig(:result, :tools)
      expect(tools[0][:annotations]).to eq({ maxResultSizeChars: 100 })
      expect(tools[0][:_meta]).to eq({ 'anthropic/maxResultSizeChars': 100 })
    end

    it 'keeps a draft4-incompatible-but-modern schema callable' do
      # Valid modern JSON Schema that draft4's metaschema rejects (numeric
      # exclusiveMinimum) — Python accepts it. Depending on the installed mcp
      # gem the schema is either accepted natively (mcp >= 0.22 validates it) or
      # rejected by the draft4 metaschema (older mcp, the SDK falls back to a
      # permissive schema with a warning). Either way the tool must keep working
      # instead of being permanently uncallable; that invariant is what this
      # test pins, independent of which mcp version is resolved (no lockfile).
      tool = ClaudeAgentSDK.create_tool(
        'count', 'Count',
        { type: 'object', properties: { n: { type: 'integer', exclusiveMinimum: 0 } }, required: ['n'] }
      ) { |args| { content: [{ type: 'text', text: "n=#{args[:n]}" }] } }
      server3 = described_class.new(name: 'demo3', tools: [tool])

      res = rpc(server3, 'tools/call', { name: 'count', arguments: { n: 3 } })
      expect(res.dig(:result, :content, 0, :text)).to eq('n=3')
      expect(res.dig(:result, :isError)).to eq(false)
    end

    it 'warns and disables validation when the mcp gem rejects a tool schema' do
      # Deterministic coverage of the fallback path, decoupled from which schemas
      # a given mcp version's metaschema happens to reject: simulate the gem
      # raising ArgumentError on the tool's real schema (non-empty properties),
      # while still letting the permissive fallback ({} properties) build.
      allow(MCP::Tool::InputSchema).to receive(:new).and_wrap_original do |orig, schema|
        props = schema[:properties] || schema['properties']
        raise ArgumentError, 'simulated draft4 incompatibility' if props && !props.empty?

        orig.call(schema)
      end

      tool = ClaudeAgentSDK.create_tool(
        'count', 'Count',
        { type: 'object', properties: { n: { type: 'integer' } }, required: ['n'] }
      ) { |args| { content: [{ type: 'text', text: "n=#{args[:n]}" }] } }
      server3 = described_class.new(name: 'demo3', tools: [tool])

      res = nil
      expect do
        res = rpc(server3, 'tools/call', { name: 'count', arguments: { n: 3 } })
      end.to output(/argument validation disabled/).to_stderr
      expect(res.dig(:result, :content, 0, :text)).to eq('n=3')
      expect(res.dig(:result, :isError)).to eq(false)
    end

    it 'normalizes gem protocol errors on tools/call to in-band isError (version drift guard)' do
      # mcp 0.7.1+/0.18 turned various tool failures back into JSON-RPC
      # protocol errors; handle_message must normalize ANY tools/call error
      # envelope so the model always sees the text.
      tool = ClaudeAgentSDK.create_tool('t', 'T', {}) { |_| { content: [] } }
      server4 = described_class.new(name: 'demo4', tools: [tool])
      allow(server4.mcp_server).to receive(:handle).and_return(
        { jsonrpc: '2.0', id: 0, error: { code: -32_603, message: 'Internal error', data: 'boom detail' } }
      )

      res = server4.handle_message({ jsonrpc: '2.0', id: 9, method: 'tools/call',
                                     params: { name: 't', arguments: {} } })
      expect(res[:error]).to be_nil
      expect(res.dig(:result, :isError)).to eq(true)
      expect(res.dig(:result, :content, 0, :text)).to eq('boom detail')
    end

    it 're-stamps non-gem-safe string ids through handle_message' do
      # The gem rejects ids not matching /\A[a-zA-Z0-9_-]+\z/ with
      # {id: nil, error: -32600}; the bridge swaps in a safe id and restores
      # the original (Python echoes any id verbatim).
      tool = ClaudeAgentSDK.create_tool('echo', 'E', {}) { |_| { content: [{ type: 'text', text: 'ok' }] } }
      server5 = described_class.new(name: 'demo5', tools: [tool])

      res = server5.handle_message({ id: 'req.1:weird', method: 'tools/call',
                                     params: { name: 'echo', arguments: {} } })
      expect(res[:id]).to eq('req.1:weird')
      expect(res.dig(:result, :content, 0, :text)).to eq('ok')
    end

    it 'answers notifications/initialized with an empty result via the Query dispatch shape' do
      # Pin the boundary: the Query dispatch returns {jsonrpc:, result: {}}
      # (Python parity); the gem's notification semantics (nil) must not
      # leak in if this is ever rerouted through handle_message.
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      server6 = described_class.new(name: 'demo6', tools: [])
      query = ClaudeAgentSDK::Query.new(
        transport: transport, is_streaming_mode: true, sdk_mcp_servers: { 'srv' => server6 }
      )
      res = query.send(:handle_sdk_mcp_request, 'srv', { method: 'notifications/initialized' })
      expect(res).to eq({ jsonrpc: '2.0', result: {} })
    end
  end

  describe '#handle_json' do
    it 'exposes correct schema via MCP tools/list for string-keyed schemas' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'save_memory',
        description: 'Save a fact',
        input_schema: {
          'type' => 'object',
          'properties' => { 'fact' => { 'type' => 'string' } },
          'required' => ['fact']
        },
        handler: ->(_) { { content: [{ type: 'text', text: 'ok' }] } }
      )
      server = described_class.new(name: 'test', tools: [tool])

      request = { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }
      response = JSON.parse(server.handle_json(JSON.generate(request)), symbolize_names: true)

      tool_schema = response.dig(:result, :tools, 0, :inputSchema)
      expect(tool_schema[:properties].keys).to contain_exactly(:fact)
      expect(tool_schema[:properties][:fact][:type]).to eq('string')
    end

    it 'exposes correct schema via MCP tools/list for symbol-keyed schemas' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'test',
        description: 'Test',
        input_schema: {
          type: 'object',
          properties: { name: { type: 'string' } },
          required: ['name']
        },
        handler: ->(_) { { content: [{ type: 'text', text: 'ok' }] } }
      )
      server = described_class.new(name: 'test', tools: [tool])

      request = { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }
      response = JSON.parse(server.handle_json(JSON.generate(request)), symbolize_names: true)

      tool_schema = response.dig(:result, :tools, 0, :inputSchema)
      expect(tool_schema[:properties].keys).to contain_exactly(:name)
      expect(tool_schema[:properties][:name][:type]).to eq('string')
    end

    it 'propagates tool errors and non-text content in MCP responses' do
      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'fail_with_image',
        description: 'Return a tool error',
        input_schema: {},
        handler: lambda do |_|
          {
            content: [
              { type: 'text', text: 'tool failed' },
              { type: 'image', data: 'abc123', mimeType: 'image/png' }
            ],
            is_error: true
          }
        end
      )
      server = described_class.new(name: 'test', tools: [tool])

      request = {
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: { name: 'fail_with_image', arguments: {} }
      }
      response = JSON.parse(server.handle_json(JSON.generate(request)), symbolize_names: true)

      expect(response.dig(:result, :isError)).to eq(true)
      expect(response.dig(:result, :content, 0, :type)).to eq('text')
      expect(response.dig(:result, :content, 1, :type)).to eq('image')
      expect(response.dig(:result, :content, 1, :mimeType)).to eq('image/png')
    end
  end
end

RSpec.describe ClaudeAgentSDK, '.create_tool' do
  it 'creates a tool with name, description, and schema' do
    tool = described_class.create_tool('greet', 'Greet user', { name: :string }) do |args|
      { content: [{ type: 'text', text: "Hello, #{args[:name]}!" }] }
    end

    expect(tool).to be_a(ClaudeAgentSDK::SdkMcpTool)
    expect(tool.name).to eq('greet')
    expect(tool.description).to eq('Greet user')
    expect(tool.handler).to be_a(Proc)
  end

  it 'requires a block' do
    expect { described_class.create_tool('test', 'Test', {}) }
      .to raise_error(ArgumentError, /Block required/)
  end

  it 'passes annotations to the tool' do
    annotations = { title: 'My Tool', readOnlyHint: true }
    tool = described_class.create_tool('test', 'Test', {}, annotations: annotations) do |_|
      { content: [] }
    end

    expect(tool.annotations).to eq(annotations)
  end

  it 'defaults annotations to nil' do
    tool = described_class.create_tool('test', 'Test', {}) { |_| { content: [] } }
    expect(tool.annotations).to be_nil
  end

  it 'handler executes correctly' do
    tool = described_class.create_tool('add', 'Add', { a: :number, b: :number }) do |args|
      { content: [{ type: 'text', text: (args[:a] + args[:b]).to_s }] }
    end

    result = tool.handler.call({ a: 2, b: 3 })
    expect(result[:content].first[:text]).to eq('5')
  end
end

RSpec.describe ClaudeAgentSDK, '.create_sdk_mcp_server' do
  it 'creates an SDK MCP server configuration' do
    tool = described_class.create_tool('test', 'Test', {}) { |_| { content: [] } }
    server_config = described_class.create_sdk_mcp_server(name: 'test-server', tools: [tool])

    expect(server_config).to be_a(Hash)
    expect(server_config[:type]).to eq('sdk')
    expect(server_config[:name]).to eq('test-server')
    expect(server_config[:instance]).to be_a(ClaudeAgentSDK::SdkMcpServer)
  end

  it 'defaults version to 1.0.0' do
    server_config = described_class.create_sdk_mcp_server(name: 'test')
    expect(server_config[:instance].version).to eq('1.0.0')
  end

  it 'accepts custom version' do
    server_config = described_class.create_sdk_mcp_server(name: 'test', version: '2.0.0')
    expect(server_config[:instance].version).to eq('2.0.0')
  end

  it 'creates functional calculator example' do
    add_tool = described_class.create_tool('add', 'Add numbers', { a: :number, b: :number }) do |args|
      result = args[:a] + args[:b]
      { content: [{ type: 'text', text: "#{args[:a]} + #{args[:b]} = #{result}" }] }
    end

    server_config = described_class.create_sdk_mcp_server(
      name: 'calculator',
      version: '1.0.0',
      tools: [add_tool]
    )

    server = server_config[:instance]
    tools = server.list_tools
    expect(tools.length).to eq(1)
    expect(tools.first[:name]).to eq('add')

    result = server.call_tool('add', { a: 15, b: 27 })
    expect(result[:content].first[:text]).to eq('15 + 27 = 42')
  end

  it 'makes a Symbol-named tool callable by its string wire name' do
    # tools/call arrives from the CLI with the name as a JSON String; a
    # Symbol name stored verbatim was advertised in tools/list but missed
    # the gem's name-keyed lookup — 'Tool not found' on every invocation.
    tool = described_class.create_tool(:greet, 'Greet', { who: :string }) do |args|
      { content: [{ type: 'text', text: "hi #{args[:who]}" }] }
    end
    server = described_class.create_sdk_mcp_server(name: 'greeter', tools: [tool])[:instance]

    expect(server.list_tools.first[:name]).to eq('greet')
    result = server.call_tool('greet', { who: 'ruby' })
    expect(result[:content].first[:text]).to eq('hi ruby')
  end
end

RSpec.describe ClaudeAgentSDK, '.extract_sdk_mcp_servers' do
  it 'extracts live instances from hash and typed sdk configs, ignoring other server types' do
    server = Object.new
    servers = described_class.extract_sdk_mcp_servers(
      hash_sdk: { type: 'sdk', name: 'a', instance: server },
      # A typed McpSdkServerConfig previously failed the Hash-only guard,
      # so its in-process server was silently never registered.
      typed_sdk: ClaudeAgentSDK::McpSdkServerConfig.new(name: 'b', instance: server),
      http: ClaudeAgentSDK::McpHttpServerConfig.new(url: 'https://example.com/mcp'),
      stdio: { type: 'stdio', command: 'node' }
    )
    expect(servers).to eq(hash_sdk: server, typed_sdk: server)
  end

  it 'returns an empty hash for non-Hash mcp_servers values' do
    expect(described_class.extract_sdk_mcp_servers('path/to/config.json')).to eq({})
    expect(described_class.extract_sdk_mcp_servers(nil)).to eq({})
  end
end
