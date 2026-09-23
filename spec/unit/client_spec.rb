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
    # CLAUDE_CODE_ENTRYPOINT is now set as a default-if-absent by the transport layer
    expect(received_options.env).not_to have_key('CLAUDE_CODE_ENTRYPOINT')
  end

  it 'passes forward_subagent_text through to the Query handler' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)

    [true, false].each do |enabled|
      captured = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        captured = kwargs
        query_handler
      end

      described_class.new(
        options: ClaudeAgentSDK::ClaudeAgentOptions.new(forward_subagent_text: enabled)
      ).connect

      expect(captured[:forward_subagent_text]).to be(enabled)
    end
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

  it 'rejects a bare Hash initial prompt before resolving observers or constructing a transport' do
    factory = double('observer factory')
    expect(factory).not_to receive(:call)
    expect(ClaudeAgentSDK::SubprocessCLITransport).not_to receive(:new)
    client = described_class.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [factory]))

    expect { client.connect({ type: 'user', message: { content: 'hello' } }) }
      .to raise_error(ArgumentError, /got Hash/)
  end

  describe 'hook normalization on connect' do
    let(:query_handler) { instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true) }

    before do
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil)
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)
    end

    it 'omits nil and empty lists while preserving active matcher callbacks and timeouts' do
      callback = ->(*) { {} }
      matcher = ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [callback], timeout: 7)
      hooks = { 'PostToolUse' => nil, 'Stop' => [], PreToolUse: [matcher] }
      described_class.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new(hooks: hooks)).connect

      expect(ClaudeAgentSDK::Query).to have_received(:new).with(hash_including(
                                                                  hooks: { 'PreToolUse' => [{ matcher: 'Bash', hooks: [callback], timeout: 7 }] }
                                                                ))
      expect(hooks).to eq('PostToolUse' => nil, 'Stop' => [], PreToolUse: [matcher])
    end

    it 'passes nil when no active hook lists remain' do
      described_class.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new(
        hooks: { 'PreToolUse' => nil, 'PostToolUse' => [] }
      )).connect

      expect(ClaudeAgentSDK::Query).to have_received(:new).with(hash_including(hooks: nil))
    end
  end

  it 'streams an initial Enumerator prompt in the background via Query#stream_input' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)
    streamed = nil
    allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
    allow(query_handler).to receive(:stream_input) { |stream| streamed = stream.to_a }
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    stream = ['{"type":"user"}', '{"type":"user"}'].to_enum

    client = described_class.new
    client.connect(stream)

    # Items reach stream_input unchanged (it owns serialization — Hashes are
    # JSON-generated there, fixing the old to_s/inspect bug).
    expect(streamed).to eq(['{"type":"user"}', '{"type":"user"}'])
  end

  it 'serializes Hash stream messages as JSON via stream_input (not Ruby inspect)' do
    writes = []
    transport = mock_transport
    allow(transport).to receive(:write) { |data| writes << data }
    query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true)

    Async do |task|
      task.with_timeout(2.0) do
        query.stream_input([{ type: 'user', message: { role: 'user', content: 'hi' } }])
      end
    end.wait

    payload = JSON.parse(writes.first, symbolize_names: true)
    expect(payload[:type]).to eq('user')
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
    expect(received_options.env).not_to have_key('CLAUDE_CODE_ENTRYPOINT')
  end

  # query() and Client#connect share ClaudeAgentSDK.configure_can_use_tool,
  # so the mutual-exclusion rule is enforced identically at both entry points.
  it 'rejects can_use_tool combined with permission_prompt_tool_name' do
    callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      can_use_tool: callback, permission_prompt_tool_name: 'mcp__auth__prompt'
    )
    client = described_class.new(options: options)

    expect { client.connect }.to raise_error(ArgumentError, /cannot be used with permission_prompt_tool_name/)
  end

  it 'warns on connect when can_use_tool is shadowed by allowed_tools' do
    ClaudeAgentSDK::OptionWarnings.reset!
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback, allowed_tools: ['Read'])
    client = described_class.new(options: options)

    expect { client.connect }.to output(/can_use_tool will not be invoked for: Read/).to_stderr
  ensure
    ClaudeAgentSDK::OptionWarnings.reset!
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

  it 'passes agent_progress_summaries through to the Query handler, preserving nil vs false' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)

    [true, false, nil].each do |value|
      captured = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        captured = kwargs
        query_handler
      end

      described_class.new(
        options: ClaudeAgentSDK::ClaudeAgentOptions.new(agent_progress_summaries: value)
      ).connect

      expect(captured).to have_key(:agent_progress_summaries)
      expect(captured[:agent_progress_summaries]).to be(value)
    end
  end

  it 'raises when backgrounding tasks while not connected' do
    client = described_class.new
    expect { client.background_tasks }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
    expect { client.background_tasks(tool_use_id: 'toolu_1') }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
  end

  it 'checks the connection before validating the background_tasks selector' do
    expect { described_class.new.background_tasks(tool_use_id: '') }
      .to raise_error(ClaudeAgentSDK::CLIConnectionError)
  end

  it 'rejects an empty background_tasks selector when connected, writing nothing' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    query_handler = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true)
    allow(query_handler).to receive_messages(start: true, initialize_protocol: true)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    # Recorder instead of the real control path: a regressed guard then fails
    # here at once rather than parking on the default control timeout.
    sent = []
    allow(query_handler).to receive(:send_control_request) do |request|
      sent << request
      {}
    end

    client = described_class.new
    client.connect
    expect { client.background_tasks(tool_use_id: '') }.to raise_error(ArgumentError, /pass nil explicitly/)
    expect(sent).to be_empty
    expect(transport).not_to have_received(:write)
  end

  # Through the real Query response handler: the Client must hand back a
  # definitive targeted miss as-is, never as success.
  [{ backgrounded: false }, { backgrounded: true }].each do |payload|
    it "returns #{payload.inspect} from a targeted background_tasks unchanged" do
      written = []
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true)
      allow(transport).to receive(:write) { |line| written << JSON.parse(line) }
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      query_handler = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true)
      allow(query_handler).to receive_messages(start: true, initialize_protocol: true)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

      client = described_class.new
      client.connect

      result = nil
      Async do |task|
        task.with_timeout(2.0) do
          sender = task.async { client.background_tasks(tool_use_id: 'toolu_42') }
          task.sleep 0.01 until written.any?
          query_handler.send(:handle_control_response,
                             { type: 'control_response',
                               response: { subtype: 'success', request_id: written.first.fetch('request_id'),
                                           response: payload } })
          result = sender.wait
        end
      end.wait

      expect(result).to eq(payload)
      expect(result[:backgrounded]).to be(payload[:backgrounded])
      expect(written.first.fetch('request')).to eq('subtype' => 'background_tasks', 'tool_use_id' => 'toolu_42')
    end
  end

  it 'delegates background_tasks when connected and returns the CLI payload' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)
    allow(query_handler).to receive(:background_tasks).with(tool_use_id: nil).and_return({})
    allow(query_handler).to receive(:background_tasks).with(tool_use_id: 'toolu_42').and_return({ backgrounded: true })
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    client = described_class.new
    client.connect
    expect(client.background_tasks).to eq({})
    expect(client.background_tasks(tool_use_id: 'toolu_42')).to eq({ backgrounded: true })
    expect(query_handler).to have_received(:background_tasks).with(tool_use_id: nil)
    expect(query_handler).to have_received(:background_tasks).with(tool_use_id: 'toolu_42')
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

  describe 'Ruby-style aliases of the parity names' do
    let(:query_handler) do
      instance_double(
        ClaudeAgentSDK::Query,
        start: true, initialize_protocol: true, set_model: nil, set_permission_mode: nil,
        get_context_usage: { totalTokens: 1200 }, get_mcp_status: { mcpServers: [] }
      )
    end

    def connected_client
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)
      described_class.new.tap(&:connect)
    end

    it '#model= sends the set_model control request and evaluates to the assigned value' do
      client = connected_client

      expect(client.model = 'claude-opus-5').to eq('claude-opus-5')
      expect(query_handler).to have_received(:set_model).with('claude-opus-5')
    end

    it '#model= accepts nil (back to the default model), like #set_model' do
      client = connected_client
      client.model = nil

      expect(query_handler).to have_received(:set_model).with(nil)
    end

    it '#permission_mode= sends the set_permission_mode control request' do
      client = connected_client

      expect(client.permission_mode = 'plan').to eq('plan')
      expect(query_handler).to have_received(:set_permission_mode).with('plan')
    end

    it '#context_usage and #mcp_status return what the get_ forms return' do
      client = connected_client

      expect(client.context_usage).to eq(totalTokens: 1200)
      expect(client.mcp_status).to eq(mcpServers: [])
    end

    it 'route through the parity methods, so an override of those applies to both spellings' do
      client = connected_client
      allow(client).to receive(:set_model)
      allow(client).to receive(:get_mcp_status).and_return(:overridden)

      client.model = 'haiku'

      expect(client).to have_received(:set_model).with('haiku')
      expect(client.mcp_status).to eq(:overridden)
    end

    it 'raise CLIConnectionError while not connected, like the parity names' do
      client = described_class.new

      expect { client.model = 'haiku' }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
      expect { client.permission_mode = 'plan' }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
      expect { client.context_usage }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
      expect { client.mcp_status }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
    end
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

    allow(query_handler).to receive(:initialization_result).and_return({ commands: ['help'] })
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
      expect(received_options.env).not_to have_key('CLAUDE_CODE_ENTRYPOINT')
    end

    it 'defaults transport_class to SubprocessCLITransport' do
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil)
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)

      client = described_class.new
      client.connect

      expect(ClaudeAgentSDK::SubprocessCLITransport).to have_received(:new)
    end
  end

  context 'with exclude_dynamic_sections' do
    let(:transport) { instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil) }
    let(:query_handler) { instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true) }

    before do
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    end

    it 'passes exclude_dynamic_sections from SystemPromptPreset to Query' do
      received_kwargs = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        received_kwargs = kwargs
        query_handler
      end

      preset = ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', exclude_dynamic_sections: true)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: preset)
      client = described_class.new(options: options)
      client.connect

      expect(received_kwargs[:exclude_dynamic_sections]).to eq(true)
    end

    it 'passes exclude_dynamic_sections from Hash with symbol keys to Query' do
      received_kwargs = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        received_kwargs = kwargs
        query_handler
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        system_prompt: { type: 'preset', preset: 'claude_code', exclude_dynamic_sections: true }
      )
      client = described_class.new(options: options)
      client.connect

      expect(received_kwargs[:exclude_dynamic_sections]).to eq(true)
    end

    it 'handles false correctly from Hash with symbol keys' do
      received_kwargs = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        received_kwargs = kwargs
        query_handler
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        system_prompt: { type: 'preset', preset: 'claude_code', exclude_dynamic_sections: false }
      )
      client = described_class.new(options: options)
      client.connect

      expect(received_kwargs[:exclude_dynamic_sections]).to eq(false)
    end

    it 'passes nil when system_prompt is a plain string' do
      received_kwargs = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        received_kwargs = kwargs
        query_handler
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: 'You are a helper')
      client = described_class.new(options: options)
      client.connect

      expect(received_kwargs[:exclude_dynamic_sections]).to be_nil
    end
  end

  # Python #1268: connect() hands the system prompt's snapshot to Query only
  # for the preset and custom forms; String and file prompts have none.
  context 'with system prompt snapshot' do
    let(:transport) { instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil) }
    let(:query_handler) { instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true) }

    before do
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    end

    def snapshot_passed_to_query(system_prompt)
      received_kwargs = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        received_kwargs = kwargs
        query_handler
      end

      client = described_class.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: system_prompt))
      client.connect
      received_kwargs.fetch(:system_prompt_snapshot)
    end

    {
      'custom Hash with snapshot false' => [{ type: 'custom', prompt: 'Be helpful', snapshot: false }, false],
      'preset Hash with snapshot true' => [{ type: 'preset', preset: 'claude_code', snapshot: true }, true],
      'preset Hash with string keys and snapshot false' =>
        [{ 'type' => 'preset', 'preset' => 'claude_code', 'snapshot' => false }, false],
      'preset Hash without snapshot' => [{ type: 'preset', preset: 'claude_code' }, nil],
      'file Hash (snapshot ignored)' => [{ type: 'file', path: '/p.md', snapshot: false }, nil],
      'plain String' => ['Be helpful', nil],
      'nil system_prompt' => [nil, nil]
    }.each do |label, (system_prompt, expected)|
      it "passes #{expected.inspect} for a #{label}" do
        expect(snapshot_passed_to_query(system_prompt)).to be(expected)
      end
    end

    it 'passes snapshot from SystemPromptCustom and SystemPromptPreset objects' do
      custom = ClaudeAgentSDK::SystemPromptCustom.new(prompt: 'Be helpful', snapshot: false)
      preset = ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', snapshot: true)

      expect(snapshot_passed_to_query(custom)).to be(false)
      expect(snapshot_passed_to_query(preset)).to be(true)
    end

    it 'ignores a non-boolean snapshot' do
      expect(snapshot_passed_to_query({ type: 'custom', prompt: 'x', snapshot: 'yes' })).to be_nil
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
  describe 'Client#query with an iterable (F7)' do
    def connected_client_capturing(writes)
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil)
      allow(transport).to receive(:write) { |data| writes << data }
      query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true, close: nil)
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)
      client = described_class.new
      client.connect
      client
    end

    it 'streams Hashes inline, stamping session_id only when absent' do
      writes = []
      client = connected_client_capturing(writes)

      client.query([
                     { type: 'user', message: { role: 'user', content: 'one' } },
                     { type: 'user', message: { role: 'user', content: 'two' }, session_id: 'explicit' }
                   ], session_id: 'sess-9')

      frames = writes.map { |w| JSON.parse(w, symbolize_names: true) }
      expect(frames[0][:session_id]).to eq('sess-9')
      expect(frames[1][:session_id]).to eq('explicit')
    end

    it 'passes JSONL strings through verbatim and rejects other item types' do
      writes = []
      client = connected_client_capturing(writes)

      jsonl = ClaudeAgentSDK::Streaming.user_message('pre-serialized')
      client.query([jsonl])
      expect(JSON.parse(writes.first, symbolize_names: true).dig(:message, :content)).to eq('pre-serialized')

      expect { client.query([42]) }.to raise_error(ArgumentError, /stream items must be Hashes or JSONL Strings/)
    end

    it 'rejects a bare Hash prompt (would iterate key-value pairs)' do
      client = connected_client_capturing([])
      expect { client.query({ type: 'user' }) }.to raise_error(ArgumentError, /got Hash/)
    end
  end

  describe 'Client.open (F10)' do
    it 'connects, yields the client, disconnects, and returns the block value' do
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil, close: nil)
      query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true, close: nil)
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

      yielded = nil
      result = described_class.open(options: ClaudeAgentSDK::ClaudeAgentOptions.new) do |client|
        yielded = client
        :block_value
      end

      expect(result).to eq(:block_value)
      expect(yielded).to be_a(described_class)
      expect(query_handler).to have_received(:close) # disconnect ran
    end

    it 'disconnects even when the block raises, and propagates the exception' do
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil, close: nil)
      query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true, close: nil)
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

      expect do
        described_class.open { |_client| raise 'block boom' }
      end.to raise_error(RuntimeError, 'block boom')
      expect(query_handler).to have_received(:close)
    end

    it 'requires a block' do
      expect { described_class.open }.to raise_error(ArgumentError, /requires a block/)
    end
  end

  describe 'observer on_error wiring' do
    let(:recording_observer) do
      Class.new do
        include ClaudeAgentSDK::Observer

        attr_reader :errors, :closed

        def initialize
          @errors = []
          @closed = false
        end

        def on_error(error)
          @errors << error
        end

        def on_close
          @closed = true
        end
      end.new
    end

    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [recording_observer]) }

    def stub_connectable(query_handler_overrides = {})
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil, close: nil)
      query_handler = instance_double(
        ClaudeAgentSDK::Query,
        { start: true, initialize_protocol: true, close: nil }.merge(query_handler_overrides)
      )
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)
      [transport, query_handler]
    end

    it 'receive_messages notifies on_error, re-raises, and on_close only fires at disconnect' do
      _, query_handler = stub_connectable
      msg = sample_assistant_message
      allow(query_handler).to receive(:receive_messages) do |&block|
        block.call(msg)
        raise ClaudeAgentSDK::ProcessError.new('Command failed', exit_code: 1)
      end

      client = described_class.new(options: options)
      client.connect

      expect { client.receive_messages { |_m| nil } }.to raise_error(ClaudeAgentSDK::ProcessError)
      expect(recording_observer.errors.length).to eq(1)
      expect(recording_observer.closed).to be false

      client.disconnect
      expect(recording_observer.closed).to be true
    end

    it 'receive_response notifies on_error and re-raises' do
      _, query_handler = stub_connectable
      allow(query_handler).to receive(:receive_messages)
        .and_raise(ClaudeAgentSDK::ProcessError.new('Command failed', exit_code: 1))

      client = described_class.new(options: options)
      client.connect

      expect { client.receive_response { |_m| nil } }.to raise_error(ClaudeAgentSDK::ProcessError)
      expect(recording_observer.errors.length).to eq(1)
    end

    it 'does not notify on_error for the Not-connected usage guard' do
      client = described_class.new(options: options)

      expect { client.receive_messages { |_m| nil } }
        .to raise_error(ClaudeAgentSDK::CLIConnectionError, /Not connected/)
      expect(recording_observer.errors).to be_empty
    end

    it 'Client#query notifies on_error when the stdin write fails' do
      transport, = stub_connectable
      client = described_class.new(options: options)
      client.connect
      allow(transport).to receive(:write)
        .and_raise(ClaudeAgentSDK::CLIConnectionError, 'not ready')

      expect { client.query('hi') }.to raise_error(ClaudeAgentSDK::CLIConnectionError, 'not ready')
      expect(recording_observer.errors.length).to eq(1)
    end

    it 'connect failure notifies on_error without on_close' do
      stub_connectable
      # Override: initialize_protocol raises -> pre-handshake failure
      allow(ClaudeAgentSDK::Query).to receive(:new) do
        instance_double(ClaudeAgentSDK::Query, start: true, close: nil).tap do |qh|
          allow(qh).to receive(:initialize_protocol)
            .and_raise(ClaudeAgentSDK::ProcessError.new('Command failed', exit_code: 1))
        end
      end

      client = described_class.new(options: options)

      expect { client.connect }.to raise_error(ClaudeAgentSDK::ProcessError)
      expect(recording_observer.errors.length).to eq(1)
      expect(recording_observer.closed).to be false
    end

    it 'resume materialization failure during connect notifies on_error' do
      stub_connectable
      allow(ClaudeAgentSDK::SessionStores).to receive(:validate_session_store_options)
      store_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        observers: [recording_observer],
        session_store: ClaudeAgentSDK::InMemorySessionStore.new,
        resume: 'sess-1'
      )
      allow(ClaudeAgentSDK::SessionResume).to receive(:materialize_resume_session)
        .and_raise(ClaudeAgentSDK::ClaudeSDKError, 'store backend down')

      client = described_class.new(options: store_options)

      expect { client.connect }.to raise_error(ClaudeAgentSDK::ClaudeSDKError, 'store backend down')
      expect(recording_observer.errors.length).to eq(1)
    end

    it 'String-prompt send failure during connect notifies on_error exactly once' do
      transport, = stub_connectable
      allow(transport).to receive(:write)
        .and_raise(ClaudeAgentSDK::CLIConnectionError, 'write failed')

      client = described_class.new(options: options)

      expect { client.connect('hello') }.to raise_error(ClaudeAgentSDK::CLIConnectionError, 'write failed')
      expect(recording_observer.errors.length).to eq(1)
    end
  end

  describe 'observer on_user_prompt for streaming connect' do
    it 'fires on_user_prompt for user messages with extractable text only' do
      prompt_observer = Class.new do
        include ClaudeAgentSDK::Observer

        attr_reader :prompts

        def initialize
          @prompts = []
        end

        def on_user_prompt(prompt)
          @prompts << prompt
        end
      end.new

      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil, close: nil)
      query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true, close: nil)
      allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
      allow(query_handler).to receive(:stream_input, &:to_a)
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

      stream = [
        JSON.generate(type: 'user', message: { role: 'user', content: 'streamed question' }),
        JSON.generate(type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't' }] })
      ].to_enum

      client = described_class.new(
        options: ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [prompt_observer])
      )
      client.connect(stream)

      expect(prompt_observer.prompts).to eq(['streamed question'])
    end
  end

  # L7: input-stream errors are swallowed by streaming input (warn only,
  # Python parity) and observers are NOT notified — the documented
  # Observer#on_error contract. connect used to wrap the initial prompt in a
  # notifying enumerator, firing on_error for an error that didn't surface
  # (and marking a still-live OTel trace as failed); query() never did.
  describe 'initial prompt stream errors and observers' do
    it 'does not notify on_error for a raising initial Enumerator prompt' do
      errors = []
      observer = Class.new do
        include ClaudeAgentSDK::Observer

        def initialize(sink) = (@sink = sink)
        def on_error(error) = @sink << error
      end.new(errors)

      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, write: nil, close: nil)
      query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true, close: nil)
      allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
      allow(query_handler).to receive(:stream_input) do |stream|
        # Emulate the real stream_input's swallow-with-warn handling.
        stream.each { |_m| nil }
      rescue StandardError
        nil
      end
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

      failing = Enumerator.new do |y|
        y << { type: 'user', message: { role: 'user', content: 'hi' } }
        raise 'stream boom'
      end

      client = described_class.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer]))
      expect { client.connect(failing) }.not_to raise_error
      expect(errors).to be_empty
    end
  end

  # M16: a dropped mirror batch means the store copy is incomplete and the
  # materialized temp dir holds the only copy of those turns — disconnect must
  # preserve it (scrubbed of credentials) instead of deleting it.
  describe '#disconnect with a materialized resume' do
    def client_with(handler, materialized)
      client = described_class.new
      client.instance_variable_set(:@query_handler, handler)
      client.instance_variable_set(:@materialized, materialized)
      client
    end

    it 'preserves the temp dir when the mirror dropped batches' do
      handler = instance_double(ClaudeAgentSDK::Query, close: nil, mirror_batches_dropped?: true)
      materialized = instance_double(ClaudeAgentSDK::MaterializedResume, cleanup: nil, preserve_transcripts: nil)

      client_with(handler, materialized).disconnect

      expect(handler).to have_received(:close)
      expect(materialized).to have_received(:preserve_transcripts)
      expect(materialized).not_to have_received(:cleanup)
    end

    it 'cleans up the temp dir when no batches were dropped' do
      handler = instance_double(ClaudeAgentSDK::Query, close: nil, mirror_batches_dropped?: false)
      materialized = instance_double(ClaudeAgentSDK::MaterializedResume, cleanup: nil, preserve_transcripts: nil)

      client_with(handler, materialized).disconnect

      expect(materialized).to have_received(:cleanup)
      expect(materialized).not_to have_received(:preserve_transcripts)
    end
  end
end
