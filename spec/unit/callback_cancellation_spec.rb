# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::CancellationSignal do
  it 'distinguishes timeout from cancellation and wakes all early and late waiters' do
    signal = described_class.new
    expect(signal.wait(timeout: 0.001)).to be false
    expect(signal.cancelled?).to be false
    entered = Thread::Queue.new
    workers = Array.new(2) do
      Thread.new do
        entered << true
        signal.wait(timeout: 2)
      end
    end
    2.times { entered.pop }
    2.times { signal.cancel }
    expect(workers.map(&:value)).to eq([true, true])
    expect(signal.wait(timeout: 0)).to be true
  ensure
    signal&.cancel
    workers&.each(&:join)
  end

  it 'waits on an Async fiber without blocking the reactor' do
    signal = described_class.new
    Async do |task|
      waiter = task.async { signal.wait }
      signal.cancel
      expect(waiter.wait).to be true
    end.wait
  end
end

RSpec.shared_examples 'callback cancellation through the control protocol' do
  def callback_request(id)
    request = if callback_kind == :permission
                { subtype: 'can_use_tool', tool_name: 'Bash', input: { command: 'pwd' },
                  tool_use_id: "tool-#{id}", agent_id: "agent-#{id}" }
              else
                { subtype: 'hook_callback', callback_id: 'hook_0', tool_use_id: "tool-#{id}",
                  input: { hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'pwd' } } }
              end
    { type: 'control_request', request_id: id, request: request }
  end

  def successful_result
    callback_kind == :permission ? ClaudeAgentSDK::PermissionResultAllow.new : { suppress_output: true }
  end

  def callback_query(transport, callback, mode: :thread)
    ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                              can_use_tool: callback, callback_scheduling: mode).tap do |query|
      query.instance_variable_set(:@hook_callbacks, { 'hook_0' => callback }) if callback_kind == :hook
    end
  end

  def routed_transport(messages, writes)
    mock_transport.tap do |transport|
      allow(transport).to receive(:write) { |line| writes << JSON.parse(line, symbolize_names: true) }
      allow(transport).to receive(:read_messages) do |&block|
        while (message = messages.pop)
          raise IOError, 'transport lost' if message == :crash

          block.call(message)
        end
      end
    end
  end

  %i[thread inline].each do |mode|
    it "cancels only the matching #{mode} callback and never sends a late success" do
      messages = Thread::Queue.new
      writes = Thread::Queue.new
      entered = Thread::Queue.new
      finished = Thread::Queue.new
      release = Thread::Queue.new
      callback = lambda do |_tool, _input, context|
        entered << context
        if context.request_id == 'a'
          context.signal.wait
        else
          release.pop
        end
        successful_result
      ensure
        finished << context
      end
      query = callback_query(routed_transport(messages, writes), callback, mode: mode)

      Async do |task|
        task.with_timeout(5) do
          query.start
          messages << callback_request('a') << callback_request('b')
          contexts = Array.new(2) { entered.pop }.to_h { |context| [context.request_id, context] }
          if callback_kind == :permission
            expect(contexts['a'].agent_id).to eq('agent-a')
            expect(contexts['a'].tool_use_id).to eq('tool-a')
          end
          messages << { type: 'control_cancel_request', requestId: 'a' }
          response = writes.pop.fetch(:response)
          expect(response).to include(request_id: 'a', subtype: 'error', error: 'Cancelled')
          expect(finished.pop.signal.cancelled?).to be true
          expect(contexts['b'].signal.cancelled?).to be false

          # Unknown/duplicate cancellations must not cancel the other request.
          messages << { type: 'control_cancel_request', request_id: 'missing' }
          messages << { type: 'control_cancel_request', request_id: 'a' }
          release << true
          expected = callback_kind == :permission ? { behavior: 'allow', updatedInput: { command: 'pwd' } } : { suppressOutput: true }
          expect(writes.pop.fetch(:response)).to include(request_id: 'b', subtype: 'success',
                                                         response: expected)
          finished.pop
          query.close
          expect(contexts['b'].signal.cancelled?).to be false
          expect(writes).to be_empty
          expect(query.instance_variable_get(:@callback_request_signals)).to be_empty
        end
      ensure
        query.close
        release.close
      end.wait
    end

    %i[eof crash close].each do |ending|
      it "invalidates a pending #{mode} callback on #{ending}" do
        messages = Thread::Queue.new
        writes = Thread::Queue.new
        entered = Thread::Queue.new
        finished = Thread::Queue.new
        callback = lambda do |_tool, _input, context|
          entered << context
          context.signal.wait
          successful_result
        ensure
          finished << true
        end
        query = callback_query(routed_transport(messages, writes), callback, mode: mode)

        Async do |task|
          task.with_timeout(5) do
            query.start
            messages << callback_request('a')
            context = entered.pop
            case ending
            when :close then query.close
            when :eof then messages << nil
            when :crash then messages << :crash
            end
            finished.pop
            expect(context.signal.cancelled?).to be true
            expect(writes.pop.dig(:response, :error)).to eq('Cancelled')
            expect(query.instance_variable_get(:@callback_request_signals)).to be_empty
          end
        ensure
          query.close
        end.wait
      end
    end
  end

  %i[eof crash].each do |ending|
    it "does not leak a failed cancellation reply after #{ending}, preserving the original read error" do
      messages = Thread::Queue.new
      entered = Thread::Queue.new
      transport = routed_transport(messages, Thread::Queue.new)
      callback = lambda do |_tool, _input, context|
        entered << context
        context.signal.wait
        successful_result
      end
      query = callback_query(transport, callback)

      Async do |task|
        task.with_timeout(5) do
          query.start
          messages << callback_request('a')
          context = entered.pop
          handler = query.instance_variable_get(:@inflight_control_request_tasks).fetch('a')
          allow(transport).to receive(:write).and_raise(ClaudeAgentSDK::CLIConnectionError, 'process exited')
          messages << (ending == :eof ? nil : :crash)
          expect { handler.wait }.not_to raise_error
          expect(context.signal.cancelled?).to be true
          if ending == :crash
            expect { query.receive_messages { |_| nil } }.to raise_error(IOError, 'transport lost')
          else
            expect { query.receive_messages { |_| nil } }.not_to raise_error
          end
        end
      ensure
        query.close
      end.wait
    end
  end

  it 'ignores connection errors only when sending a best-effort error reply' do
    transport = mock_transport
    callback = ->(*) { raise 'decision failed' }
    query = callback_query(transport, callback)
    Async do
      allow(transport).to receive(:write).and_raise(ClaudeAgentSDK::CLIConnectionError, 'process exited')
      expect { query.send(:handle_control_request, callback_request('a')) }.not_to raise_error
      allow(transport).to receive(:write).and_raise(ArgumentError, 'broken writer')
      expect { query.send(:handle_control_request, callback_request('b')) }.to raise_error(ArgumentError, 'broken writer')
    end.wait
  end

  it 'invalidates the signal and clears tracking if a callback raises' do
    context = nil
    callback = lambda do |_tool, _input, ctx|
      context = ctx
      raise 'decision service unavailable'
    end
    writes = Thread::Queue.new
    query = callback_query(routed_transport(Thread::Queue.new, writes), callback)
    Async { query.send(:handle_control_request, callback_request('a')) }.wait
    expect(context.signal.cancelled?).to be true
    expect(writes.pop.dig(:response, :error)).to eq('decision service unavailable')
    expect(query.instance_variable_get(:@callback_request_signals)).to be_empty
  end
