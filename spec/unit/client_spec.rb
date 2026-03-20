# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::Client do
  it 'always connects in streaming mode (stdin stays open)' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)

    received_options = nil

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |options|
      received_options = options
      transport
    end
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect

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
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |options|
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

  it 'raises when reconnecting MCP server while not connected' do
    client = described_class.new
    expect { client.reconnect_mcp_server('my-server') }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
  end

  it 'delegates reconnect_mcp_server when connected' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true, initialize_protocol: true,
      reconnect_mcp_server: nil
    )
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect
    client.reconnect_mcp_server('my-server')
    expect(query_handler).to have_received(:reconnect_mcp_server).with('my-server')
  end

  it 'raises when toggling MCP server while not connected' do
    client = described_class.new
    expect { client.toggle_mcp_server('my-server', true) }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
  end

  it 'delegates toggle_mcp_server when connected' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true, initialize_protocol: true,
      toggle_mcp_server: nil
    )
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect
    client.toggle_mcp_server('my-server', false)
    expect(query_handler).to have_received(:toggle_mcp_server).with('my-server', false)
  end

  it 'raises when stopping task while not connected' do
    client = described_class.new
    expect { client.stop_task('task_1') }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
  end

  it 'delegates stop_task when connected' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true, initialize_protocol: true,
      stop_task: nil
    )
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect
    client.stop_task('task_abc')
    expect(query_handler).to have_received(:stop_task).with('task_abc')
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

  context 'with custom transport_class' do
    let(:query_handler) do
      instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true, close: nil)
    end

    before do
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)
    end

    # Build an anonymous Transport subclass that captures its initialize arguments
    # via the provided block and stubs all interface methods.
    def build_transport_class(&on_initialize)
      Class.new(ClaudeAgentSDK::Transport) do
        define_method(:initialize, &on_initialize)
        define_method(:connect) { nil }
        define_method(:write) { |_data| nil }
        define_method(:read_messages) { nil }
        define_method(:close) { nil }
        define_method(:ready?) { true }
        define_method(:end_input) { nil }
      end
    end

    it 'uses custom transport_class instead of SubprocessCLITransport' do
      received_args = nil
      klass = build_transport_class { |options, **kwargs| received_args = { options: options, kwargs: kwargs } }

      client = described_class.new(transport_class: klass)
      client.connect

      expect(received_args[:options]).to be_a(ClaudeAgentSDK::ClaudeAgentOptions)
      expect(received_args[:kwargs]).to eq({})
    end

    it 'passes transport_args as keyword arguments to transport_class.new' do
      received_args = nil
      klass = build_transport_class { |options, **kwargs| received_args = { options: options, kwargs: kwargs } }

      client = described_class.new(
        transport_class: klass,
        transport_args: { sandbox: 'my-sandbox', timeout: 30 }
      )
      client.connect

      expect(received_args[:kwargs]).to eq({ sandbox: 'my-sandbox', timeout: 30 })
    end

    it 'still performs option transformations with custom transport' do
      received_options = nil
      klass = build_transport_class { |options, **_kwargs| received_options = options }

      callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)
      client = described_class.new(options: options, transport_class: klass)
      client.connect

      expect(received_options.permission_prompt_tool_name).to eq('stdio')
      expect(received_options.env['CLAUDE_CODE_ENTRYPOINT']).to eq('sdk-rb-client')
    end

    it 'defaults transport_class to SubprocessCLITransport' do
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)

      client = described_class.new
      client.connect

      expect(ClaudeAgentSDK::SubprocessCLITransport).to have_received(:new)
    end
  end

  context 'with default configuration' do
    after { ClaudeAgentSDK.reset_configuration }

    before do
      ClaudeAgentSDK.configure do |config|
        config.default_options = {
          model: 'sonnet',
          permission_mode: 'bypassPermissions',
          env: { 'API_KEY' => 'configured_key' }
        }
      end
    end

    it 'uses configured defaults when no options provided' do
      client = described_class.new
      options = client.instance_variable_get(:@options)

      expect(options.model).to eq('sonnet')
      expect(options.permission_mode).to eq('bypassPermissions')
      expect(options.env['API_KEY']).to eq('configured_key')
    end

    it 'merges provided options with defaults' do
      override_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        model: 'opus',
        env: { 'OVERRIDE_KEY' => 'override_value' }
      )
      client = described_class.new(options: override_options)
      options = client.instance_variable_get(:@options)

      expect(options.model).to eq('opus') # override
      expect(options.permission_mode).to eq('bypassPermissions') # from default
      expect(options.env['API_KEY']).to eq('configured_key') # from default
      expect(options.env['OVERRIDE_KEY']).to eq('override_value') # from provided
    end

    it 'passes merged options to transport' do
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
      query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)

      received_options = nil
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |options|
        received_options = options
        transport
      end
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

      client = described_class.new
      client.connect

      expect(received_options.model).to eq('sonnet')
      expect(received_options.permission_mode).to eq('bypassPermissions')
    end
  end
end
