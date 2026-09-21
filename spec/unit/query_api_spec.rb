# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

RSpec.describe ClaudeAgentSDK, '.query' do
  it 'passes entrypoint via transport env without mutating global ENV' do
    original_entrypoint = ENV['CLAUDE_CODE_ENTRYPOINT']
    ENV.delete('CLAUDE_CODE_ENTRYPOINT')

    captured_options = nil
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)
    allow(transport).to receive(:read_messages) # returns nil immediately

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages) # yields nothing
    allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |opts|
      captured_options = opts
      transport
    end
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(env: { 'EXTRA' => '1' })

    # query() calls Async do...end.wait internally; wrap in Async to prevent nested reactor issues.
    begin
      Async do
        described_class.query(prompt: 'hello', options: options) { |_message| nil }
      end.wait
    rescue StandardError
      # Ignore errors from mock transport — we're only testing options configuration
    end

    expect(captured_options).not_to be_nil
    # CLAUDE_CODE_ENTRYPOINT is now set as a default-if-absent by the transport,
    # not by query(). The caller's env should pass through without an override.
    expect(captured_options.env).not_to have_key('CLAUDE_CODE_ENTRYPOINT')
    expect(captured_options.env['EXTRA']).to eq('1')
    expect(options.env['CLAUDE_CODE_ENTRYPOINT']).to be_nil
    expect(ENV['CLAUDE_CODE_ENTRYPOINT']).to be_nil
  ensure
    if original_entrypoint.nil?
      ENV.delete('CLAUDE_CODE_ENTRYPOINT')
    else
      ENV['CLAUDE_CODE_ENTRYPOINT'] = original_entrypoint
    end
  end

  it 'passes hooks into the control protocol for one-shot queries' do
    hook_fn = ->(_input, _tool_use_id, _context) { {} }
    matcher = ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [hook_fn], timeout: 30)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      hooks: { 'PreToolUse' => [matcher] }
    )

    writes = []
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write) { |payload| writes << JSON.parse(payload, symbolize_names: true) }

    captured_query_args = nil
    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)
    allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
      captured_query_args = kwargs
      query_handler
    end

    Async do
      described_class.query(prompt: 'hello', options: options) { |_message| nil }
    end.wait

    expect(captured_query_args[:hooks]).to eq(
      'PreToolUse' => [
        {
          matcher: 'Bash',
          hooks: [hook_fn],
          timeout: 30
        }
      ]
    )
    expect(query_handler).to have_received(:wait_for_result_and_end_input)
    expect(writes.first[:session_id]).to eq('')
  end

  it 'passes nil hooks when all matcher lists are empty' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      hooks: { 'PreToolUse' => [] }
    )

    captured_query_args = nil
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)
    allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
      captured_query_args = kwargs
      query_handler
    end

    Async do
      described_class.query(prompt: 'hello', options: options) { |_message| nil }
    end.wait

    expect(captured_query_args[:hooks]).to be_nil
  end

  it 'configures can_use_tool for streaming one-shot queries' do
    callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)
    prompt = [ClaudeAgentSDK::Streaming.user_message('hello')].to_enum

    captured_options = nil
    captured_query_args = nil

    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      stream_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)
    allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |opts|
      captured_options = opts
      transport
    end
    allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
      captured_query_args = kwargs
      query_handler
    end

    Async do
      described_class.query(prompt: prompt, options: options) { |_message| nil }
    end.wait

    expect(captured_options.permission_prompt_tool_name).to eq('stdio')
    expect(captured_query_args[:can_use_tool]).to eq(callback)
    expect(query_handler).to have_received(:stream_input).with(prompt)
  end

  it 'propagates a read-loop failure instead of hanging when streaming input is still blocked' do
    # Transport that completes the initialize handshake, then crashes the read
    # loop while the user's input enumerator is still parked. Before the fix,
    # the untracked stream_input task kept the root reactor alive forever and
    # query() never returned (the error decayed to an async console warning).
    fake_transport = Class.new do
      def initialize
        @incoming = Async::Queue.new
      end

      def connect; end
      def end_input; end
      def close; end

      def write(data)
        msg = JSON.parse(data, symbolize_names: true)
        return unless msg[:type] == 'control_request' && msg.dig(:request, :subtype) == 'initialize'

        @incoming.enqueue(
          type: 'control_response',
          response: { subtype: 'success', request_id: msg[:request_id], response: {} }
        )
        @incoming.enqueue(:crash)
      end

      def read_messages
        loop do
          msg = @incoming.dequeue
          raise ClaudeAgentSDK::CLIConnectionError, 'CLI crashed mid-stream' if msg == :crash

          yield msg
        end
      end
    end.new
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(fake_transport)

    blocked_prompt = Enumerator.new do |y|
      y << { type: 'user', message: { role: 'user', content: 'hi' }, session_id: '' }
      sleep # blocked indefinitely, like a Queue#pop awaiting more input
    end

    error = nil
    thread = Thread.new do
      described_class.query(prompt: blocked_prompt) { |_message| nil }
    rescue StandardError => e
      error = e
    end

    expect(thread.join(5)).not_to be_nil, 'query() hung: stream_input child task was not stopped on close'
    expect(error).to be_a(ClaudeAgentSDK::CLIConnectionError)
  ensure
    thread&.kill
  end

  it 'delivers messages while the stdin-close wait is still pending for string prompts' do
    # Guards the background spawn of wait_for_result_and_end_input: a
    # synchronous call would defer all message delivery until the first
    # result (unbounded since the 60s timeout was removed).
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)

    order = []
    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: nil, close: nil)
    allow(query_handler).to receive(:wait_for_result_and_end_input) do
      order << :wait_started
      Async::Task.current.sleep(0.05)
      order << :wait_finished
    end
    allow(query_handler).to receive(:spawn_task) { |&blk| Async::Task.current.async { blk.call } }
    allow(query_handler).to receive(:receive_messages) { order << :messages_delivered }
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    described_class.query(prompt: 'hello') { |_message| nil }

    expect(order.index(:messages_delivered)).to be < order.index(:wait_finished),
                                                "messages were deferred until stdin close completed: #{order.inspect}"
  end

  context 'with a custom transport' do
    def fake_streaming_transport(writes)
      Class.new do
        define_method(:initialize) do
          @incoming = Async::Queue.new
          @writes = writes
        end
        def connect; end
        def end_input; end

        def close
          @closed = true
        end

        def closed?
          !!@closed
        end

        def write(data)
          @writes << data
          msg = JSON.parse(data, symbolize_names: true)
          return unless msg[:type] == 'control_request' && msg.dig(:request, :subtype) == 'initialize'

          @incoming.enqueue(
            type: 'control_response',
            response: { subtype: 'success', request_id: msg[:request_id], response: {} }
          )
          @incoming.enqueue(type: 'result', subtype: 'success', is_error: false, duration_ms: 1,
                            duration_api_ms: 1, num_turns: 1, session_id: 's', total_cost_usd: 0)
          @incoming.enqueue(:end)
        end

        def read_messages
          loop do
            msg = @incoming.dequeue
            break if msg == :end

            yield msg
          end
        end
      end.new
    end

    it 'uses the injected transport and never constructs SubprocessCLITransport' do
      writes = []
      fake = fake_streaming_transport(writes)
      expect(ClaudeAgentSDK::SubprocessCLITransport).not_to receive(:new)

      described_class.query(prompt: 'hello', transport: fake) { |_m| nil }

      expect(fake.closed?).to be(true)
      user_frame = writes.map { |w| JSON.parse(w, symbolize_names: true) }.find { |m| m[:type] == 'user' }
      expect(user_frame.dig(:message, :content)).to eq('hello')
    end

    it 'skips resume materialization when a transport is injected' do
      writes = []
      fake = fake_streaming_transport(writes)
      expect(ClaudeAgentSDK::SessionResume).not_to receive(:materialize_resume_session)

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        session_store: ClaudeAgentSDK::InMemorySessionStore.new, resume: SecureRandom.uuid
      )
      described_class.query(prompt: 'hello', options: options, transport: fake) { |_m| nil }
    end

    it 'rejects transports that do not respond to #connect' do
      expect do
        described_class.query(prompt: 'hello', transport: Object.new) { |_m| nil }
      end.to raise_error(ArgumentError, /must respond to #connect/)
    end
  end

  # can_use_tool is served over the control protocol, which needs stdin open
  # for the verdict to reach the CLI. The SDK is always streaming internally
  # (a String prompt is written to stdin as a user message like any other),
  # so a String prompt works too — the old "requires streaming mode" refusal
  # was a needless restriction (Python #1204).
  describe 'can_use_tool' do
    # Enforces the real CLI contract: the permission control_request is only
    # emitted after the user message is written, the assistant/result frames
    # only after the verdict is written back, and any write after end_input
    # raises like a closed pipe would.
    def permission_gated_transport(state)
      Class.new do
        define_method(:initialize) do
          @incoming = Async::Queue.new
          @state = state
        end
        def connect; end

        # Like the real CLI in stream-json mode: stdin EOF ends the process.
        # A regression that closes stdin early therefore fails the example
        # (no permission callback, no messages) instead of hanging.
        def end_input
          @state[:ended] = true
          @incoming.enqueue(:end)
        end

        def close
          @state[:closed] = true
        end

        def write(data)
          raise IOError, 'stdin closed' if @state[:ended]

          @state[:writes] << data
          msg = JSON.parse(data, symbolize_names: true)
          case msg[:type]
          when 'control_request'
            handle_initialize(msg) if msg.dig(:request, :subtype) == 'initialize'
          when 'user'
            request_permission
          when 'control_response'
            finish_turn
          end
        end

        def read_messages
          loop do
            msg = @incoming.dequeue
            break if msg == :end

            yield msg
          end
        end

        private

        def handle_initialize(msg)
          @incoming.enqueue(
            type: 'control_response',
            response: { subtype: 'success', request_id: msg[:request_id], response: {} }
          )
        end

        def request_permission
          @incoming.enqueue(
            type: 'control_request',
            request_id: 'perm_1',
            request: {
              subtype: 'can_use_tool', tool_name: 'Write',
              input: { file_path: '/tmp/x', content: 'hi' }, tool_use_id: 'toolu_1'
            }
          )
        end

        def finish_turn
          @incoming.enqueue(type: 'assistant',
                            message: { role: 'assistant', model: 'claude-sonnet-4',
                                       content: [{ type: 'text', text: 'done' }] })
          @incoming.enqueue(type: 'result', subtype: 'success', is_error: false, duration_ms: 1,
                            duration_api_ms: 1, num_turns: 1, session_id: 's', total_cost_usd: 0)
          @incoming.enqueue(:end)
        end
      end.new
    end

    def run_permission_query(prompt)
      state = { writes: [], ended: false, closed: false, calls: [] }
      callback = lambda do |tool_name, _input, _context|
        state[:calls] << tool_name
        ClaudeAgentSDK::PermissionResultAllow.new
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)

      messages = []
      described_class.query(prompt: prompt, options: options,
                            transport: permission_gated_transport(state)) { |m| messages << m }
      [messages, state]
    end

    def permission_verdicts(state)
      state[:writes].map { |w| JSON.parse(w, symbolize_names: true) }
                    .select { |m| m[:type] == 'control_response' }
    end

    it 'answers the permission request for a String prompt' do
      messages, state = run_permission_query('write it')

      expect(state[:calls]).to eq(['Write'])
      expect(messages.map(&:class)).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(state[:ended]).to be(true)
    end

    it 'answers the permission request for an Enumerator prompt' do
      prompt = Enumerator.new do |y|
        y << { type: 'user', message: { role: 'user', content: 'write it' }, parent_tool_use_id: nil, session_id: '' }
      end
      messages, state = run_permission_query(prompt)

      expect(state[:calls]).to eq(['Write'])
      expect(messages.map(&:class)).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(state[:ended]).to be(true)
    end

    it 'writes an allow verdict back over the control protocol' do
      _messages, state = run_permission_query('write it')

      verdicts = permission_verdicts(state)
      expect(verdicts.length).to eq(1)
      expect(verdicts.first.dig(:response, :subtype)).to eq('success')
      expect(verdicts.first.dig(:response, :response, :behavior)).to eq('allow')
    end

    it 'routes permission prompts over stdio' do
      captured = nil
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |opts|
        captured = opts
        raise ClaudeAgentSDK::CLIConnectionError, 'stop here'
      end
      callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)

      expect { described_class.query(prompt: 'hello', options: options) { |_m| nil } }
        .to raise_error(ClaudeAgentSDK::CLIConnectionError)
      expect(captured.permission_prompt_tool_name).to eq('stdio')
    end

    it 'rejects can_use_tool combined with permission_prompt_tool_name' do
      callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        can_use_tool: callback, permission_prompt_tool_name: 'mcp__auth__prompt'
      )

      expect do
        described_class.query(prompt: 'hello', options: options) { |_message| nil }
      end.to raise_error(ArgumentError, /cannot be used with permission_prompt_tool_name/)
    end
  end

  # Regression (M6): Client#query validated the prompt but query() did not —
  # a bare Hash responds to #each and streamed [key, value].to_s garbage to
  # the CLI; nil/Integer hung forever waiting for stdin.
  describe 'prompt validation' do
    it 'rejects a bare Hash prompt' do
      expect do
        described_class.query(prompt: { type: 'user' }) { |_m| nil }
      end.to raise_error(ArgumentError, /got Hash/)
    end

    it 'rejects prompts that are neither String nor each-able' do
      expect do
        described_class.query(prompt: 42) { |_m| nil }
      end.to raise_error(ArgumentError, /must be a String or respond to #each \(got Integer\)/)
    end

    it 'fails fast at the call site even without a block (before enum_for defers)' do
      expect { described_class.query(prompt: nil) }
        .to raise_error(ArgumentError, /got NilClass/)
    end
  end

  # Regression (M7): query() built its Query handler without the
  # exclude_dynamic_sections kwarg, so excludeDynamicSections never reached
  # the initialize request — Client and Python both send it.
  it 'passes exclude_dynamic_sections from a preset system prompt to the control protocol' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: { type: 'preset', preset: 'claude_code', exclude_dynamic_sections: true }
    )

    captured_query_args = nil
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)
    allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
      captured_query_args = kwargs
      query_handler
    end

    Async do
      described_class.query(prompt: 'hello', options: options) { |_message| nil }
    end.wait

    expect(captured_query_args[:exclude_dynamic_sections]).to be(true)
  end

  # Python #1268: query() hands snapshot to Query only for the preset and
  # custom forms, and a false value survives the trip.
  {
    [{ type: 'custom', prompt: 'Be helpful', snapshot: false }] => false,
    [{ type: 'preset', preset: 'claude_code', snapshot: true }] => true,
    [{ type: 'preset', preset: 'claude_code' }] => nil,
    [{ type: 'file', path: '/p.md', snapshot: false }] => nil,
    ['Be helpful'] => nil
  }.each do |(system_prompt), expected|
    it "passes system_prompt_snapshot #{expected.inspect} for #{system_prompt.inspect} to the control protocol" do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: system_prompt)

      captured_query_args = nil
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
      allow(transport).to receive(:write)

      query_handler = instance_double(
        ClaudeAgentSDK::Query,
        start: true,
        initialize_protocol: nil,
        wait_for_result_and_end_input: nil,
        close: nil
      )
      allow(query_handler).to receive(:receive_messages)
      allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }

      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        captured_query_args = kwargs
        query_handler
      end

      Async do
        described_class.query(prompt: 'hello', options: options) { |_message| nil }
      end.wait

      expect(captured_query_args.fetch(:system_prompt_snapshot)).to be(expected)
    end
  end

  it 'passes forward_subagent_text from the options to the control protocol' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)
    allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)

    [true, false].each do |enabled|
      captured_query_args = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        captured_query_args = kwargs
        query_handler
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(forward_subagent_text: enabled)
      Async do
        described_class.query(prompt: 'hello', options: options) { |_message| nil }
      end.wait

      expect(captured_query_args[:forward_subagent_text]).to be(enabled)
    end
  end

  it 'passes agent_progress_summaries from the options to the control protocol, preserving nil vs false' do
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)
    allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)

    [true, false, nil].each do |value|
      captured_query_args = nil
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        captured_query_args = kwargs
        query_handler
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(agent_progress_summaries: value)
      Async do
        described_class.query(prompt: 'hello', options: options) { |_message| nil }
      end.wait

      expect(captured_query_args).to have_key(:agent_progress_summaries)
      expect(captured_query_args[:agent_progress_summaries]).to be(value)
    end
  end
end
