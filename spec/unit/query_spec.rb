# frozen_string_literal: true

require 'spec_helper'
require 'async'

RSpec.describe ClaudeAgentSDK::Query do
  describe 'hook callbacks' do
    it 'passes typed hook input objects to callbacks' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      received = {}
      callback = lambda do |input, tool_use_id, context|
        received[:input] = input
        received[:tool_use_id] = tool_use_id
        received[:context] = context
        {}
      end

      query.instance_variable_set(:@hook_callbacks, { 'hook_0' => callback })

      request_data = {
        callback_id: 'hook_0',
        tool_use_id: 'toolu_123',
        input: {
          hook_event_name: 'PreToolUse',
          tool_name: 'Bash',
          tool_input: { command: 'ls' },
          session_id: 'sess_123',
          cwd: '/tmp'
        }
      }

      query.send(:handle_hook_callback, request_data)

      expect(received[:input]).to be_a(ClaudeAgentSDK::PreToolUseHookInput)
      expect(received[:input].tool_name).to eq('Bash')
      expect(received[:input].tool_input).to eq({ command: 'ls' })
      expect(received[:tool_use_id]).to eq('toolu_123')
      expect(received[:context]).to be_a(ClaudeAgentSDK::HookContext)
    end

    it 'registers HookMatcher timeouts during initialize' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)

      hook_fn = ->(_input, _tool_use_id, _context) { {} }
      hooks = {
        'PreToolUse' => [
          {
            matcher: 'Bash',
            hooks: [hook_fn],
            timeout: 5
          }
        ]
      }

      query = described_class.new(transport: transport, is_streaming_mode: true, hooks: hooks)
      allow(query).to receive(:send_control_request).and_return({})

      query.initialize_protocol

      timeouts = query.instance_variable_get(:@hook_callback_timeouts)
      expect(timeouts['hook_0']).to eq(5)
    end

    it 'enforces HookMatcher timeouts' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      callback = lambda do |_input, _tool_use_id, _context|
        Async::Task.current.sleep(0.05)
        {}
      end

      query.instance_variable_set(:@hook_callbacks, { 'hook_0' => callback })
      query.instance_variable_set(:@hook_callback_timeouts, { 'hook_0' => 0.01 })

      request_data = {
        callback_id: 'hook_0',
        tool_use_id: nil,
        input: { hook_event_name: 'PreToolUse' }
      }

      error = nil
      Async do
        begin
          query.send(:handle_hook_callback, request_data)
        rescue StandardError => e
          error = e
        end
      end.wait
      expect(error).to be_a(Async::TimeoutError)
    end
  end

  describe 'control request cancellation' do
    it 'writes a cancelled response when stopped' do
      writes = []
      transport = instance_double(ClaudeAgentSDK::Transport)
      allow(transport).to receive(:write) { |data| writes << data }

      query = described_class.new(transport: transport, is_streaming_mode: true)

      callback = lambda do |_input, _tool_use_id, _context|
        Async::Task.current.sleep(1)
        {}
      end
      query.instance_variable_set(:@hook_callbacks, { 'hook_0' => callback })

      message = {
        request_id: 'req_1',
        request: {
          subtype: 'hook_callback',
          callback_id: 'hook_0',
          tool_use_id: 'toolu_123',
          input: { hook_event_name: 'PreToolUse' }
        }
      }

      Async do |task|
        child = task.async do
          query.send(:handle_control_request, message)
        end

        task.sleep(0)
        child.stop
        child.wait
      end.wait

      expect(writes).not_to be_empty
      payload = JSON.parse(writes.last, symbolize_names: true)
      expect(payload[:type]).to eq('control_response')
      expect(payload.dig(:response, :subtype)).to eq('error')
      expect(payload.dig(:response, :request_id)).to eq('req_1')
      expect(payload.dig(:response, :error)).to eq('Cancelled')
    end
  end
end
