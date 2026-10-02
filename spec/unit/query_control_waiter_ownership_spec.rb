# frozen_string_literal: true

require 'spec_helper'
require 'async'

# Outbound control requests (interrupt, set_model, ...) wait for the CLI's
# response on a waiter that the session's read loop signals. Which waiter is
# safe depends on where the caller runs, not on whether it has an Async task:
# only a fiber of the reactor that owns the Query checks the result slot and
# parks without the read loop being able to run in between. A fiber on
# ANOTHER thread's reactor (`Sync { client.interrupt }` on a request thread
# while the session lives on a background reactor, or a `Sync { }` inside a
# :thread-mode callback) races the read loop exactly like a plain thread, so
# it needs the level-triggered ThreadWaiter too.
#
# No clock takes part in the ordering below. The control-request timeout is
# only the cap that turns a lost wakeup into a failing example.
RSpec.describe ClaudeAgentSDK::Query, 'control requests from a fiber on another reactor' do
  # In-memory stand-in for the CLI. Thread::Queue everywhere: the caller
  # writes from one thread while the owning reactor reads on another.
  let(:transport_class) do
    Class.new do
      attr_reader :held

      def initialize
        @incoming = Thread::Queue.new
        @handled = Thread::Queue.new
        @held = Thread::Queue.new
        @hold_interrupt_response = false
      end

      def hold_interrupt_response!
        @hold_interrupt_response = true
      end

      def connect; end

      def ready?
        true
      end

      def end_input; end

      def close
        @incoming << nil
      end

      def deliver(frame)
        @incoming << frame
      end

      # What CLI 2.1.286 answers to `initialize` (payload trimmed) and to
      # `interrupt`.
      def write(line)
        request = JSON.parse(line, symbolize_names: true)
        return unless request[:type] == 'control_request'

        case request.dig(:request, :subtype)
        when 'initialize'
          deliver(type: 'control_response',
                  response: { subtype: 'success', request_id: request[:request_id],
                              response: { commands: [], agents: [], output_style: 'default', models: [],
                                          pid: 4242, session_state: 'idle', capabilities: [] },
                              pending_permission_requests: [], pending_user_dialog_requests: [] })
        when 'interrupt'
          response = { type: 'control_response',
                       response: { subtype: 'success', request_id: request[:request_id],
                                   response: { still_queued: [] } } }
          @hold_interrupt_response ? @held << response : deliver(response)
        end
      end

      def read_messages
        while (frame = @incoming.pop)
          yield frame
          @handled << frame # the read loop is done with this frame
        end
      ensure
        @handled << :read_loop_ended
      end

      # Blocks until the read loop has finished handling +frame+.
      def wait_until_handled(frame)
        loop do
          seen = @handled.pop
          return if seen.equal?(frame)
          raise 'the read loop ended before it handled the frame' if seen == :read_loop_ended
        end
      end
    end
  end

  # A result-slot Hash that can hold its next #key? caller right after the
  # check, as a thread preempted between "is my response there?" and "park".
  let(:holding_slots_class) do
    Class.new(Hash) do
      attr_reader :checked

      def hold_next_check!
        @checked = Thread::Queue.new
        @release = Thread::Queue.new
        @armed = true
      end

      def release!
        @release << true
      end

      def key?(request_id)
        present = super
        if @armed
          @armed = false
          @checked << present
          @release.pop
        end
        present
      end
    end
  end

  let(:transport) { transport_class.new }
  let(:query) { described_class.new(transport: transport, is_streaming_mode: true) }

  before do
    # The cap for a response that never wakes its sender (1200 s by default).
    allow(query).to receive(:control_request_timeout_seconds).and_return(10)
  end

  # Runs the session — read loop included — on a reactor of its own, on a
  # background thread, for the duration of the block.
  def with_session_on_its_own_reactor
    ready = Thread::Queue.new
    finish = Thread::Queue.new
    owner = Thread.new do
      Thread.current.report_on_exception = false
      Sync do
        query.start
        query.initialize_protocol
        ready << :ready
        finish.pop
      ensure
        query.close
      end
    ensure
      ready << :owner_exited # never leaves the example waiting for a session that did not start
    end
    raise 'the session did not start' unless ready.pop == :ready

    yield
  ensure
    finish << :done
    owner.join # re-raises whatever ended the owning thread
  end

  # Calls the control method from a reactor of its own on a new thread. The
  # thread's value is the response, or the error the call raised.
  def interrupt_from_another_reactor(announce_exit_on: nil)
    Thread.new do
      Sync { query.interrupt }
    rescue StandardError => e
      e
    ensure
      announce_exit_on&.push(:sender_exited)
    end
  end

  def read_task
    query.instance_variable_get(:@task)
  end

  it 'answers a control method called inside Sync on another thread and keeps the session running' do
    with_session_on_its_own_reactor do
      # The caller has an Async task, but on a reactor that is not the Query's.
      answer = interrupt_from_another_reactor.value
      aggregate_failures do
        expect(answer).to eq({ still_queued: [] })
        expect(read_task).to be_alive # signalling the caller did not take the read loop down
      end
    end
  end

  it 'does not lose the response routed between the sender checking its slot and parking' do
    slots = holding_slots_class.new
    query.instance_variable_set(:@pending_control_results, slots)
    transport.hold_interrupt_response!

    with_session_on_its_own_reactor do
      slots.hold_next_check!
      sender = interrupt_from_another_reactor(announce_exit_on: slots.checked)

      expect(slots.checked.pop).to be(false) # the sender looked: no response yet
      response = transport.held.pop
      transport.deliver(response)            # the CLI's response arrives ...
      transport.wait_until_handled(response) # ... and the read loop has stored and signalled it
      slots.release!                         # only now does the sender go on to park

      answer = sender.value
      aggregate_failures do
        expect(answer).to eq({ still_queued: [] })
        expect(read_task).to be_alive
      end
    ensure
      slots.release!
      sender&.join
    end
  end
end
