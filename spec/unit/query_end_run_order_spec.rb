# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'async/queue'

# Query#end_run has one suspension point: stopping the ceiling sleeper hands
# the reactor to whatever else is ready. A stream_input task that is ready at
# that moment writes its next message, and the run that message belongs to is
# decided by what it sees: an ended run is reopened as a fresh one, a run
# that is still open is joined. So the run must already count as ended when
# end_run reaches that suspension point, or the message joins the run that is
# about to end and stdin closes before its own run produced a frame.
#
# No clock takes part in the ordering below: two enqueues make the read loop
# and the stream task ready, in that order, and the example then only yields
# to the reactor until the state it waits for is there.
RSpec.describe ClaudeAgentSDK::Query, 'ending a run while the next streamed message is ready' do
  # Queue-backed stand-in for the CLI: frames are fed to the read loop one by
  # one, and every stdin close records how many messages had been written.
  let(:transport_class) do
    Class.new do
      attr_reader :frames, :writes, :stdin_closed_after, :frames_handled

      def initialize
        @frames = Async::Queue.new
        @writes = []
        @stdin_closed_after = []
        @frames_handled = 0
      end

      def connect; end

      def ready?
        true
      end

      def read_messages
        while (frame = @frames.dequeue) != :eof
          yield frame
          @frames_handled += 1 # the read loop is done with this frame
        end
      end

      def write(line)
        @writes << line
      end

      def end_input
        @stdin_closed_after << @writes.length
      end

      def close
        @frames.enqueue(:eof)
      end
    end
  end

  # The frames CLI 2.1.286 sends around a turn when the transport asked for
  # session state: "running", the turn, its result, then "idle".
  def session_state(value)
    { type: 'system', subtype: 'session_state_changed', state: value, sdk_host_only: true,
      uuid: SecureRandom.uuid, session_id: 'b1c2d3e4-0000-4000-8000-000000000001' }
  end

  def turn_result
    sample_result_message.merge(result: 'done', stop_reason: 'end_turn', terminal_reason: 'completed')
  end

  def user_message(content)
    { type: 'user', message: { role: 'user', content: content }, parent_tool_use_id: nil, session_id: '' }
  end

  def reactor_settles(task, limit: 10)
    task.with_timeout(limit) { task.yield until yield }
  end

  it 'keeps stdin open for a message written while the previous run was ending' do
    transport = transport_class.new
    gate = Async::Queue.new
    prompts = Enumerator.new do |yielder|
      yielder << user_message('first')
      gate.dequeue
      yielder << user_message('second')
    end
    # A hook keeps the control channel in use, so stdin waits for the run's end.
    query = described_class.new(transport: transport, is_streaming_mode: true,
                                hooks: { 'PreToolUse' => [{ matcher: 'Bash', hooks: [proc {}] }] })

    Async do |task|
      query.start
      streamer = task.async { query.stream_input(prompts) } # writes "first", parks on the gate
      transport.frames.enqueue(session_state('running'))
      transport.frames.enqueue(turn_result)
      reactor_settles(task) { transport.frames_handled == 2 }
      # The precondition of the whole example: the result armed the ceiling
      # sleeper, so ending the run has a task to stop — the suspension point.
      expect(query.instance_variable_get(:@run_end_ceiling_task)).not_to be_nil

      transport.frames.enqueue(session_state('idle')) # the read loop becomes ready first ...
      gate.enqueue(:go)                               # ... and the stream task second
      reactor_settles(task) { transport.writes.length == 2 && transport.frames_handled == 3 }
      3.times { task.yield } # whatever the ended run woke gets its turn

      # "second" owes a run of its own, and none of that run's frames exists yet.
      expect(transport.stdin_closed_after).to be_empty

      transport.frames.enqueue(session_state('running'))
      transport.frames.enqueue(turn_result)
      transport.frames.enqueue(session_state('idle'))
      task.with_timeout(10) { streamer.wait }
      expect(transport.stdin_closed_after).to eq([2])
    ensure
      query.close
    end.wait
  end
end
