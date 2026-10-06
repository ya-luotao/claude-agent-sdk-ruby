# frozen_string_literal: true

require 'spec_helper'
require 'async'

# When query() may close stdin, as a table: each example is a sequence of
# events through Query::RunLifecycle's interface and what it must leave
# behind. No Query, no transport and no clock take part: the lifecycle gets a
# FakeSleeper, which the example wakes by hand, and three facts it would read
# from its Query. Only the #wait rows need a reactor.
#
# The groups are named after the behaviours the lifecycle has to keep:
#
#   B1   with a control channel in use, the run ends at the CLI's "idle" after
#        a result (Python #1279); "idle" before any result ends nothing
#   B2   a CLI that sends no session state ends the run at the first result
#        with no tracked task in flight (#1088); only local_agent and
#        local_workflow tasks are tracked
#   B3   neither a result nor "idle" ends the run while a tracked task is in
#        flight
#   B4   the ceiling: armed at a result, and at each "running" after one, while
#        the CLI still reports work; never before the first result, mid-turn,
#        once the run ended, is final or the Query closed, or with no control
#        channel in use; 0 means no ceiling, and the sleep is capped
#   B5   a main-thread turn stops the clock and reopens the run, a subagent's
#        frames do not; "requires_action" stops it and the "running" that
#        follows restarts it; a ceiling that passes with a tracked agent in
#        flight stands down, and the clock starts over once the agent settles
#   B6   a ceiling that passes while the SDK is still answering a control
#        request re-arms instead of ending the run
#   B7   each message written owes a run of its own
#   B9   an ended run is reopened as a fresh one, which the waiters of the
#        ended run do not wait for; a final run is never reopened, and being
#        final does not end it
#   B10  the run is marked ended before the sleeper is stopped
#   B11  every exit path clears the sleeper
#   B14  empty input is final only: nothing is stopped, nothing is ended
#   Q5   a wake from an earlier arm never touches a later one
#
# The wiring of a Query to its lifecycle (which frames reach it and in what
# order with the mirror flush and the stream, the real sleeper, the real
# predicates) is covered through Query in query_run_end_spec.rb and
# query_end_run_order_spec.rb.
RSpec.describe ClaudeAgentSDK::Query::RunLifecycle do
  let(:sleeper) { FakeSleeper.new }
  # What the lifecycle reads from its Query, each time it asks.
  let(:facts) { { bidirectional_needs: true, closed: false, control_requests_in_flight: false } }
  let(:lifecycle) do |example|
    described_class.new(ceiling_ms: example.metadata.fetch(:ceiling_ms, 600_000), sleeper: sleeper,
                        bidirectional_needs: -> { facts[:bidirectional_needs] },
                        closed: -> { facts[:closed] },
                        control_requests_in_flight: -> { facts[:control_requests_in_flight] })
  end

  # Once an event is over, the lifecycle holds a sleeper exactly when one is
  # still sleeping, and no other sleeps: it never loses track of one (an arm
  # replaced without being stopped stays pending), and never keeps one that
  # woke or was stopped.
  after { expect(sleeper.pending_arms.length).to eq(lifecycle.ceiling_armed? ? 1 : 0) }

  def state(value)
    { type: 'system', subtype: 'session_state_changed', state: value, session_id: 's', sdk_host_only: true }
  end

  def result
    sample_result_message
  end

  def turn_frame(type = 'assistant', parent_tool_use_id: nil)
    { type: type, message: { role: 'assistant', content: [] }, parent_tool_use_id: parent_tool_use_id }
  end

  def task_started(id, task_type = 'local_agent')
    { type: 'system', subtype: 'task_started', task_id: id, task_type: task_type }.compact
  end

  def task_done(id, status = 'completed')
    { type: 'system', subtype: 'task_notification', task_id: id, status: status }
  end

  def task_updated(id, patch)
    { type: 'system', subtype: 'task_updated', task_id: id, patch: patch }
  end

  def feed(*frames)
    frames.each { |frame| lifecycle.frame(frame) }
  end

  # Whether the run had ended after each of +frames+.
  def ended_after_each(*frames)
    frames.map do |frame|
      lifecycle.frame(frame)
      lifecycle.ended?
    end
  end

  def armed?
    lifecycle.ceiling_armed?
  end

  describe 'B1: the run ends at idle after a result' do
    it 'does not end at the result while the CLI reports running, and ends at the idle that follows' do
      expect(ended_after_each(state('running'), result, state('idle'))).to eq([false, false, true])
    end

    it 'does not end at an idle that comes before any result, and ends at the result' do
      expect(ended_after_each(state('running'), state('idle'), result)).to eq([false, false, true])
    end

    it 'does the same when idle is the first state the CLI reports' do
      expect(ended_after_each(state('idle'), result)).to eq([false, true])
    end

    # Messages written before any result are merged into fewer turns: results
    # follow each other with no idle until all queued input is served.
    it 'does not end at a second result with no idle in between' do
      expect(ended_after_each(state('running'), result, result, state('idle'))).to eq([false, false, false, true])
    end

    it 'reports the latest session state, and none from a CLI that sends none' do
      expect(lifecycle.session_state).to be_nil
      feed(result)
      expect(lifecycle.session_state).to be_nil

      feed(state('running'), state('requires_action'))
      expect(lifecycle.session_state).to eq('requires_action')
    end
  end

  describe 'B2: with no session state, the run ends at the first result with no tracked task in flight' do
    it 'ends at the first result' do
      expect(ended_after_each(result)).to eq([true])
    end

    it 'ends at the first result when nothing needs the control channel, whatever the state says' do
      facts[:bidirectional_needs] = false

      expect(ended_after_each(state('running'), result)).to eq([false, true])
    end

    it 'tracks task_started only for deferring task types' do
      feed(task_started('a', 'local_agent'), task_started('w', 'local_workflow'),
           task_started('s', 'local_shell'), task_started('n', nil))

      expect(%w[a w s n].select { |id| lifecycle.inflight?(id) }).to eq(%w[a w])
    end

    it 'ignores frames with a missing or empty task_id' do
      feed({ type: 'system', subtype: 'task_started', task_type: 'local_agent' }, task_started(''))

      expect([nil, ''].select { |id| lifecycle.inflight?(id) }).to be_empty
      expect(ended_after_each(result)).to eq([true]) # nothing in the ledger holds the run open
    end

    it 'clears on task_notification regardless of status' do
      feed(task_started('a'), task_done('a', 'failed'))

      expect(lifecycle.inflight?('a')).to be(false)
      expect(ended_after_each(result)).to eq([true])
    end

    it 'clears on terminal task_updated statuses only' do
      feed(task_started('a'), task_updated('a', { status: 'running' }))
      expect(lifecycle.inflight?('a')).to be(true)

      feed(task_updated('a', { status: 'killed' }))
      expect(lifecycle.inflight?('a')).to be(false)
      expect(ended_after_each(result)).to eq([true])
    end

    it 'tolerates a non-Hash or absent patch on task_updated' do
      feed(task_started('a'), task_updated('a', 'completed'), { type: 'system', subtype: 'task_updated', task_id: 'a' })

      expect(lifecycle.inflight?('a')).to be(true)
    end

    it 'ignores background_tasks_changed in both directions' do
      feed(task_started('a'), { type: 'system', subtype: 'background_tasks_changed', tasks: [] })
      expect(lifecycle.inflight?('a')).to be(true)

      feed({ type: 'system', subtype: 'background_tasks_changed',
             tasks: [{ task_id: 'b', task_type: 'local_agent', description: 'other' }] })
      expect(%w[a b].select { |id| lifecycle.inflight?(id) }).to eq(%w[a])
    end

    it 'is a no-op for terminal frames about unknown task ids' do
      feed(task_done('ghost'), task_updated('ghost', { status: 'failed' }))

      expect(lifecycle.inflight?('ghost')).to be(false)
      expect(ended_after_each(result)).to eq([true])
    end
  end

  describe 'B3: a tracked task in flight holds the run open' do
    { 'a task_notification' => { subtype: 'task_notification', status: 'completed' },
      'a terminal task_updated' => { subtype: 'task_updated', patch: { status: 'killed' } } }.each do |drain, settled|
      it "does not end at a result with a task in flight, and ends at the next one once #{drain} settled it" do
        frames = [task_started('bg'), result, { type: 'system', task_id: 'bg', **settled }, result]

        expect(ended_after_each(*frames)).to eq([false, false, false, true])
      end
    end

    it 'does not end at idle either: only the idle of the follow-up turn ends the run (B2/B3)' do
      frames = [task_started('bg'), result, state('idle'), task_done('bg'), state('running'), turn_frame, result, state('idle')]

      expect(ended_after_each(*frames)).to eq([false, false, false, false, false, false, false, true])
    end

    it 'does not hold the run open for a task that settled before the result when the CLI reports no state' do
      expect(ended_after_each(task_started('bg'), task_done('bg'), result)).to eq([false, false, true])
    end
  end

  describe 'B4: the ceiling is armed only for the wait between turns' do
    capped_seconds = { 300 => 0.3, 10**12 => 2_147_483.647 }

    [nil, 'running', 'idle', 'requires_action'].each do |session_state|
      [0, 300, 10**12].each do |ms|
        [true, false].each do |needs|
          arms = session_state == 'running' && ms.positive? && needs
          ends = !needs || session_state.nil? || session_state == 'idle'
          title = "a result under state #{session_state.inspect}, ceiling #{ms}, control channel #{needs ? 'in use' : 'unused'}: " \
                  "#{arms ? "arms for #{capped_seconds.fetch(ms)}s" : 'arms nothing'}, #{ends ? 'ends the run' : 'leaves the run open'}"

          it title, ceiling_ms: ms do
            facts[:bidirectional_needs] = needs
            feed(state(session_state)) if session_state
            feed(result)

            expect([armed?, lifecycle.ended?]).to eq([arms, ends])
            expect(sleeper.arms.map(&:seconds)).to eq(arms ? [capped_seconds.fetch(ms)] : [])
          end
        end
      end
    end

    it 'caps the sleep at MAX_RUN_END_CEILING_MS', ceiling_ms: 10**12 do
      feed(state('running'), result)

      expect(sleeper.arms.last.seconds).to eq(ClaudeAgentSDK::Query::MAX_RUN_END_CEILING_MS / 1000.0)
    end

    it 'is not armed by running before the first result' do
      feed(state('running'))

      expect(armed?).to be(false)
    end

    it 'starts over at each running after a result, and at each result' do
      feed(state('running'), result)
      expect([sleeper.arms.length, sleeper.stops]).to eq([1, 0])

      feed(state('running'))
      expect([sleeper.arms.length, sleeper.stops]).to eq([2, 1])

      feed(result)
      expect([sleeper.arms.length, sleeper.stops]).to eq([3, 2])
      expect(armed?).to be(true)
    end

    it 'is not armed mid-turn' do
      feed(state('running'), result, turn_frame, task_started('bg'), task_done('bg'), state('running'))

      expect(armed?).to be(false)
      expect(lifecycle.ended?).to be(false)
    end

    it 'is not armed once the run has ended' do
      feed(state('running'), result)
      sleeper.fire
      expect(lifecycle.ended?).to be(true)

      feed(result) # another result of the same run: no state change reopened it
      expect(armed?).to be(false)
    end

    it 'is not armed once the run is final, ended or not' do
      feed(state('running'), result)
      lifecycle.stdin_closing # final, and the CLI never reported idle: the run has not ended
      feed(state('running'))
      expect([armed?, lifecycle.ended?]).to eq([false, false])

      feed(turn_frame, result)
      expect(armed?).to be(false)
    end

    it 'is not armed while the Query is closed (B4 closed)' do
      feed(state('running'))
      facts[:closed] = true
      feed(result)

      expect(armed?).to be(false)
      expect(lifecycle.ended?).to be(false)
    end
  end

  describe 'B5: what stops the clock and what starts it over' do
    %w[assistant stream_event].each do |type|
      it "is stopped by a main-thread #{type} and re-armed by the turn's result" do
        feed(state('running'), result, turn_frame(type))
        expect(armed?).to be(false)

        sleeper.fire_stale # the stopped sleeper was already waking up
        expect([armed?, lifecycle.ended?]).to eq([false, false])

        feed(result)
        expect(armed?).to be(true)
        sleeper.fire
        expect(lifecycle.ended?).to be(true)
      end

      it "is not stopped by a subagent's #{type}" do
        feed(state('running'), result, turn_frame(type, parent_tool_use_id: 'toolu_1'))

        expect(armed?).to be(true)
        expect([sleeper.arms.length, sleeper.stops]).to eq([1, 0]) # the same sleeper, not a new one
        sleeper.fire
        expect(lifecycle.ended?).to be(true)
      end
    end

    it 'reopens a run the ceiling ended when a main-thread turn starts with no state change' do
      feed(state('running'), result)
      sleeper.fire
      expect(lifecycle.ended?).to be(true)

      feed(turn_frame)
      expect([lifecycle.ended?, armed?]).to eq([false, false])
      expect(ended_after_each(result, state('idle'))).to eq([false, true])
    end

    it 'does not reopen an ended run for a subagent frame' do
      feed(state('running'), result, state('idle'), turn_frame(parent_tool_use_id: 'toolu_1'))

      expect(lifecycle.ended?).to be(true)
    end

    it 'is stopped by requires_action and re-armed by the running that follows' do
      feed(state('running'), result, state('requires_action'))
      expect(armed?).to be(false)

      sleeper.fire_stale
      expect([armed?, lifecycle.ended?]).to eq([false, false])

      feed(state('running'))
      expect(armed?).to be(true)
      sleeper.fire
      expect(lifecycle.ended?).to be(true)
    end

    it 'is not armed by a result that arrives while the SDK is answering a request' do
      feed(state('requires_action'), result)
      expect([armed?, lifecycle.ended?]).to eq([false, false])

      feed(state('running'))
      expect(armed?).to be(true)
      sleeper.fire
      expect(lifecycle.ended?).to be(true)
    end

    %w[running requires_action].each do |wake|
      it "reopens an ended run for work the CLI takes up after idle (#{wake})" do
        feed(state('running'), result, state('idle'))
        expect(lifecycle.ended?).to be(true)

        feed(state(wake))
        expect(lifecycle.ended?).to be(false)
        expect(armed?).to be(wake == 'running') # past a result, between turns
        expect(ended_after_each(state('running'), turn_frame, result, state('idle'))).to eq([false, false, false, true])
      end
    end

    it 'leaves a tracked agent alone when the ceiling passes, and starts over once the agent settles' do
      feed(state('running'), task_started('bg'), result)
      expect(armed?).to be(true)

      sleeper.fire # with bg still running
      expect([armed?, lifecycle.ended?]).to eq([false, false])

      feed(task_done('bg'))
      expect(armed?).to be(true)
      sleeper.fire
      expect(lifecycle.ended?).to be(true)
    end

    it 'does not start over when a task settles while another is still in flight' do
      feed(state('running'), task_started('one'), task_started('two'), result)
      sleeper.fire
      feed(task_done('one'))
      expect(armed?).to be(false)

      feed(task_done('two'))
      expect(armed?).to be(true)
    end
  end

  describe 'B6: a ceiling that passes under a control request the SDK is still answering' do
    it 're-arms instead of ending the run, and ends it at the next wake once the request is answered' do
      feed(state('running'), result)
      facts[:control_requests_in_flight] = true
      sleeper.fire
      expect([armed?, lifecycle.ended?]).to eq([true, false]) # the clock starts over
      expect(sleeper.arms.length).to eq(2)

      facts[:control_requests_in_flight] = false
      sleeper.fire
      expect([armed?, lifecycle.ended?]).to eq([false, true])
    end

    it 'leaves the request alone when a tracked agent is in flight too: the agent decides' do
      feed(state('running'), task_started('bg'), result)
      facts[:control_requests_in_flight] = true
      sleeper.fire

      expect([armed?, lifecycle.ended?]).to eq([false, false])
    end
  end

  describe 'B7: a message that is about to be written owes a run of its own' do
    it 'reopens an ended run and arms nothing' do
      feed(result)
      expect(lifecycle.ended?).to be(true)

      lifecycle.message_will_write
      expect([lifecycle.ended?, armed?]).to eq([false, false])
    end

    it 'leaves a run that has not ended as it is, and stops its clock' do
      feed(state('running'), result)
      lifecycle.message_will_write

      expect([lifecycle.ended?, armed?, sleeper.stops]).to eq([false, false, 1])
    end

    it "owes a result of its own: a late idle of the previous message's run does not end it" do
      feed(state('running'), result, state('idle'))
      lifecycle.message_will_write

      expect(ended_after_each(state('idle'), state('running'), result, state('idle'))).to eq([false, false, false, true])
    end

    it 'does not arm at a running that comes before its own result' do
      feed(state('running'), result, state('idle'))
      lifecycle.message_will_write
      feed(state('running'))

      expect(armed?).to be(false)
    end

    it 'releases the waiter the ended run woke, and makes a later wait wait for the new run' do
      Async do |task|
        woken = task.async { lifecycle.wait }
        feed(result) # the run the first waiter holds ends
        lifecycle.message_will_write # and a fresh one takes its place
        task.with_timeout(10) { woken.wait }

        later = task.async { lifecycle.wait }
        3.times { task.yield }
        expect(later.finished?).to be(false)

        feed(result)
        task.with_timeout(10) { later.wait }
        expect(lifecycle.ended?).to be(true)
      ensure
        [woken, later].each { |waiter| waiter&.stop }
      end.wait
    end
  end

  describe 'B9: final' do
    it 'keeps an ended run ended, whatever comes next' do
      feed(result)
      lifecycle.stdin_closing
      expect([lifecycle.final?, lifecycle.ended?]).to eq([true, true])

      lifecycle.message_will_write
      feed(state('running'), turn_frame)
      expect([lifecycle.final?, lifecycle.ended?]).to eq([true, true])
    end

    it 'does not end a run that has not ended' do
      expect(lifecycle.final?).to be(false)
      feed(state('running'), result)
      lifecycle.stdin_closing

      expect([lifecycle.final?, lifecycle.ended?]).to eq([true, false])
      expect(ended_after_each(state('idle'))).to eq([true]) # the CLI's idle still ends it
    end
  end

  describe 'B10: the run is ended before its sleeper is stopped' do
    # Stopping a real sleeper hands the reactor to whatever else is ready; a
    # message written then must find the run already ended (B7).
    def ended_when_stopped
      seen = []
      sleeper.on_stop = -> { seen << lifecycle.ended? }
      yield
      seen
    ensure
      sleeper.on_stop = nil
    end

    it 'at the idle that ends the run' do
      feed(state('running'), result)

      expect(ended_when_stopped { feed(state('idle')) }).to eq([true])
    end

    it 'when the reader is gone' do
      feed(state('running'), result)

      expect(ended_when_stopped { lifecycle.reader_gone }).to eq([true])
    end
  end

  describe 'B11: every exit path clears the sleeper' do
    before { feed(state('running'), result) }

    it 'reader_gone stops it, ends the run and makes it final' do
      lifecycle.reader_gone

      expect([armed?, sleeper.stops, lifecycle.ended?, lifecycle.final?]).to eq([false, 1, true, true])
    end

    it 'stdin_closing stops it and makes the run final' do
      lifecycle.stdin_closing

      expect([armed?, sleeper.stops, lifecycle.ended?, lifecycle.final?]).to eq([false, 1, false, true])
    end
  end

  # A characterization of the empty-input shape, not a promise: closing stdin
  # with nothing written cannot tell a resume that has work of its own from one
  # that has none (anthropics/claude-agent-sdk-python#1226), and a resumed CLI
  # may have armed the ceiling by then. The sleeper is left for the read task's
  # stop.
  describe 'B14: empty input is final only (#1226)' do
    it 'leaves an armed sleeper armed and the run unended' do
      feed(state('running'), result)
      lifecycle.empty_input

      expect([lifecycle.final?, armed?, sleeper.stops, lifecycle.ended?]).to eq([true, true, 0, false])
    end

    it 'is final with nothing armed too' do
      lifecycle.empty_input

      expect([lifecycle.final?, armed?, lifecycle.ended?]).to eq([true, false, false])
    end
  end

  describe 'Q5: a wake from an earlier arm never touches a later one' do
    it 'stands down when its arm was replaced by the re-arm under a control request' do
      feed(state('running'), result) # the first arm
      facts[:control_requests_in_flight] = true
      sleeper.fire # re-armed: the second arm
      facts[:control_requests_in_flight] = false

      sleeper.fire_stale # the first arm wakes again
      expect([armed?, lifecycle.ended?, sleeper.stops]).to eq([true, false, 0]) # the second arm is intact

      sleeper.fire
      expect([armed?, lifecycle.ended?]).to eq([false, true])
    end

    it 'stands down when the run was reopened and armed again since' do
      feed(state('running'), result, turn_frame, result) # stopped by the turn, armed again by its result

      sleeper.fire_stale
      expect([armed?, lifecycle.ended?]).to eq([true, false])
    end
  end

  describe '#wait' do
    it 'returns at once when nothing needs the control channel' do
      facts[:bidirectional_needs] = false

      Async { |task| task.with_timeout(10) { lifecycle.wait } }.wait
      expect(lifecycle.ended?).to be(false)
    end

    it 'returns at once when the run has already ended' do
      feed(result)

      Async { |task| task.with_timeout(10) { lifecycle.wait } }.wait
    end

    it 'waits for the end of the run when the control channel is in use' do
      Async do |task|
        waiter = task.async { lifecycle.wait }
        feed(state('running'), result)
        3.times { task.yield }
        expect(waiter.finished?).to be(false)

        feed(state('idle'))
        task.with_timeout(10) { waiter.wait }
      ensure
        waiter&.stop
      end.wait
    end

    it 'is released when the reader is gone' do
      Async do |task|
        waiter = task.async { lifecycle.wait }
        lifecycle.reader_gone
        task.with_timeout(10) { waiter.wait }
      ensure
        waiter&.stop
      end.wait
    end
  end
end
