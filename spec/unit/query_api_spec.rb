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

  it 'rejects string prompts when can_use_tool is configured' do
    callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)

    expect do
      described_class.query(prompt: 'hello', options: options) { |_message| nil }
    end.to raise_error(ArgumentError, /can_use_tool callback requires streaming mode/)
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
end
