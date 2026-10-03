# frozen_string_literal: true

require 'spec_helper'
require 'async'

# ClaudeAgentSDK.notify_observers contains what an observer (or the
# callback_wrapper around it) raises, so observers can never break a session.
# It must contain exactly that and nothing else: the calling fiber WAITS for
# the observer's thread hop, and an exception raised into a waiting fiber is
# not the observer's. A caller's deadline (`task.with_timeout`,
# `Timeout.timeout`) arrives precisely that way.
RSpec.describe ClaudeAgentSDK, '.notify_observers' do
  # Queue-backed stand-in for the CLI: answers the handshake, answers every
  # prompt with one assistant message and its result, and ends its stdout
  # when stdin is closed.
  let(:transport_class) do
    Class.new do
      attr_reader :frames_handled

      def initialize
        @stdout = Thread::Queue.new
        @frames_handled = 0
      end

      def connect; end

      def ready?
        true
      end

      def end_input
        @stdout << :eof
      end

      def close
        @stdout << :eof
      end

      def write(line)
        frame = JSON.parse(line, symbolize_names: true)
        if frame[:type] == 'control_request' && frame.dig(:request, :subtype) == 'initialize'
          @stdout << { type: 'control_response',
                       response: { subtype: 'success', request_id: frame[:request_id],
                                   response: { commands: [], agents: [], output_style: 'default', models: [],
                                               pid: 4242, session_state: 'idle', capabilities: [] },
                                   pending_permission_requests: [], pending_user_dialog_requests: [] } }
        elsif frame[:type] == 'user'
          @stdout << { type: 'assistant', parent_tool_use_id: nil, session_id: 'c0ffee00-0000-4000-8000-000000000002',
                       message: { id: 'msg_01', type: 'message', role: 'assistant',
                                  model: 'claude-haiku-4-5-20251001', content: [{ type: 'text', text: 'Four.' }],
                                  stop_reason: 'end_turn', usage: { input_tokens: 10, output_tokens: 3 } } }
          @stdout << { type: 'result', subtype: 'success', is_error: false, duration_ms: 1500,
                       duration_api_ms: 1000, num_turns: 1, result: 'Four.', stop_reason: 'end_turn',
                       session_id: 'c0ffee00-0000-4000-8000-000000000002', total_cost_usd: 0.001234,
                       usage: { input_tokens: 10, output_tokens: 3 }, terminal_reason: 'completed' }
        end
      end

      def read_messages
        while (frame = @stdout.pop) != :eof
          yield frame
          @frames_handled += 1 # the read loop is done with this frame
        end
      end
    end
  end

  let(:transport) { transport_class.new }

  # Client builds its transport itself: hand it the one the example holds.
  def class_returning(instance)
    Class.new { define_singleton_method(:new) { |*_args, **_kwargs| instance } }
  end

  def observer_with(**handlers)
    Class.new do
      include ClaudeAgentSDK::Observer

      handlers.each { |name, body| define_method(name, &body) }
    end.new
  end

  describe "a caller's deadline while an observer is running" do
    it 'is raised to the caller, and the turn does not carry on' do
      release = Thread::Queue.new
      slow_observer = observer_with(on_message: ->(_message) { release.pop }) # runs until the example lets it go
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [slow_observer])
      events = Thread::Queue.new

      Async do |root|
        client = ClaudeAgentSDK::Client.new(options: options, transport_class: class_returning(transport))
        client.connect
        client.query('What is 2 + 2?')
        # The whole turn is queued before the deadline starts (handshake
        # response, assistant, result), so the receive below reaches the
        # observer's hop without suspending: the deadline cannot expire
        # anywhere but there, however slow the machine is.
        root.with_timeout(10) { root.yield until transport.frames_handled == 3 }

        receiver = root.async do |task|
          task.with_timeout(0.01) do
            client.receive_response { |message| events << [:block_called, message.class] }
          end
          events << [:receive_returned]
        rescue Async::TimeoutError
          events << [:deadline_raised]
        end

        expect(events.pop).to eq([:deadline_raised])
        receiver.wait
        expect(events).to be_empty # the message block was never called
      ensure
        release.close # the observer's pop returns, its thread ends
        client&.disconnect
      end.wait
    end
  end

  describe 'what an observer or its wrapper raises' do
    let(:message) { ClaudeAgentSDK::MessageParser.parse(sample_assistant_message) }

    def notify(observers, scheduling:, wrapper: nil)
      Async do
        described_class.notify_observers(observers, :on_message, message, scheduling: scheduling, wrapper: wrapper)
      end.wait
    end

    %i[thread inline].each do |scheduling|
      context "with callback_scheduling: :#{scheduling}" do
        it 'is contained for a StandardError and for a ScriptError, and later observers still run' do
          notified = []
          observers = [
            observer_with(on_message: ->(_message) { raise 'observer crashed' }),
            observer_with(on_message: ->(_message) { raise NotImplementedError, 'observer stub' }),
            observer_with(on_message: ->(received) { notified << received })
          ]

          expect { notify(observers, scheduling: scheduling) }.not_to raise_error
          expect(notified).to eq([message])
        end

        it 'is contained when the callback_wrapper itself fails, and later observers still run' do
          notified = []
          calls = 0
          failing_once = lambda do |invocation|
            calls += 1
            raise 'wrapper failed' if calls == 1

            invocation.call
          end
          observers = Array.new(2) { observer_with(on_message: ->(received) { notified << received }) }

          expect { notify(observers, scheduling: scheduling, wrapper: failing_once) }.not_to raise_error
          expect(notified).to eq([message]) # the first observer's wrapper failed, the second ran
        end
      end
    end

    it 'still delivers every message when the wrapper fails around an observer during query()' do
      calls = 0
      # query() wraps, in order: on_user_prompt, on_message (assistant), the
      # block, on_message (result), the block, on_close. The second call is
      # the observer's on_message for the first message.
      fails_around_on_message = lambda do |invocation|
        calls += 1
        raise 'wrapper failed around the observer' if calls == 2

        invocation.call
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer_with],
                                                       callback_wrapper: fails_around_on_message)
      seen = []

      described_class.query(prompt: 'What is 2 + 2?', options: options, transport: transport) do |received|
        seen << received.class
      end

      expect(seen).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(calls).to eq(6)
    end
  end
end
