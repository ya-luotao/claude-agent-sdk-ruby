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
  end
end

