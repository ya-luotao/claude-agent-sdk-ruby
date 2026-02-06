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

    it 'parses additional hook input event types' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      received_inputs = []
      callback = lambda do |input, _tool_use_id, _context|
        received_inputs << input
        {}
      end

      query.instance_variable_set(:@hook_callbacks, { 'hook_0' => callback })

      cases = [
        {
          event_name: 'PostToolUseFailure',
          expected_class: ClaudeAgentSDK::PostToolUseFailureHookInput,
          input: {
            hook_event_name: 'PostToolUseFailure',
            tool_name: 'Bash',
            tool_input: { command: 'ls' },
            tool_use_id: 'toolu_1',
            error: 'boom',
            is_interrupt: true,
            session_id: 'sess_1',
            cwd: '/tmp'
          }
        },
        {
          event_name: 'Notification',
          expected_class: ClaudeAgentSDK::NotificationHookInput,
          input: {
            hook_event_name: 'Notification',
            message: 'hello',
            title: 'hi',
            notification_type: 'info'
          }
        },
        {
          event_name: 'SubagentStart',
          expected_class: ClaudeAgentSDK::SubagentStartHookInput,
          input: {
            hook_event_name: 'SubagentStart',
            agent_id: 'agent_1',
            agent_type: 'coder'
          }
        },
        {
          event_name: 'PermissionRequest',
          expected_class: ClaudeAgentSDK::PermissionRequestHookInput,
          input: {
            hook_event_name: 'PermissionRequest',
            tool_name: 'Bash',
            tool_input: { command: 'ls' },
            permission_suggestions: [{ type: 'setMode', mode: 'default' }]
          }
        },
        {
          event_name: 'SubagentStop',
          expected_class: ClaudeAgentSDK::SubagentStopHookInput,
          input: {
            hook_event_name: 'SubagentStop',
            stop_hook_active: true,
            agent_id: 'agent_1',
            agent_transcript_path: '/tmp/agent.jsonl',
            agent_type: 'coder'
          }
        }
      ]

      cases.each do |case_data|
        query.send(
          :handle_hook_callback,
          {
            callback_id: 'hook_0',
            tool_use_id: 'toolu_123',
            input: case_data[:input]
          }
        )

        parsed = received_inputs.last
        expect(parsed).to be_a(case_data[:expected_class])
      end

      subagent_stop = received_inputs.last
      expect(subagent_stop.agent_id).to eq('agent_1')
      expect(subagent_stop.agent_transcript_path).to eq('/tmp/agent.jsonl')
      expect(subagent_stop.agent_type).to eq('coder')
    end

    it 'accepts string keys in hook input payloads' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      received = {}
      callback = lambda do |input, _tool_use_id, _context|
        received[:input] = input
        {}
      end

      query.instance_variable_set(:@hook_callbacks, { 'hook_0' => callback })

      query.send(
        :handle_hook_callback,
        {
          callback_id: 'hook_0',
          tool_use_id: nil,
          input: {
            'hook_event_name' => 'Notification',
            'message' => 'hello',
            'title' => 'hi',
            'notification_type' => 'info',
            'session_id' => 'sess_1',
            'cwd' => '/tmp'
          }
        }
      )

      expect(received[:input]).to be_a(ClaudeAgentSDK::NotificationHookInput)
      expect(received[:input].message).to eq('hello')
      expect(received[:input].session_id).to eq('sess_1')
      expect(received[:input].cwd).to eq('/tmp')
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

  describe 'SDK MCP tool responses' do
    it 'preserves non-text content and maps is_error to isError' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      tool_result = {
        content: [
          { type: 'text', text: 'ok' },
          { type: 'image', data: 'abc123', mimeType: 'image/png' }
        ],
        is_error: true
      }
      server = instance_double('SdkMcpServer')
      allow(server).to receive(:call_tool).with('mixed_content', {}).and_return(tool_result)

      response = query.send(
        :handle_mcp_tools_call,
        server,
        { id: 1 },
        { name: 'mixed_content', arguments: {} }
      )

      expect(response.dig(:result, :content)).to eq(tool_result[:content])
      expect(response.dig(:result, :isError)).to eq(true)
    end

    it 'accepts camelCase keys from server results' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      server = instance_double('SdkMcpServer')
      allow(server).to receive(:call_tool).with('tool', {}).and_return(
        {
          'content' => [{ 'type' => 'text', 'text' => 'done' }],
          'isError' => false,
          'structuredContent' => { 'status' => 'ok' }
        }
      )

      response = query.send(
        :handle_mcp_tools_call,
        server,
        { id: 2 },
        { name: 'tool', arguments: {} }
      )

      expect(response.dig(:result, :content)).to eq([{ 'type' => 'text', 'text' => 'done' }])
      expect(response.dig(:result, :isError)).to eq(false)
      expect(response.dig(:result, :structuredContent)).to eq({ 'status' => 'ok' })
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
