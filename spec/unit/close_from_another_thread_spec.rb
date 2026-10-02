# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'timeout'

# Query#close — and so Client#disconnect — may be called from a thread other
# than the one whose reactor owns the session: an application thread that
# cancels a session, or a tool handler / hook / can_use_tool callback on its
# :thread-mode worker. Async::Task#stop needs the owning reactor, so such a
# caller hands the close to a task on that reactor and waits for it.
#
# The task that takes the request is an idle watcher, and it is `transient`
# so that a session nobody closes never keeps its reactor alive. A transient
# task is also the one kind a reactor does not wait for. The close stops the
# read loop, the end of the stream wakes the session's own task, and once
# that task has nothing left to do the reactor is finished: it used to wind
# down and stop the watcher at the first point where the transport's teardown
# waited for the CLI. SubprocessCLITransport then does what it does for a
# cancelled close — SIGTERM — instead of closing stdin and giving the CLI the
# grace period it needs for its last session write, and the caller was
# released before the child was reaped. The close now runs in a task the
# reactor waits for.
#
# No clock orders anything below. The one bound, around each example, only
# turns a lost wake-up into a failure instead of a hung suite.
RSpec.describe ClaudeAgentSDK::Query, 'closed from another thread' do
  # Stand-in for SubprocessCLITransport, with the part of its #close that
  # matters here: stdin EOF, then a WAIT for the CLI to exit — a suspension
  # point on the reactor, like wait_process_with_timeout — and SIGTERM from
  # the ensure when the close is unwound while it waits. The journal reads
  # like the CLI's own event log.
  let(:transport_class) do
    Class.new do
      attr_reader :journal, :teardown_task, :teardown_task_was_transient

      def initialize(_options = nil, **_transport_args)
        @stdout = Thread::Queue.new
        @journal = []
        # Closed queues as latches: #pop parks a fiber or a thread until
        # #close, and returns at once ever after.
        @stdin_closed = Thread::Queue.new
        @exited = Thread::Queue.new
        @closing = false
      end

      def connect; end

      def ready?
        !@closing
      end

      # What CLI 2.1.286 answers to `initialize` (payload trimmed).
      def write(line)
        raise ClaudeAgentSDK::CLIConnectionError, 'ProcessTransport is not ready for writing' if @closing

        frame = JSON.parse(line, symbolize_names: true)
        return unless frame[:type] == 'control_request' && frame.dig(:request, :subtype) == 'initialize'

        deliver(type: 'control_response',
                response: { subtype: 'success', request_id: frame[:request_id],
                            response: { commands: [], agents: [], output_style: 'default', models: [],
                                        pid: 4242, session_state: 'idle', capabilities: [] },
                            pending_permission_requests: [], pending_user_dialog_requests: [] })
      end

      def deliver(frame)
        @stdout << frame
      end

      def read_messages
        while (frame = @stdout.pop)
          yield frame
        end
      end

      def end_input
        close_stdin
      end

      def close
        return if @closing

        @closing = true
        @teardown_task = Async::Task.current?
        @teardown_task_was_transient = @teardown_task&.transient?
        graceful = false
        begin
          close_stdin
          @exited.pop # parks the closing task until the CLI is gone
          @journal << :cli_exited
          graceful = true
        ensure
          @journal << :sigterm unless graceful
          @stdout.close
        end
      end

      # Parks the caller until the teardown has closed stdin.
      def wait_for_stdin_eof
        @stdin_closed.pop
      end

      def exit_cli
        @exited.close
      end

      # What the CLI does about stdin EOF: it exits.
      def exit_on_stdin_eof
        wait_for_stdin_eof
        exit_cli
      end

      # The CLI's stdout ends: the read loop is over, the process is not.
      def end_stdout
        @stdout.close
      end

      private

      def close_stdin
        return if @stdin_closed.closed?

        @journal << :stdin_eof
        @stdin_closed.close
      end
    end
  end

  let(:transport) { transport_class.new }
  let(:query) { described_class.new(transport: transport, is_streaming_mode: true) }
  let(:threads) { [] }

  around do |example|
    Timeout.timeout(60) { example.run }
  ensure
    threads.each { |thread| reap(thread) }
  end

  def in_thread(&block)
    thread = Thread.new do
      Thread.current.report_on_exception = false
      block.call
    end
    threads << thread
    thread
  end

  # A failed example can leave a thread parked; one that raised has already
  # failed the example through its own join.
  def reap(thread)
    thread.kill
    thread.join
  rescue StandardError
    nil
  end

  # The session on a reactor of its own. Nothing was asked of the CLI, so its
  # task parks until the close ends the stream — and then has nothing left to
  # do. Its last act scripts the CLI (exit on stdin EOF) from the reactor's
  # own thread. That puts the wake-up of the teardown, which is waiting for
  # that exit, behind the end of the task: a reactor that winds down as soon
  # as the task is over stops the teardown before it can see the exit.
  def session_with_nothing_left_to_do(parked)
    in_thread do
      Sync do
        query.start
        parked << true
        query.receive_messages { |_message| nil }
        transport.exit_on_stdin_eof
      end
    end
  end

  describe 'when the session task has nothing left to do' do
    it 'closes stdin and waits for the CLI to exit before it returns' do
      parked = Thread::Queue.new
      session = session_with_nothing_left_to_do(parked)
      parked.pop

      query.close
      transport.journal << :close_returned
      session.join

      expect(transport.journal).to eq(%i[stdin_eof cli_exited close_returned])
    end

    it 'runs the teardown on a task the reactor waits for' do
      parked = Thread::Queue.new
      session = session_with_nothing_left_to_do(parked)
      parked.pop

      query.close
      session.join

      expect(transport.teardown_task_was_transient).to be(false)
    end

    # The watcher is a child of the task that started the session. When that
    # task and the read loop are both over, async moves it up the tree — here
    # all the way to the reactor, which unrelated work keeps alive. A task
    # spawned through the reactor from there would become a child of the
    # watcher, and a reactor only counts its own children.
    it 'does so after the watcher has been re-parented to the reactor' do
      started = Thread::Queue.new
      stream_ended = Thread::Queue.new
      session = in_thread do
        Fiber.set_scheduler(Async::Scheduler.new)
        Fiber.schedule { query.start } # over at once; the read loop keeps it in the tree
        Fiber.schedule do              # unrelated work on the same reactor
          started << true
          query.receive_messages { |_message| nil }
          stream_ended << true
          transport.exit_on_stdin_eof
        end
      ensure
        Fiber.set_scheduler(nil) # runs the reactor until its tasks have finished
      end
      started.pop
      transport.end_stdout
      stream_ended.pop
      expect(query.instance_variable_get(:@close_watcher).parent).to be_a(Async::Scheduler)

      query.close
      transport.journal << :close_returned
      session.join

      expect(transport.journal).to eq(%i[stdin_eof cli_exited close_returned])
    end
  end

  # What the watcher's `ensure` guaranteed still holds: a teardown that is
  # itself cancelled — the transport TERMs the CLI then — never strands the
  # caller.
  it 'still releases the caller when the teardown itself is stopped' do
    parked = Thread::Queue.new
    session = in_thread do
      Sync do |task|
        query.start
        parked << true
        query.receive_messages { |_message| nil }
        transport.wait_for_stdin_eof
        task.stop # the application stops the session's tasks, the teardown among them
      end
    end
    parked.pop

    query.close
    transport.journal << :close_returned
    session.join

    expect(transport.journal).to eq(%i[stdin_eof sigterm close_returned])
  end

  # A waiting caller checks every 100 ms that the reactor-side task answering
  # it is still alive, and falls back to a direct close when it is not (the
  # reactor is gone). While a teardown is in flight that check has to see the
  # task running it. The session's own task stays busy in these examples, so
  # no reactor winds down: the teardown is simply slow.
  describe 'while the teardown is still waiting for the CLI' do
    # Reports, as the asking Thread, every check whether +task+ is alive.
    def report_liveness_checks(task, signals)
      task.define_singleton_method(:alive?) do
        signals << Thread.current
        super()
      end
    end

    def busy_session(hold)
      started = Thread::Queue.new
      session = in_thread do
        Sync do
          query.start
          started << true
          hold.pop
        end
      end
      started.pop
      session
    end

    def closing_thread(signals)
      in_thread do
        query.close
        transport.journal << :close_returned
        signals << :returned
      end
    end

    it 'does not return before the CLI has exited, however long that takes' do
      hold = Thread::Queue.new
      session = busy_session(hold)
      signals = Thread::Queue.new
      closer = closing_thread(signals)
      transport.wait_for_stdin_eof
      report_liveness_checks(transport.teardown_task, signals)

      # Two liveness checks later — or once the caller has (wrongly) returned.
      2.times { break if signals.pop == :returned }
      transport.exit_cli
      closer.join
      hold << true
      session.join

      expect(transport.journal).to eq(%i[stdin_eof cli_exited close_returned])
    end

    it 'keeps a second caller waiting for the same teardown' do
      hold = Thread::Queue.new
      session = busy_session(hold)
      signals = Thread::Queue.new
      first = closing_thread(signals)
      transport.wait_for_stdin_eof
      report_liveness_checks(transport.teardown_task, signals)
      second = closing_thread(signals)

      # Until the second caller has seen the teardown in flight — or has
      # (wrongly) returned.
      loop do
        signal = signals.pop
        break if signal == :returned || signal == second
      end
      transport.exit_cli
      [first, second].each(&:join)
      hold << true
      session.join

      expect(transport.journal).to eq(%i[stdin_eof cli_exited close_returned close_returned])
    end
  end

  describe 'through Client#disconnect' do
    # Client builds its transport itself; hand it the scripted one.
    let(:client_transport_class) do
      scripted = transport
      Class.new { define_singleton_method(:new) { |*_args, **_kwargs| scripted } }
    end

    it 'returns to a plain thread once the CLI has exited' do
      client = ClaudeAgentSDK::Client.new(transport_class: client_transport_class)
      parked = Thread::Queue.new
      session = in_thread do
        Sync do
          client.connect
          parked << true
          client.receive_response { |_message| nil }
          transport.exit_on_stdin_eof
        end
      end
      parked.pop

      client.disconnect
      transport.journal << :disconnect_returned
      session.join

      expect(transport.journal).to eq(%i[stdin_eof cli_exited disconnect_returned])
    end

    # A :thread-mode callback runs on a worker thread; the task that waits
    # for it is a child of the read loop the close stops.
    it 'returns to a :thread-mode callback once the CLI has exited' do
      client = nil
      returned = Thread::Queue.new
      can_use_tool = lambda do |_tool_name, _input, _context|
        client.disconnect
        transport.journal << :disconnect_returned
        ClaudeAgentSDK::PermissionResultAllow.new
      ensure
        returned << true
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :thread, can_use_tool: can_use_tool)
      client = ClaudeAgentSDK::Client.new(options: options, transport_class: client_transport_class)
      session = in_thread do
        Sync do
          client.connect
          transport.deliver(type: 'control_request', request_id: 'f3a1c2d4-0b7e-4c1a-9d52-6e8f0a1b2c3d',
                            request: { subtype: 'can_use_tool', tool_name: 'Bash',
                                       input: { command: 'git status', description: 'Show working tree status' },
                                       permission_suggestions: [], tool_use_id: 'toolu_01Hq7XvKc2mRt9LwZ3nYb5Ds' })
          client.receive_response { |_message| nil }
          transport.exit_on_stdin_eof
        end
      end

      returned.pop
      session.join

      expect(transport.journal).to eq(%i[stdin_eof cli_exited disconnect_returned])
    end
  end
end
