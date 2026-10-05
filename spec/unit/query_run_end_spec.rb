# frozen_string_literal: true

require 'spec_helper'
require 'async'

# When query() closes stdin on a run that serves control requests (Python
# #1190/#1279): at the CLI's "idle" session state after a result, bounded
# between turns by CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS, and at the first
# result with no tracked task in flight from a CLI that sends no state.
#
# This is the decision as a Query makes it, through its read loop and its
# stdin-closing tasks over a transport double. The decision itself — every
# state and frame order — is tabled in query/run_lifecycle_spec.rb, against
# Query::RunLifecycle alone; what is kept here is what only a Query can
# show: which frames reach the lifecycle and in what order with the mirror
# flush and the stream, the real sleeper, the real predicates.
#
# Nothing here waits on a clock to "let the read loop catch up": frames are
# followed by a barrier (#with_query), and the ceiling is fired by hand
# (#ceiling_passes) in every example but one.
RSpec.describe ClaudeAgentSDK::Query do
  # The transport double. Frames come from +queue+; a Thread::Queue among
  # them is a barrier, which is answered instead of delivered (#with_query).
  # +written+ receives every line the SDK writes.
  def queue_fed_transport(queue)
    ended = []
    written = Thread::Queue.new
    transport = mock_transport
    allow(transport).to receive(:end_input) { ended << true }
    allow(transport).to receive(:write) { |line| written << line }
    allow(transport).to receive(:read_messages) do |&blk|
      loop do
        msg = queue.dequeue
        break if msg == :eof
        next msg.push(:reached) if msg.is_a?(Thread::Queue)

        blk.call(msg)
      end
    end
    [transport, ended, written]
  end

  def hooks_config
    { 'PreToolUse' => [{ matcher: 'Bash', hooks: [proc {}] }] }
  end

  def build_query(transport, **kwargs)
    described_class.new(transport: transport, is_streaming_mode: true, hooks: hooks_config, **kwargs)
  end

  def state(value, sdk_host_only: true)
    frame = { type: 'system', subtype: 'session_state_changed', state: value, session_id: 's' }
    frame[:sdk_host_only] = true if sdk_host_only
    frame
  end

  def result
    sample_result_message
  end

  def main_assistant
    { type: 'assistant', message: { role: 'assistant', content: [] }, parent_tool_use_id: nil }
  end

  def task_started(id)
    { type: 'system', subtype: 'task_started', task_id: id, task_type: 'local_agent' }
  end

  def task_done(id)
    { type: 'system', subtype: 'task_notification', task_id: id, status: 'completed' }
  end

  def user_message(content = 'hi')
    { type: 'user', message: { role: 'user', content: content }, session_id: '' }
  end

  # Runs +body+ with a started query whose read loop is fed from a queue, and
  # yields the query, `feed`, the end_input calls so far, the task and the
  # queue of written lines.
  #
  # `feed.call(*frames)` returns once the read loop is done with the frames
  # and what they woke has run. It enqueues a barrier behind them, which the
  # transport double only takes off the queue after the block for the frame
  # before it has returned — so every side effect of every frame is in place,
  # including the ones that suspend the read loop half-way (arming and
  # stopping the ceiling sleeper both yield). Being told that a frame was
  # dequeued would not be enough. Then every task that is ready gets a few
  # turns on the reactor: a task the frames woke (the stdin-closing waiter)
  # needs two to reach end_input, as it yields once if it has a ceiling
  # sleeper to stop; five is that with room to spare, and still no clock.
  #
  # `feed.call` with no frames is the same barrier with nothing in front of
  # it: it lets what the example itself made ready (a gate it opened, a
  # ceiling it fired) run.
  def with_query(**kwargs)
    queue = Async::Queue.new
    transport, ended, written = queue_fed_transport(queue)
    query = build_query(transport, **kwargs)
    Async do |task|
      query.start
      feed = lambda do |*frames|
        barrier = Thread::Queue.new
        [*frames, barrier].each { |frame| queue.enqueue(frame) }
        raise 'the read loop never got through the frames it was fed' unless barrier.pop(timeout: 10)

        5.times { task.yield }
      end
      yield query, feed, ended, task, written
    ensure
      query.close
      release_parked_tasks(task)
    end.wait
  end

  # Closing the query ends the run for good, which releases every task the
  # example left parked on it (a wait_for_result_and_end_input, a
  # stream_input). Bounded, and what is still parked is stopped: a task that
  # close did not release would keep this reactor alive forever, and the
  # example would hang the suite instead of failing.
  def release_parked_tasks(task)
    parked = []
    task.children&.each { |child| parked << child }
    task.with_timeout(10) { task.yield while parked.any?(&:alive?) }
  rescue Async::TimeoutError
    parked.each(&:stop)
    raise
  end

  # Waits for a task that is expected to finish now. The bound is what a
  # regression runs into; nothing healthy comes near it.
  def finish(task, awaited)
    task.with_timeout(10) { awaited.wait }
  end

  describe 'stdin stays open until idle' do
    it 'keeps stdin open past a result when a task settled just before it, and closes at idle (#1190)' do
      with_query do |query, feed, ended, task|
        waiter = task.async { query.wait_for_result_and_end_input }
        feed.call(state('running'), task_started('bg-1'), task_done('bg-1'), result)
        expect(ended).to be_empty # the settled agent still owes a follow-up turn

        feed.call(main_assistant, result) # the follow-up turn
        expect(ended).to be_empty

        feed.call(state('idle'))
        finish(task, waiter)
        expect(ended).not_to be_empty
      end
    end

    it 'drops only the frames marked sdk_host_only from the stream' do
      seen = []
      with_query do |query, feed, _ended, task|
        consumer = task.async { query.receive_messages { |m| seen << m } }
        feed.call(state('running'), state('running', sdk_host_only: false), result)
        consumer.stop
      end

      states = seen.select { |m| m[:subtype] == 'session_state_changed' }
      expect(states.length).to eq(1)
      expect(states.first).not_to have_key(:sdk_host_only)
      expect(seen.map { |m| m[:type] }).to include('result')
    end

    it 'drives the run end from unmarked frames too' do
      with_query do |query, feed, ended, task|
        waiter = task.async { query.wait_for_result_and_end_input }
        feed.call(state('running', sdk_host_only: false), result)
        expect(ended).to be_empty

        feed.call(state('idle', sdk_host_only: false))
        finish(task, waiter)
        expect(ended).not_to be_empty
      end
    end

    it 'closes stdin at the first result when the CLI sends no state (older CLIs)' do
      with_query do |query, feed, ended, task|
        waiter = task.async { query.wait_for_result_and_end_input }
        feed.call(result)
        finish(task, waiter)
        expect(ended).not_to be_empty
      end
    end

    it 'ends the run at a result that follows idle' do
      with_query do |query, feed, ended, task|
        waiter = task.async { query.wait_for_result_and_end_input }
        feed.call(state('running'), state('idle'))
        expect(ended).to be_empty # idle before any result does not end the run

        feed.call(result)
        finish(task, waiter)
        expect(ended).not_to be_empty
      end
    end

    it 'does not end the run at idle while a tracked task is in flight' do
      with_query do |query, feed, ended, task|
        waiter = task.async { query.wait_for_result_and_end_input }
        feed.call(state('running'), task_started('bg-1'), result, state('idle'))
        expect(ended).to be_empty

        feed.call(task_done('bg-1'), state('running'), main_assistant, result, state('idle'))
        finish(task, waiter)
        expect(ended).not_to be_empty
      end
    end

    it 'makes a single-message Enumerator prompt wait for idle' do
      with_query do |query, feed, ended, task|
        streamer = task.async { query.stream_input([user_message]) }
        feed.call(state('running'), result)
        expect(ended).to be_empty

        feed.call(state('idle'))
        finish(task, streamer)
        expect(ended).not_to be_empty
      end
    end

    it "makes the last streamed message wait for its own run, not an earlier one's" do
      gate = Async::Queue.new
      prompts = Enumerator.new do |y|
        y << user_message('one')
        gate.dequeue
        y << user_message('two')
      end

      with_query do |query, feed, ended, task, written|
        streamer = task.async { query.stream_input(prompts) }
        expect(written.pop(timeout: 10)).to include('one')
        feed.call(state('running'), result, state('idle')) # the first message's run ends
        gate.enqueue(:go)
        expect(written.pop(timeout: 10)).to include('two')
        feed.call # the stream is exhausted: the streamer now waits for message two's run
        expect(ended).to be_empty # which has not even started

        feed.call(state('running'), result, state('idle'))
        finish(task, streamer)
        expect(ended).not_to be_empty
      end
    end

    # The idle of the run that just ended can still be on its way when the
    # next message goes out. It belongs to the earlier run: the new message
    # owes a result of its own before an idle can end its run.
    it 'does not let a late idle of the previous run end the run of the next message' do
      gate = Async::Queue.new
      prompts = Enumerator.new do |y|
        y << user_message('one')
        gate.dequeue
        y << user_message('two')
      end

      with_query do |query, feed, ended, task, written|
        streamer = task.async { query.stream_input(prompts) }
        expect(written.pop(timeout: 10)).to include('one')
        feed.call(state('running'), result, state('idle')) # the first message's run ends
        gate.enqueue(:go)
        expect(written.pop(timeout: 10)).to include('two')
        feed.call(state('idle')) # a late duplicate, before message two produced anything
        expect(ended).to be_empty

        feed.call(state('running'), result, state('idle'))
        finish(task, streamer)
        expect(ended).not_to be_empty
      end
    end

    # A message is serialized before the run is reopened for it: one that
    # verbatim_prompts cannot mark raises there, and a run reopened for a
    # message that never went out would wait for a result nobody owes.
    it 'does not reopen the run for a message that fails to serialize' do
      gate = Async::Queue.new
      prompts = Enumerator.new do |y|
        y << user_message('one')
        gate.dequeue
        y << 'not a JSON object'
      end

      with_query(verbatim_prompts: true) do |query, feed, ended, task, written|
        allow(query).to receive(:warn) # stream_input logs the error and goes on to close stdin
        streamer = task.async { query.stream_input(prompts) }
        expect(written.pop(timeout: 10)).to include('one')
        feed.call(state('running'), result, state('idle')) # the first message's run ends
        expect(ended).to be_empty # the stream is still open

        gate.enqueue(:go)
        finish(task, streamer)
        expect(query.run_lifecycle.ended?).to be(true)
        expect(ended).not_to be_empty
      end
    end

    # Frame sequence observed from CLI 2.1.285 for three messages written
    # before any result: it merges queued messages into fewer turns (two
    # results here) and reports no idle until all queued input is served.
    it 'keeps stdin open across results for eagerly streamed messages until the final idle' do
      with_query do |query, feed, ended, task|
        streamer = task.async { query.stream_input([user_message('one'), user_message('two'), user_message('three')]) }
        feed.call(state('running'), result)
        expect(ended).to be_empty

        feed.call(result)
        expect(ended).to be_empty

        feed.call(state('idle'))
        finish(task, streamer)
        expect(ended).not_to be_empty
      end
    end

    %w[running requires_action].each do |wake|
      it "reopens an ended run for work the CLI takes up after idle (#{wake})" do
        gate = Async::Queue.new
        prompts = Enumerator.new do |y|
          y << user_message
          gate.dequeue
        end

        with_query do |query, feed, ended, task|
          streamer = task.async { query.stream_input(prompts) }
          feed.call(state('running'), result, state('idle')) # ended while the stream is still open
          feed.call(state(wake)) # a finished background task woke the CLI
          gate.enqueue(:go)
          feed.call # the stream is exhausted: the streamer waits for the reopened run
          expect(ended).to be_empty

          feed.call(state('running'), main_assistant, result, state('idle'))
          finish(task, streamer)
          expect(ended).not_to be_empty
        end
      end
    end
  end

  describe 'the mirror flush at a result' do
    # A result wakes whoever waits for the run's end and whoever reads the
    # stream, and both may go on to read the session store: the mirror is
    # flushed first. The flush suspends the read loop (a lock, a thread
    # join), so the order shows while it is parked.
    it 'ends the run and hands the result to the stream only once the mirror is flushed' do
      queue = Async::Queue.new
      transport, ended = queue_fed_transport(queue)
      query = build_query(transport)
      gate = Async::Queue.new
      flushes = 0
      batcher = instance_double(ClaudeAgentSDK::TranscriptMirrorBatcher, enqueue: nil, close: nil)
      allow(batcher).to receive(:flush) do
        flushes += 1
        gate.dequeue if flushes == 1 # the flush for the result; the one at the end of the read loop passes
      end
      query.set_transcript_mirror_batcher(batcher)
      seen = []

      Async do |task|
        query.start
        task.async { query.receive_messages { |message| seen << message[:type] } }
        waiter = task.async { query.wait_for_result_and_end_input }
        queue.enqueue(result) # from a CLI that sends no state: this result ends the run
        task.with_timeout(10) { task.yield until flushes == 1 }
        5.times { task.yield } # whatever the result could wake before the flush is done has run

        expect([seen, query.run_lifecycle.ended?, ended]).to eq([[], false, []])

        gate.enqueue(:flushed)
        finish(task, waiter)
        task.with_timeout(10) { task.yield until seen.any? }
        expect([seen, query.run_lifecycle.ended?, ended]).to eq([%w[result], true, [true]])
      ensure
        query.close
        release_parked_tasks(task)
      end.wait
    end
  end

  describe 'run-end ceiling' do
    # The ceiling is a sleeper that ends the run when its sleep is over. Which
    # sleeper is armed when, and what one that wakes may do, is tabled in
    # query/run_lifecycle_spec.rb. The two examples here that need one to wake
    # hand the Query a FakeSleeper (`sleeper:`), which never wakes by itself,
    # and wake it by hand; the others keep the real sleeper, a child of the
    # read task, and only the first sleeps through a real ceiling.
    let(:sleeper) { FakeSleeper.new }

    def ceiling_armed?(query)
      query.run_lifecycle.ceiling_armed?
    end

    # The sleep of the armed sleeper is over; +feed+ then lets what that woke
    # run.
    def ceiling_passes(feed)
      sleeper.fire
      feed.call
    end

    it 'ends the run when no idle arrives within the ceiling after a result' do
      with_query(run_end_ceiling_ms: 300) do |query, feed, ended, task|
        waiter = task.async { query.wait_for_result_and_end_input }
        feed.call(state('running'), result)

        # No idle follows: only the ceiling, a real one here, ends this run.
        finish(task, waiter)
        expect(ended).not_to be_empty
      end
    end

    it 'does not close stdin under a control request the SDK is still answering' do
      entered = Thread::Queue.new
      release = Thread::Queue.new
      parked_hook = lambda do |_input, _tool_use_id, _context|
        entered << true
        release.pop # on its worker thread, for as long as the example wants
        {}
      end
      hook_request = { type: 'control_request', request_id: 'req_1',
                       request: { subtype: 'hook_callback', callback_id: 'hook_0', tool_use_id: nil,
                                  input: { hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: {},
                                           session_id: 's', cwd: '/tmp' } } }

      with_query(sleeper: sleeper) do |query, feed, ended, task, written|
        query.instance_variable_set(:@hook_callbacks, { 'hook_0' => parked_hook })
        waiter = task.async { query.wait_for_result_and_end_input }
        feed.call(state('running'), result, hook_request)
        expect(entered.pop(timeout: 10)).to be(true)

        ceiling_passes(feed) # while the hook is still running
        expect(ended).to be_empty
        expect(ceiling_armed?(query)).to be(true) # the clock starts over instead

        release << true
        expect(written.pop(timeout: 10)).to include('req_1') # the reply went out,
        expect(ended).to be_empty # on a stdin that was still open
        feed.call

        ceiling_passes(feed)
        finish(task, waiter)
        expect(ended).not_to be_empty
      ensure
        release << true # never leave the worker thread parked
      end
    end

    it 'reopens a stream the ceiling ended for a main-thread turn' do
      gate = Async::Queue.new
      prompts = Enumerator.new do |y|
        y << user_message
        gate.dequeue
      end

      with_query(sleeper: sleeper) do |query, feed, ended, task|
        streamer = task.async { query.stream_input(prompts) }
        feed.call(state('running'), result)
        ceiling_passes(feed) # ends the run while the stream is still open
        feed.call(main_assistant)
        gate.enqueue(:go)
        feed.call # the stream is exhausted: the streamer waits for the reopened run
        expect(ended).to be_empty

        feed.call(result, state('idle'))
        finish(task, streamer)
        expect(ended).not_to be_empty
      end
    end

    it 'arms no ceiling once stdin is closed' do
      with_query do |query, feed, ended, task|
        waiter = task.async { query.wait_for_result_and_end_input }
        feed.call(state('running'), result, state('idle'))
        finish(task, waiter)
        expect(ended.length).to eq(1)

        feed.call(state('running'), main_assistant, result)
        expect(ceiling_armed?(query)).to be(false)
      end
    end

    # A frame the read loop already held when the Query was closed (a result
    # parked in the mirror flush) must not leave a sleeper behind: the
    # lifecycle asks the Query whether it is closed each time it would arm. A
    # closed Query reads no further frame, so the frames are handed to its
    # lifecycle directly; it was never started, so nothing but that answer
    # stands in the way (the run is neither ended nor final).
    it 'arms no ceiling once the Query is closed' do
      query = build_query(mock_transport, sleeper: sleeper)
      query.close

      [state('running'), result].each { |frame| query.run_lifecycle.frame(frame) }

      expect([query.run_lifecycle.ended?, query.run_lifecycle.final?, ceiling_armed?(query)]).to eq([false, false, false])
      expect(sleeper.arms).to be_empty
    end

    # A pending ceiling sleeper is a child task; if an exit path forgot to
    # clear it, the enclosing reactor would stay alive for the full ceiling.
    it 'leaves no sleeper behind when the CLI exits mid-wait' do
      queue = Async::Queue.new
      transport, ended = queue_fed_transport(queue)
      query = build_query(transport) # default 10-minute ceiling

      finished = Thread.new do
        Async do |task|
          query.start
          waiter = task.async { query.wait_for_result_and_end_input }
          [state('running'), result, :eof].each { |frame| queue.enqueue(frame) }
          waiter.wait
        end.wait
      end.join(30)

      expect(finished).to be_truthy
      expect(ended).not_to be_empty
    ensure
      query&.close
    end
  end

  describe '.run_end_ceiling_ms' do
    around do |example|
      previous = ENV.fetch('CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS', nil)
      ENV.delete('CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS')
      example.run
    ensure
      if previous
        ENV['CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS'] = previous
      else
        ENV.delete('CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS')
      end
    end

    {
      [{}, nil] => 600_000,
      [{}, '0'] => 0,
      [{}, '5000'] => 5000,
      [{ 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS' => '2000' }, '5000'] => 2000,
      [{ CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS: 3000 }, nil] => 3000,
      [{ 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS' => nil }, '5000'] => 600_000, # nil unsets it in the child
      [{}, 'soon'] => 600_000,
      [{}, '-1'] => 600_000,
      [{}, '1.5'] => 600_000,
      [{}, '1e6'] => 600_000, # the CLI reads this one; the SDK falls back, as Python does
      [{}, '1_000'] => 600_000,
      [{}, ' 42 '] => 42,
      [{}, ''] => 600_000
    }.each do |(options_env, ambient), expected|
      it "reads #{options_env.inspect} over ambient #{ambient.inspect} as #{expected}" do
        ENV['CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS'] = ambient if ambient

        expect(described_class.run_end_ceiling_ms(options_env)).to eq(expected)
      end
    end

    it 'is handed to the Query by query() and Client from options.env' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(env: { 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS' => '1234' })
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil,
                                                                          write: nil)
      query_handler = instance_double(described_class, start: true, initialize_protocol: nil,
                                                       wait_for_result_and_end_input: nil, close: nil)
      allow(query_handler).to receive(:receive_messages)
      allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      captured = []
      allow(described_class).to receive(:new) do |**kwargs|
        captured << kwargs[:run_end_ceiling_ms]
        query_handler
      end

      Async { ClaudeAgentSDK.query(prompt: 'hi', options: options) { |_m| nil } }.wait
      ClaudeAgentSDK::Client.new(options: options).connect

      expect(captured).to eq([1234, 1234])
    end
  end
end

RSpec.describe ClaudeAgentSDK::SubprocessCLITransport do
  # #connect registers the stubbed Process::Waiter in the process-wide
  # at-exit registry and these examples never #close: drop it here, so the
  # double does not outlive its example (see the suite-wide check in
  # spec_helper.rb).
  after { described_class.active_processes_mutex.synchronize { described_class.active_processes.clear } }

  def connect_and_capture_env(options)
    transport = described_class.new('hi', options)
    allow(transport).to receive(:check_claude_version)
    captured_env = nil
    stdin = instance_double(IO)
    allow(stdin).to receive(:close)
    allow(Open3).to receive(:popen3) do |env, *_args|
      captured_env = env
      [stdin, StringIO.new, StringIO.new, instance_double(Process::Waiter)]
    end
    connect_draining_stderr(transport)
    captured_env
  end

  around do |example|
    saved = %w[CLAUDE_CODE_SDK_READS_SESSION_STATE CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS
               claude_code_sdk_reads_session_state].to_h { |k| [k, ENV.fetch(k, nil)] }
    saved.each_key { |k| ENV.delete(k) }
    example.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  {
    'unset' => [{}, {}, '1'],
    'caller off' => [{ 'CLAUDE_CODE_SDK_READS_SESSION_STATE' => '0' }, {}, '0'],
    'caller Symbol key' => [{ CLAUDE_CODE_SDK_READS_SESSION_STATE: '0' }, {}, '0'],
    'caller nil unsets' => [{ 'CLAUDE_CODE_SDK_READS_SESSION_STATE' => nil }, {}, nil],
    'ambient off' => [{}, { 'CLAUDE_CODE_SDK_READS_SESSION_STATE' => '0' }, '0'],
    'caller other case' => [{ 'claude_code_sdk_reads_session_state' => '0' }, {}, nil]
  }.each do |name, (options_env, ambient, expected)|
    it "asks for sdk_host_only session state unless the caller chose (#{name})" do
      ambient.each { |k, v| ENV[k] = v }
      env = connect_and_capture_env(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude',
                                                                           env: options_env))

      expect(env['CLAUDE_CODE_SDK_READS_SESSION_STATE']).to eq(expected)
      expect(env).not_to have_key('CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS')
    end
  end
end
