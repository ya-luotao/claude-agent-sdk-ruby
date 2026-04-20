# frozen_string_literal: true

require 'spec_helper'

# The SDK depends on `async`, which installs a Fiber scheduler. If that
# scheduler is visible to user-supplied callbacks, any IO those callbacks
# perform (notably PostgreSQL via ActiveRecord) is intercepted by the
# scheduler and can corrupt results. The SDK's job is to keep the scheduler
# contained inside the SDK itself — user callbacks always see a plain
# thread with `Fiber.scheduler == nil`.
RSpec.describe 'Fiber scheduler boundary' do
  def stub_query_handler_yielding(*messages)
    handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(handler).to receive(:receive_messages) do |&block|
      messages.each { |m| block.call(m) }
    end
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(handler)
    handler
  end

  def stub_transport
    transport = instance_double(
      ClaudeAgentSDK::SubprocessCLITransport,
      connect: true, close: nil, end_input: nil
    )
    allow(transport).to receive(:write)
    allow(transport).to receive(:read_messages)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    transport
  end

  describe 'ClaudeAgentSDK.query { |message| ... }' do
    it 'invokes the user block without a Fiber scheduler' do
      stub_transport
      stub_query_handler_yielding(
        { type: 'assistant', message: { role: 'assistant', model: 'claude', content: [{ type: 'text', text: 'hi' }] } }
      )

      captured_scheduler = :unset
      ClaudeAgentSDK.query(prompt: 'hi') do |_message|
        captured_scheduler = Fiber.scheduler
      end

      expect(captured_scheduler).to be_nil
    end

    it 're-raises errors from the worker on the caller thread' do
      stub_transport
      handler = stub_query_handler_yielding
      allow(handler).to receive(:receive_messages).and_raise(RuntimeError, 'worker boom')

      expect { ClaudeAgentSDK.query(prompt: 'hi') { |_m| next } }.to raise_error(RuntimeError, 'worker boom')
    end
  end

  describe 'ClaudeAgentSDK::Client#receive_messages { |message| ... }' do
    it 'invokes the user block without a Fiber scheduler' do
      stub_transport
      stub_query_handler_yielding(
        { type: 'assistant', message: { role: 'assistant', model: 'claude', content: [{ type: 'text', text: 'hi' }] } },
        { type: 'result', subtype: 'success', duration_ms: 1, duration_api_ms: 1, is_error: false, num_turns: 1,
          session_id: 's', total_cost_usd: 0 }
      )

      client = ClaudeAgentSDK::Client.new
      client.connect

      captured_scheduler = :unset
      client.receive_response { |_msg| captured_scheduler = Fiber.scheduler }

      expect(captured_scheduler).to be_nil
    ensure
      client&.disconnect
    end
  end

  describe 'SDK MCP tool handler' do
    it 'is invoked without a Fiber scheduler when called from inside an Async reactor' do
      captured = :unset
      tool = ClaudeAgentSDK.create_tool('probe', 'Probe', {}) do |_args|
        captured = Fiber.scheduler
        { content: [{ type: 'text', text: 'ok' }] }
      end
      server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server', tools: [tool])

      Async { server.call_tool('probe', {}) }.wait

      expect(captured).to be_nil
    end
  end

  describe 'Hook callback' do
    it 'is invoked without a Fiber scheduler' do
      captured = :unset
      hook_fn = lambda do |_input, _tool_use_id, _context|
        captured = Fiber.scheduler
        {}
      end
      hooks = { 'PreToolUse' => [{ matcher: 'Bash', hooks: [hook_fn] }] }
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, write: nil, connect: nil, close: nil)

      query = ClaudeAgentSDK::Query.new(
        transport: transport,
        is_streaming_mode: true,
        hooks: hooks
      )
      # Register the callback by initializing once (registers id -> callback).
      allow(query).to receive(:send_control_request).and_return({})
      query.initialize_protocol

      callback_id = query.instance_variable_get(:@hook_callbacks).keys.first
      request_data = {
        callback_id: callback_id,
        input: { hook_event_name: 'PreToolUse' },
        tool_use_id: 'toolu_1'
      }

      Async { query.send(:handle_hook_callback, request_data) }.wait

      expect(captured).to be_nil
    end
  end
end
