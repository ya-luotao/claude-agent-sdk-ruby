# frozen_string_literal: true

require 'spec_helper'
require 'async'

RSpec.describe ClaudeAgentSDK::Query do
  describe '#spawn_task' do
    it 'stops spawned child tasks on close so a blocked input stream cannot hang the reactor' do
      transport = mock_transport
      query = described_class.new(transport: transport, is_streaming_mode: true)

      started = false
      spawned = nil
      Async do
        blocked = Enumerator.new do |y|
          y << { type: 'user', message: { role: 'user', content: 'hi' }, session_id: '' }
          started = true
          sleep # parked forever, like a Queue#pop awaiting more input
        end
        spawned = query.spawn_task { query.stream_input(blocked) }
        sleep 0.01 # let stream_input run up to the park point
        query.close

        expect(started).to be true
        expect(spawned).to be_stopped
      ensure
        spawned&.stop # guard: never hang the suite if close regresses
      end.wait
    end

    it 'raises CLIConnectionError when called outside an Async reactor' do
      query = described_class.new(transport: mock_transport, is_streaming_mode: true)

      expect { query.spawn_task { nil } }.to raise_error(ClaudeAgentSDK::CLIConnectionError, /Async/)
    end
  end

  describe '#wait_for_result_and_end_input' do
    # The control protocol writes hook/permission/SDK-MCP replies to stdin,
    # so stdin must stay open for the whole first turn — no timeout (mirrors
    # Python SDK commit c3d96cb; turns longer than the old 60s bound silently
    # broke hooks and in-process MCP tools).
    def queue_fed_transport(queue)
      ended = []
      transport = mock_transport
      allow(transport).to receive(:end_input) { ended << true }
      allow(transport).to receive(:read_messages) do |&blk|
        loop do
          msg = queue.dequeue
          raise ClaudeAgentSDK::ProcessError.new('died', exit_code: 1, stderr: '') if msg == :crash

          blk.call(msg)
        end
      end
      [transport, ended]
    end

    def hooks_config
      { 'PreToolUse' => [{ matcher: 'Bash', hooks: [proc {}] }] }
    end

    it 'keeps stdin open past any timeout while hooks are configured' do
      # The old implementation read CLAUDE_CODE_STREAM_CLOSE_TIMEOUT and
      # force-closed stdin when it fired; 50ms makes that regression trip
      # quickly. The variable is dead after the fix.
      previous = ENV.fetch('CLAUDE_CODE_STREAM_CLOSE_TIMEOUT', nil)
      ENV['CLAUDE_CODE_STREAM_CLOSE_TIMEOUT'] = '50'
      queue = Async::Queue.new
      transport, ended = queue_fed_transport(queue)
      query = described_class.new(transport: transport, is_streaming_mode: true, hooks: hooks_config)

      Async do |task|
        query.start
        waiter = task.async { query.wait_for_result_and_end_input }
        task.sleep 0.2
        expect(ended).to be_empty

        queue.enqueue(sample_result_message)
        waiter.wait
        expect(ended).not_to be_empty
      ensure
        query.close
      end.wait
    ensure
      if previous
        ENV['CLAUDE_CODE_STREAM_CLOSE_TIMEOUT'] = previous
      else
        ENV.delete('CLAUDE_CODE_STREAM_CLOSE_TIMEOUT')
      end
    end

    it 'ends input only after the first result when SDK MCP servers are configured' do
      queue = Async::Queue.new
      transport, ended = queue_fed_transport(queue)
      query = described_class.new(
        transport: transport, is_streaming_mode: true, sdk_mcp_servers: { calc: double('sdk server') }
      )

      Async do |task|
        query.start
        waiter = task.async { query.wait_for_result_and_end_input }
        task.sleep 0.05
        expect(ended).to be_empty

        queue.enqueue(sample_result_message)
        waiter.wait
        expect(ended).not_to be_empty
      ensure
        query.close
      end.wait
    end

    it 'ends input immediately when no hooks or SDK MCP servers are configured' do
      transport = mock_transport
      ended = []
      allow(transport).to receive(:end_input) { ended << true }
      query = described_class.new(transport: transport, is_streaming_mode: true)

      Async { query.wait_for_result_and_end_input }.wait

      expect(ended).not_to be_empty
    end

    it 'unblocks a parked waiter when the read loop dies without a result' do
      queue = Async::Queue.new
      transport, ended = queue_fed_transport(queue)
      query = described_class.new(transport: transport, is_streaming_mode: true, hooks: hooks_config)

      Async do |task|
        query.start
        waiter = task.async { query.wait_for_result_and_end_input }
        task.sleep 0.05
        expect(ended).to be_empty

        queue.enqueue(:crash)
        waiter.wait
        expect(ended).not_to be_empty
      ensure
        query.close
      end.wait
    end

    # stream_input teardown: when no complete message ever reached the CLI,
    # no result can ever arrive — waiting on the first-result condition would
    # park query() forever beside an idle CLI (the pre-0.18 60s timeout used
    # to self-heal this). stdin must be closed directly instead.
    it 'closes stdin without waiting when the input stream raises before any message is written' do
      queue = Async::Queue.new
      transport, ended = queue_fed_transport(queue)
      query = described_class.new(transport: transport, is_streaming_mode: true, hooks: hooks_config)

      allow(query).to receive(:warn) # swallow-and-warn contract; keep CI stderr clean
      Async do |task|
        query.start
        task.with_timeout(2.0) do
          query.stream_input(Enumerator.new { |_y| raise 'enumerator bug' })
        end
        expect(ended).not_to be_empty
      ensure
        query.close
      end.wait
    end

    it 'closes stdin without waiting when the input stream is empty' do
      queue = Async::Queue.new
      transport, ended = queue_fed_transport(queue)
      query = described_class.new(transport: transport, is_streaming_mode: true, hooks: hooks_config)

      Async do |task|
        query.start
        task.with_timeout(2.0) { query.stream_input([]) }
        expect(ended).not_to be_empty
      ensure
        query.close
      end.wait
    end

    it 'still waits for the first result when the stream raised after a message was written' do
      queue = Async::Queue.new
      transport, ended = queue_fed_transport(queue)
      query = described_class.new(transport: transport, is_streaming_mode: true, hooks: hooks_config)

      half_stream = Enumerator.new do |y|
        y << { type: 'user', message: { role: 'user', content: 'hi' }, session_id: '' }
        raise 'enumerator bug after first message'
      end

      allow(query).to receive(:warn) # swallow-and-warn contract; keep CI stderr clean
      Async do |task|
        query.start
        streamer = task.async { query.stream_input(half_stream) }
        task.sleep 0.05
        # A turn is in flight, so stdin must stay open for control replies.
        expect(ended).to be_empty

        queue.enqueue(sample_result_message)
        task.with_timeout(2.0) { streamer.wait }
        expect(ended).not_to be_empty
      ensure
        query.close
      end.wait
    end
  end

  describe '#reconnect_mcp_server' do
    it 'sends mcp_reconnect control request with camelCase serverName' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      expect(query).to receive(:send_control_request).with({
                                                             subtype: 'mcp_reconnect',
                                                             serverName: 'my-server'
                                                           })
      query.reconnect_mcp_server('my-server')
    end
  end

  describe '#toggle_mcp_server' do
    it 'sends mcp_toggle control request with serverName and enabled' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      expect(query).to receive(:send_control_request).with({
                                                             subtype: 'mcp_toggle',
                                                             serverName: 'my-server',
                                                             enabled: false
                                                           })
      query.toggle_mcp_server('my-server', false)
    end
  end

  describe '#stop_task' do
    it 'sends stop_task control request with task_id' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      expect(query).to receive(:send_control_request).with({
                                                             subtype: 'stop_task',
                                                             task_id: 'task_abc123'
                                                           })
      query.stop_task('task_abc123')
    end
  end

  describe '#rewind_files' do
    it 'sends rewind_files control request with user_message_id' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      expect(query).to receive(:send_control_request).with({
                                                             subtype: 'rewind_files',
                                                             user_message_id: 'msg_123'
                                                           })
      query.rewind_files('msg_123')
    end
  end

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
        sleep(0.05)
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

  describe 'agents via initialize' do
    it 'includes agents dict in initialize request' do
      writes = []
      transport = instance_double(ClaudeAgentSDK::Transport)
      allow(transport).to receive(:write) { |data| writes << data }

      agents = {
        coder: ClaudeAgentSDK::AgentDefinition.new(
          description: 'A coding agent',
          prompt: 'You write code',
          tools: %w[Read Write],
          model: 'claude-sonnet-4'
        )
      }

      query = described_class.new(
        transport: transport,
        is_streaming_mode: true,
        agents: agents
      )
      allow(query).to receive(:send_control_request) do |request|
        expect(request[:subtype]).to eq('initialize')
        expect(request[:agents]).to be_a(Hash)
        expect(request[:agents][:coder][:description]).to eq('A coding agent')
        expect(request[:agents][:coder][:prompt]).to eq('You write code')
        expect(request[:agents][:coder][:tools]).to eq(%w[Read Write])
        expect(request[:agents][:coder][:model]).to eq('claude-sonnet-4')
        {}
      end

      query.initialize_protocol
    end

    it 'omits agents from initialize when nil' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)
      allow(query).to receive(:send_control_request) do |request|
        expect(request[:agents]).to be_nil
        {}
      end

      query.initialize_protocol
    end

    it 'sends top-level skills in initialize only for explicit lists' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)

      # Array (including []) is sent; 'all' and nil are wire-equivalent to
      # "no filter" and omitted (mirrors Python).
      { %w[pdf docx] => %w[pdf docx], [] => [] }.each do |skills, expected|
        query = described_class.new(transport: transport, is_streaming_mode: true, skills: skills)
        allow(query).to receive(:send_control_request) do |request|
          expect(request[:skills]).to eq(expected)
          {}
        end
        query.initialize_protocol
      end

      ['all', nil].each do |skills|
        query = described_class.new(transport: transport, is_streaming_mode: true, skills: skills)
        allow(query).to receive(:send_control_request) do |request|
          expect(request).not_to have_key(:skills)
          {}
        end
        query.initialize_protocol
      end
    end

    it 'includes skills, memory, mcpServers in agents dict' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)

      agents = {
        researcher: ClaudeAgentSDK::AgentDefinition.new(
          description: 'A research agent',
          prompt: 'Research things',
          skills: %w[search summarize],
          memory: 'project',
          mcp_servers: ['external-api']
        )
      }

      query = described_class.new(
        transport: transport,
        is_streaming_mode: true,
        agents: agents
      )
      allow(query).to receive(:send_control_request) do |request|
        agent_dict = request[:agents][:researcher]
        expect(agent_dict[:skills]).to eq(%w[search summarize])
        expect(agent_dict[:memory]).to eq('project')
        expect(agent_dict[:mcpServers]).to eq(['external-api'])
        {}
      end

      query.initialize_protocol
    end

    it 'compacts nil fields from agents dict' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)

      agents = {
        basic: ClaudeAgentSDK::AgentDefinition.new(
          description: 'Basic agent',
          prompt: 'Do stuff'
        )
      }

      query = described_class.new(
        transport: transport,
        is_streaming_mode: true,
        agents: agents
      )
      allow(query).to receive(:send_control_request) do |request|
        agent_dict = request[:agents][:basic]
        expect(agent_dict.key?(:skills)).to eq(false)
        expect(agent_dict.key?(:memory)).to eq(false)
        expect(agent_dict.key?(:mcpServers)).to eq(false)
        expect(agent_dict.key?(:tools)).to eq(false)
        expect(agent_dict.key?(:model)).to eq(false)
        {}
      end

      query.initialize_protocol
    end
  end

  describe '#parse_hook_input' do
    it 'populates tool_use_id for PreToolUse events' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      input_data = {
        hook_event_name: 'PreToolUse',
        tool_name: 'Bash',
        tool_input: { command: 'ls' },
        tool_use_id: 'toolu_abc123',
        session_id: 'sess_1'
      }

      result = query.send(:parse_hook_input, input_data)
      expect(result).to be_a(ClaudeAgentSDK::PreToolUseHookInput)
      expect(result.tool_use_id).to eq('toolu_abc123')
      expect(result.tool_name).to eq('Bash')
    end

    it 'populates agent_id and agent_type for PreToolUse events' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      input_data = {
        hook_event_name: 'PreToolUse',
        tool_name: 'Bash',
        tool_input: {},
        agent_id: 'agent_abc',
        agent_type: 'coder'
      }

      result = query.send(:parse_hook_input, input_data)
      expect(result.agent_id).to eq('agent_abc')
      expect(result.agent_type).to eq('coder')
    end

    it 'populates agent_id and agent_type for PostToolUseFailure events' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      input_data = {
        hook_event_name: 'PostToolUseFailure',
        tool_name: 'Bash',
        tool_input: {},
        agent_id: 'agent_xyz',
        agent_type: 'tester'
      }

      result = query.send(:parse_hook_input, input_data)
      expect(result).to be_a(ClaudeAgentSDK::PostToolUseFailureHookInput)
      expect(result.agent_id).to eq('agent_xyz')
      expect(result.agent_type).to eq('tester')
    end

    it 'populates agent_id and agent_type for PermissionRequest events' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      input_data = {
        hook_event_name: 'PermissionRequest',
        tool_name: 'Write',
        tool_input: {},
        agent_id: 'agent_perm',
        agent_type: 'planner'
      }

      result = query.send(:parse_hook_input, input_data)
      expect(result).to be_a(ClaudeAgentSDK::PermissionRequestHookInput)
      expect(result.agent_id).to eq('agent_perm')
      expect(result.agent_type).to eq('planner')
    end

    it 'populates tool_use_id for PostToolUse events' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      input_data = {
        hook_event_name: 'PostToolUse',
        tool_name: 'Bash',
        tool_input: { command: 'ls' },
        tool_response: 'file.txt',
        tool_use_id: 'toolu_def456'
      }

      result = query.send(:parse_hook_input, input_data)
      expect(result).to be_a(ClaudeAgentSDK::PostToolUseHookInput)
      expect(result.tool_use_id).to eq('toolu_def456')
      expect(result.tool_response).to eq('file.txt')
    end

    it 'preserves false values in hook input payloads' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)

      result = query.send(:parse_hook_input, {
                            hook_event_name: 'Stop',
                            stop_hook_active: false
                          })

      expect(result).to be_a(ClaudeAgentSDK::StopHookInput)
      expect(result.stop_hook_active).to eq(false)
    end
  end

  describe 'can_use_tool permission requests' do
    def handle_permission_request(callback, request)
      writes = []
      transport = instance_double(ClaudeAgentSDK::Transport)
      allow(transport).to receive(:write) { |data| writes << data }
      query = described_class.new(transport: transport, is_streaming_mode: true, can_use_tool: callback)

      query.send(:handle_control_request, { request_id: 'req_1', request: request })
      JSON.parse(writes.last, symbolize_names: true)
    end

    it 'forwards display fields and blocked_path/decision_reason to ToolPermissionContext' do
      received = nil
      callback = lambda do |_tool_name, _input, context|
        received = context
        ClaudeAgentSDK::PermissionResultAllow.new
      end

      handle_permission_request(callback, {
                                  subtype: 'can_use_tool',
                                  tool_name: 'Bash',
                                  input: { command: 'rm -rf /tmp/x' },
                                  permission_suggestions: [],
                                  tool_use_id: 'toolu_01DEF456',
                                  blocked_path: '/tmp/x',
                                  decision_reason: 'PreToolUse hook flagged this as destructive',
                                  title: 'Claude wants to run a Bash command',
                                  display_name: 'Bash',
                                  description: 'rm -rf /tmp/x'
                                })

      expect(received.tool_use_id).to eq('toolu_01DEF456')
      expect(received.blocked_path).to eq('/tmp/x')
      expect(received.decision_reason).to eq('PreToolUse hook flagged this as destructive')
      expect(received.title).to eq('Claude wants to run a Bash command')
      expect(received.display_name).to eq('Bash')
      expect(received.description).to eq('rm -rf /tmp/x')
    end

    it 'delivers suggestions as PermissionUpdate objects and round-trips them through updatedPermissions' do
      wire_suggestion = {
        type: 'addRules',
        destination: 'localSettings',
        behavior: 'allow',
        rules: [{ toolName: 'Bash', ruleContent: 'git status' }]
      }
      seen = []
      callback = lambda do |_tool_name, _input, context|
        seen.concat(context.suggestions)
        ClaudeAgentSDK::PermissionResultAllow.new(
          updated_permissions: context.suggestions.select { |s| s.destination == 'localSettings' }
        )
      end

      response = handle_permission_request(callback, {
                                             subtype: 'can_use_tool',
                                             tool_name: 'Bash',
                                             input: { command: 'git status' },
                                             permission_suggestions: [wire_suggestion],
                                             tool_use_id: 'toolu_2'
                                           })

      expect(seen.first).to be_a(ClaudeAgentSDK::PermissionUpdate)
      expect(seen.first.destination).to eq('localSettings')
      expect(seen.first.rules.first).to be_a(ClaudeAgentSDK::PermissionRuleValue)
      expect(seen.first.rules.first.tool_name).to eq('Bash')
      expect(response.dig(:response, :subtype)).to eq('success')
      expect(response.dig(:response, :response, :updatedPermissions)).to eq([wire_suggestion])
    end

    it 'defaults display fields to nil and suggestions to [] when the CLI omits them' do
      received = nil
      callback = lambda do |_tool_name, _input, context|
        received = context
        ClaudeAgentSDK::PermissionResultAllow.new
      end

      response = handle_permission_request(callback, {
                                             subtype: 'can_use_tool',
                                             tool_name: 'Read',
                                             input: {},
                                             tool_use_id: 'toolu_3'
                                           })

      expect(received.suggestions).to eq([])
      expect([received.title, received.display_name, received.description,
              received.blocked_path, received.decision_reason]).to all(be_nil)
      expect(response.dig(:response, :subtype)).to eq('success')
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

  describe '#start outside an Async reactor' do
    # Regression for Codex P1: Async::Task.current raises an opaque
    # "No async task available!" when start is called outside Async{}.
    # The old version of this method appeared to support synchronous callers
    # but the outer Async{} root task it spawned waited for read_messages to
    # finish, which never happens for a live Client — silent hang. The fix
    # raises a clear CLIConnectionError pointing at the supported pattern.
    it 'raises a clear CLIConnectionError when called without a reactor' do
      transport = instance_double(ClaudeAgentSDK::Transport, write: nil)
      query = described_class.new(transport: transport, is_streaming_mode: true)
      expect { query.start }.to raise_error(ClaudeAgentSDK::CLIConnectionError, /Async\{\} block/)
    end
  end

  describe 'transcript mirror wiring' do
    # Minimal transport that replays a fixed list of frames through read_messages.
    def fake_transport(messages)
      Class.new do
        def initialize(messages) = (@messages = messages)
        def read_messages(&block) = @messages.each(&block)
        def write(_str) = nil
        def close = nil
      end.new(messages)
    end

    it 'report_mirror_error enqueues a parseable mirror_error system message' do
      query = described_class.new(transport: instance_double(ClaudeAgentSDK::Transport, write: nil),
                                  is_streaming_mode: true)
      key = { 'project_key' => 'pk', 'session_id' => 'sid' }

      Async do
        query.report_mirror_error(key, 'append failed')
        raw = query.instance_variable_get(:@message_queue).dequeue
        msg = ClaudeAgentSDK::MessageParser.parse(raw)
        expect(msg).to be_a(ClaudeAgentSDK::MirrorErrorMessage)
        expect(msg.error).to eq('append failed')
        expect(msg.key).to eq(key)
        expect(msg.session_id).to eq('sid')
      end
    end

    it 'routes transcript_mirror frames to the batcher (not the message stream) and flushes on result' do
      messages = [
        { type: 'transcript_mirror', filePath: '/p/pk/sid.jsonl', entries: [{ type: 'user' }] },
        { type: 'result', subtype: 'success' }
      ]
      query = described_class.new(transport: fake_transport(messages), is_streaming_mode: true)
      batcher = instance_double(ClaudeAgentSDK::TranscriptMirrorBatcher, enqueue: nil, flush: nil, close: nil)
      query.set_transcript_mirror_batcher(batcher)

      Async { query.send(:read_messages) }

      expect(batcher).to have_received(:enqueue).with('/p/pk/sid.jsonl', [{ type: 'user' }]).once
      expect(batcher).to have_received(:flush).at_least(:once) # on result + in ensure

      # The mirror frame must not surface to consumers; the result must.
      drained = []
      q = query.instance_variable_get(:@message_queue)
      drained << q.dequeue until q.empty?
      types = drained.map { |m| m[:type] }
      expect(types).to include('result')
      expect(types).not_to include('transcript_mirror')
    end
  end
end
