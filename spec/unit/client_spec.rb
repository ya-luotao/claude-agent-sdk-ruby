# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::Client do
  it 'always connects in streaming mode (stdin stays open)' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)

    received_prompt = nil
    received_options = nil

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |prompt, options|
      received_prompt = prompt
      received_options = options
      transport
    end
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect

    expect(received_prompt).not_to be_a(String)
    expect(received_prompt).to respond_to(:each)
    expect(received_options).to be_a(ClaudeAgentSDK::ClaudeAgentOptions)
    expect(received_options.env['CLAUDE_CODE_ENTRYPOINT']).to eq('sdk-rb-client')
  end

  it 'sends an initial String prompt as a user message after connecting' do
    writes = []
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true)
    allow(transport).to receive(:write) { |data| writes << data }

    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect('hello')

    expect(writes.length).to eq(1)
    payload = JSON.parse(writes.first, symbolize_names: true)
    expect(payload[:type]).to eq('user')
    expect(payload.dig(:message, :content)).to eq('hello')
  end

  it 'streams an initial Enumerator prompt without closing stdin' do
    writes = []
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true)
    allow(transport).to receive(:write) { |data| writes << data }

    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    stream = ['{"type":"user"}', '{"type":"user"}'].to_enum

    client = described_class.new
    client.connect(stream)

    expect(writes).to eq(["{\"type\":\"user\"}\n", "{\"type\":\"user\"}\n"])
  end

  it 'auto-configures permission prompt tool when using can_use_tool' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)

    received_options = nil
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |_prompt, options|
      received_options = options
      transport
    end
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)
    client = described_class.new(options: options)
    client.connect

    expect(received_options.permission_prompt_tool_name).to eq('stdio')
    expect(received_options.env['CLAUDE_CODE_ENTRYPOINT']).to eq('sdk-rb-client')
  end

  it 'does not mutate global CLAUDE_CODE_ENTRYPOINT' do
    original_entrypoint = ENV['CLAUDE_CODE_ENTRYPOINT']
    ENV.delete('CLAUDE_CODE_ENTRYPOINT')

    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect

    expect(ENV['CLAUDE_CODE_ENTRYPOINT']).to be_nil
  ensure
    if original_entrypoint.nil?
      ENV.delete('CLAUDE_CODE_ENTRYPOINT')
    else
      ENV['CLAUDE_CODE_ENTRYPOINT'] = original_entrypoint
    end
  end

  it 'raises when requesting MCP status while not connected' do
    client = described_class.new
    expect { client.get_mcp_status }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
  end

  it 'delegates MCP status request when connected' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: true,
      get_mcp_status: { mcpServers: [{ name: 'tools', status: 'connected' }] }
    )

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect

    expect(client.get_mcp_status).to eq({ mcpServers: [{ name: 'tools', status: 'connected' }] })
  end

  it 'raises when requesting server info while not connected' do
    client = described_class.new
    expect { client.get_server_info }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
  end

  it 'returns initialization info via get_server_info when connected' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect

    query_handler.instance_variable_set(:@initialization_result, { commands: ['help'] })
    expect(client.get_server_info).to eq({ commands: ['help'] })
  end
end
