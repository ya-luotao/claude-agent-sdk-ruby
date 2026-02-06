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

    it 'handles pre-formatted JSON schemas' do
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

    it 'raises error for unknown tool' do
      server = described_class.new(name: 'test')
      expect { server.call_tool('unknown', {}) }
        .to raise_error(/Tool 'unknown' not found/)
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

    it 'raises error if handler returns invalid format' do
      handler = ->(_) { 'invalid' } # Should return hash with :content

      tool = ClaudeAgentSDK::SdkMcpTool.new(
        name: 'bad',
        description: 'Bad',
        input_schema: {},
        handler: handler
      )

      server = described_class.new(name: 'test', tools: [tool])
      expect { server.call_tool('bad', {}) }
        .to raise_error(/must return a hash with :content key/)
    end
  end

  describe '#handle_json' do
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
end
