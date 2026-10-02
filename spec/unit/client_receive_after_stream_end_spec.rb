# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'timeout'

# Once the CLI's stdout has ended — the process exited, cleanly or not — the
# read loop is gone and nothing is ever written to the message queue again.
# The read loop leaves ONE end-of-stream marker behind, so the end has to be
# remembered for every later Client#receive_response / #receive_messages:
# forgotten once the first reader consumed the marker, the next one waits on
# an empty queue that has no producer, for as long as the process lives.
#
# Each call below runs under a bounded wait, so a call that parks fails the
# example instead of hanging the suite. A call that ends does so without
# suspending, long before that bound could matter.
RSpec.describe ClaudeAgentSDK::Client, 'receiving after the CLI stream has ended' do
  # Queue-backed stand-in for the CLI process: +on_user_message+ scripts what
  # it sends back for a prompt, and how its stdout ends.
  let(:transport_class) do
    Class.new do
      def initialize(_options, on_user_message:)
        @on_user_message = on_user_message
        @stdout = Thread::Queue.new
      end

      def connect; end

      def ready?
        true
      end

      def end_input; end

      def close
        exit_cleanly
      end

      def write(line)
        frame = JSON.parse(line, symbolize_names: true)
        if frame[:type] == 'control_request' && frame.dig(:request, :subtype) == 'initialize'
          send_frame(type: 'control_response',
                     response: { subtype: 'success', request_id: frame[:request_id],
                                 response: { commands: [], agents: [], output_style: 'default', models: [],
                                             pid: 4242, session_state: 'idle', capabilities: [] },
                                 pending_permission_requests: [], pending_user_dialog_requests: [] })
        elsif frame[:type] == 'user'
          @on_user_message.call(self)
        end
      end

      def send_frame(frame)
        @stdout << frame
      end

      # stdout reaches EOF after exit status 0.
      def exit_cleanly
        @stdout << :eof
      end

      # What SubprocessCLITransport#read_messages raises at EOF when the CLI
      # exited non-zero.
      def crash(exit_code:, stderr:)
        @stdout << ClaudeAgentSDK::ProcessError.new("Command failed with exit code #{exit_code}",
                                                    exit_code: exit_code, stderr: stderr)
      end

      def read_messages
        loop do
          item = @stdout.pop
          break if item == :eof
          raise item if item.is_a?(Exception)

          yield item
        end
      end
    end
  end

  let(:session_id) { 'c0ffee00-0000-4000-8000-000000000001' }

  def assistant_frame
    { type: 'assistant', parent_tool_use_id: nil, session_id: session_id, uuid: SecureRandom.uuid,
      message: { id: 'msg_01', type: 'message', role: 'assistant', model: 'claude-haiku-4-5-20251001',
                 content: [{ type: 'text', text: 'Four.' }], stop_reason: 'end_turn',
                 usage: { input_tokens: 10, output_tokens: 3 } } }
  end

  def result_frame
    sample_result_message.merge(session_id: session_id, result: 'Four.', stop_reason: 'end_turn',
                                terminal_reason: 'completed', uuid: SecureRandom.uuid)
  end

  # One turn against a CLI scripted by +on_user_message+; yields the client
  # once the prompt is written and the CLI's reaction is queued.
  def with_session(on_user_message)
    Async do |task|
      client = described_class.new(transport_class: transport_class,
                                   transport_args: { on_user_message: on_user_message })
      client.connect
      client.query('What is 2 + 2?')
      yield client, task
    ensure
      client&.disconnect
    end.wait
  end

  # What one receive call did: the message classes it yielded, or :parked
  # when it was still waiting at the bound.
  def receive(task, client, method)
    seen = []
    task.with_timeout(5) { client.public_send(method) { |message| seen << message.class } }
    seen
  rescue Async::TimeoutError
    :parked
  end

  let(:cli_exits_after_the_turn) do
    lambda do |cli|
      cli.send_frame(assistant_frame)
      cli.send_frame(result_frame)
      cli.exit_cleanly
    end
  end

  let(:cli_crashes_mid_turn) do
    lambda do |cli|
      cli.send_frame(assistant_frame)
      cli.crash(exit_code: 1, stderr: 'Killed')
    end
  end

  %i[receive_response receive_messages].each do |method|
    describe "##{method}" do
      it 'ends at once on every call after a clean end of stream' do
        with_session(cli_exits_after_the_turn) do |client, task|
          calls = Array.new(3) { receive(task, client, method) }

          expect(calls).to eq([[ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage], [], []])
        end
      end

      it 'raises the stream error once, then ends at once on every later call' do
        with_session(cli_crashes_mid_turn) do |client, task|
          seen_before_the_crash = []
          expect do
            task.with_timeout(5) { client.public_send(method) { |message| seen_before_the_crash << message.class } }
          end.to raise_error(ClaudeAgentSDK::ProcessError, /exit code 1/)
          expect(seen_before_the_crash).to eq([ClaudeAgentSDK::AssistantMessage])

          expect(Array.new(2) { receive(task, client, method) }).to eq([[], []])
        end
      end
    end
  end

  # A Client can outlive its reactor: once the CLI has exited, the read loop
  # is over, the `Async { }` that connected finishes, and the application may
  # still call receive_* from plain Ruby. The end of the stream has to be
  # remembered there too, where nothing can be put back on the queue (async
  # < 2.29 cannot enqueue outside a task).
  describe 'from plain Ruby, after the reactor has finished' do
    def finished_session(on_user_message)
      client = described_class.new(transport_class: transport_class,
                                   transport_args: { on_user_message: on_user_message })
      Async do
        client.connect
        client.query('What is 2 + 2?')
      end.wait # the CLI exited: the read loop ended, and the reactor with it
      client
    end

    # As #receive above; there is no task here, so the bound is a plain Timeout.
    def receive_without_a_reactor(client, method)
      seen = []
      Timeout.timeout(5) { client.public_send(method) { |message| seen << message.class } }
      seen
    rescue Timeout::Error
      :parked
    end

    %i[receive_response receive_messages].each do |method|
      it "ends ##{method} at once on every call after a clean end of stream" do
        client = finished_session(cli_exits_after_the_turn)
        calls = Array.new(3) { receive_without_a_reactor(client, method) }

        expect(calls).to eq([[ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage], [], []])
      end

      it "raises the stream error from ##{method} once, then ends at once on every later call" do
        client = finished_session(cli_crashes_mid_turn)
        seen_before_the_crash = []
        expect do
          Timeout.timeout(5) { client.public_send(method) { |message| seen_before_the_crash << message.class } }
        end.to raise_error(ClaudeAgentSDK::ProcessError, /exit code 1/)
        expect(seen_before_the_crash).to eq([ClaudeAgentSDK::AssistantMessage])

        expect(Array.new(2) { receive_without_a_reactor(client, method) }).to eq([[], []])
      end
    end
  end
end
