# frozen_string_literal: true

require 'spec_helper'

# The JSON-RPC conversation the CLI has with an SDK MCP server, which travels
# as `mcp_message` control requests: each example sends one request the way
# the CLI does and checks the frame the SDK writes back. Before this file
# only tools/call and notifications/initialized were ever executed by the
# suite, so an `initialize` answer without protocolVersion — which makes the
# real CLI report the whole in-process server as failed — passed it.
#
# The initialize, notifications/initialized and tools/list requests are the
# frames CLI 2.1.286 sends when it connects to an SDK server; the other
# methods use the same envelope with the parameters the MCP specification
# gives them.
RSpec.describe ClaudeAgentSDK::Query do
  describe 'mcp_message control requests for an SDK MCP server' do
    let(:tool_calls) { [] }
    let(:prompt_calls) { [] }

    let(:add_tool) do
      calls = tool_calls
      ClaudeAgentSDK.create_tool('add', 'Add two numbers', { a: :number, b: :number }) do |args|
        calls << args
        (args[:a] + args[:b]).to_s
      end
    end

    let(:config_resource) do
      ClaudeAgentSDK.create_resource(uri: 'config://app', name: 'App Config', description: 'Current settings',
                                     mime_type: 'text/plain') do
        { contents: [{ uri: 'config://app', mimeType: 'text/plain', text: 'debug=false' }] }
      end
    end

    let(:review_prompt) do
      calls = prompt_calls
      ClaudeAgentSDK.create_prompt(name: 'review', description: 'Code review',
                                   arguments: [{ name: 'focus', description: 'What to look at',
                                                 required: true }]) do |args|
        calls << args
        { messages: [{ role: 'user', content: { type: 'text', text: "Review #{args[:focus]}" } }] }
      end
    end

    let(:full_server) do
      ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: [add_tool], resources: [config_resource],
                                           prompts: [review_prompt])
    end

    # What CLI 2.1.286 sends as the first message to every SDK server.
    let(:initialize_message) do
      { method: 'initialize',
        params: { protocolVersion: '2025-11-25', capabilities: {},
                  clientInfo: { name: 'claude-code', title: 'Claude Code',
                                description: "Anthropic's agentic coding tool",
                                websiteUrl: 'https://claude.com/claude-code', version: '2.1.286' } },
        jsonrpc: '2.0', id: 0 }
    end

    # Sends +message+ to the server registered as +server_name+ and returns
    # the JSON-RPC response the SDK wrote, after checking the envelope: an
    # mcp_message is always answered with a successful control response,
    # whatever the JSON-RPC outcome inside it.
    def mcp_exchange(message, servers: { 'calc' => full_server }, server_name: 'calc')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(mcp_servers: servers)
      reply = ScriptedCLI.session(options) do |cli|
        cli.request({ subtype: 'mcp_message', server_name: server_name, message: message }, request_id: 'req_mcp')
      end
      expect(reply).to include('subtype' => 'success', 'request_id' => 'req_mcp')
      expect(reply.fetch('response').keys).to eq(['mcp_response'])
      reply.dig('response', 'mcp_response')
    end

    describe 'initialize' do
      it 'answers with the protocol version, the capabilities of what the server offers, and its identity' do
        expect(mcp_exchange(initialize_message)).to eq(
          'jsonrpc' => '2.0', 'id' => 0,
          'result' => { 'protocolVersion' => '2024-11-05',
                        'capabilities' => { 'tools' => {}, 'resources' => {}, 'prompts' => {} },
                        'serverInfo' => { 'name' => 'calc', 'version' => '1.0.0' } }
        )
      end

      it 'advertises only tools for a server that has only tools' do
        tools_only = ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', version: '2.3.0', tools: [add_tool])

        result = mcp_exchange(initialize_message, servers: { 'calc' => tools_only }).fetch('result')

        expect(result.fetch('capabilities')).to eq('tools' => {})
        expect(result.fetch('serverInfo')).to eq('name' => 'calc', 'version' => '2.3.0')
        expect(result.fetch('protocolVersion')).to eq('2024-11-05')
      end

      it 'does not advertise tools for a server that has none' do
        no_tools = ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', resources: [config_resource])

        result = mcp_exchange(initialize_message, servers: { 'calc' => no_tools }).fetch('result')

        expect(result.fetch('capabilities')).to eq('resources' => {})
      end
    end

    it 'acknowledges notifications/initialized' do
      response = mcp_exchange({ jsonrpc: '2.0', method: 'notifications/initialized' })

      expect(response).to eq('jsonrpc' => '2.0', 'result' => {})
    end

    it 'lists the tools with their JSON schemas for tools/list' do
      response = mcp_exchange({ method: 'tools/list', jsonrpc: '2.0', id: 1 })

      expect(response).to eq(
        'jsonrpc' => '2.0', 'id' => 1,
        'result' => { 'tools' => [{ 'name' => 'add', 'description' => 'Add two numbers',
                                    'inputSchema' => { 'type' => 'object',
                                                       'properties' => { 'a' => { 'type' => 'number' },
                                                                         'b' => { 'type' => 'number' } },
                                                       'required' => %w[a b] } }] }
      )
    end

    it 'runs the tool for tools/call and returns its content' do
      response = mcp_exchange({ method: 'tools/call', params: { name: 'add', arguments: { a: 2, b: 3 } },
                                jsonrpc: '2.0', id: 2 })

      expect(tool_calls).to eq([{ a: 2, b: 3 }])
      expect(response).to include('jsonrpc' => '2.0', 'id' => 2)
      expect(response).not_to have_key('error')
      expect(response.dig('result', 'content')).to eq([{ 'type' => 'text', 'text' => '5' }])
      expect(response.dig('result', 'isError')).not_to be(true)
    end

    it 'lists the resources for resources/list' do
      response = mcp_exchange({ method: 'resources/list', jsonrpc: '2.0', id: 3 })

      expect(response).to eq(
        'jsonrpc' => '2.0', 'id' => 3,
        'result' => { 'resources' => [{ 'uri' => 'config://app', 'name' => 'App Config',
                                        'description' => 'Current settings', 'mimeType' => 'text/plain' }] }
      )
    end

    it 'reads the resource named by params.uri for resources/read' do
      response = mcp_exchange({ method: 'resources/read', params: { uri: 'config://app' }, jsonrpc: '2.0', id: 4 })

      expect(response).to eq(
        'jsonrpc' => '2.0', 'id' => 4,
        'result' => { 'contents' => [{ 'uri' => 'config://app', 'mimeType' => 'text/plain',
                                       'text' => 'debug=false' }] }
      )
    end

    it 'answers resources/read without a uri with a JSON-RPC internal error' do
      response = mcp_exchange({ method: 'resources/read', params: {}, jsonrpc: '2.0', id: 5 })

      expect(response).to eq('jsonrpc' => '2.0', 'id' => 5,
                             'error' => { 'code' => -32_603, 'message' => 'Missing uri parameter for resources/read' })
    end

    it 'lists the prompts with their arguments for prompts/list' do
      response = mcp_exchange({ method: 'prompts/list', jsonrpc: '2.0', id: 6 })

      expect(response).to eq(
        'jsonrpc' => '2.0', 'id' => 6,
        'result' => { 'prompts' => [{ 'name' => 'review', 'description' => 'Code review',
                                      'arguments' => [{ 'name' => 'focus', 'description' => 'What to look at',
                                                        'required' => true }] }] }
      )
    end

    it 'renders the prompt named by params.name with params.arguments for prompts/get' do
      response = mcp_exchange({ method: 'prompts/get', params: { name: 'review', arguments: { focus: 'the diff' } },
                                jsonrpc: '2.0', id: 7 })

      expect(prompt_calls).to eq([{ focus: 'the diff' }])
      expect(response).to eq(
        'jsonrpc' => '2.0', 'id' => 7,
        'result' => { 'messages' => [{ 'role' => 'user',
                                       'content' => { 'type' => 'text', 'text' => 'Review the diff' } }] }
      )
    end

    it 'answers prompts/get without a name with a JSON-RPC internal error' do
      response = mcp_exchange({ method: 'prompts/get', params: { arguments: { focus: 'the diff' } },
                                jsonrpc: '2.0', id: 8 })

      expect(prompt_calls).to be_empty
      expect(response).to eq('jsonrpc' => '2.0', 'id' => 8,
                             'error' => { 'code' => -32_603, 'message' => 'Missing name parameter for prompts/get' })
    end

    it 'answers a method it does not implement with method-not-found' do
      response = mcp_exchange({ method: 'completion/complete', params: {}, jsonrpc: '2.0', id: 9 })

      expect(response).to eq('jsonrpc' => '2.0', 'id' => 9,
                             'error' => { 'code' => -32_601, 'message' => "Method 'completion/complete' not found" })
    end

    it 'answers a request for a server it does not have with method-not-found' do
      response = mcp_exchange({ method: 'tools/list', jsonrpc: '2.0', id: 10 }, server_name: 'other')

      expect(response).to eq('jsonrpc' => '2.0', 'id' => 10,
                             'error' => { 'code' => -32_601, 'message' => "Server 'other' not found" })
    end
  end
end