end

RSpec.describe 'Callback cancellation' do
  context 'permissions' do
    let(:callback_kind) { :permission }

    include_examples 'callback cancellation through the control protocol'
  end

  context 'hooks' do
    let(:callback_kind) { :hook }

    include_examples 'callback cancellation through the control protocol'

    %i[thread inline].each do |mode|
      it "invalidates a timed-out #{mode} hook and never publishes its late output" do
        entered = Thread::Queue.new
        finished = Thread::Queue.new
        writes = Thread::Queue.new
        callback = lambda do |_input, _tool_id, context|
          entered << context
          context.signal.wait
          { suppress_output: true }
        ensure
          finished << true
        end
        query = callback_query(routed_transport(Thread::Queue.new, writes), callback, mode: mode)
        query.instance_variable_set(:@hook_callback_timeouts, { 'hook_0' => 0.05 })

        Async do |task|
          task.with_timeout(5) do
            handler = task.async { query.send(:handle_control_request, callback_request('timeout')) }
            context = entered.pop
            handler.wait
            finished.pop
            expect(context.signal.cancelled?).to be true
            expect(writes.pop.fetch(:response)).to include(request_id: 'timeout', subtype: 'error',
                                                           error: 'execution expired')
            expect(writes).to be_empty
            expect(query.instance_variable_get(:@callback_request_signals)).to be_empty
          end
        end.wait
      end
    end
  end
end
