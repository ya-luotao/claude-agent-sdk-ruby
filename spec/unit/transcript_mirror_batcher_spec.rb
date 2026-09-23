# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::TranscriptMirrorBatcher do
  let(:projects) { '/tmp/cas-mirror-base' }
  let(:key) { { 'project_key' => 'pk', 'session_id' => 'sid' } }
  let(:file_path) { "#{projects}/pk/sid.jsonl" }
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:errors) { [] }
  let(:on_error) { ->(k, m) { errors << [k, m] } }

  def batcher(**overrides)
    described_class.new(store: store, projects_dir: projects, on_error: on_error, **overrides)
  end

  it 'coalesces frames per file, normalizes to string keys, and preserves order on flush' do
    Async do
      b = batcher
      # Symbol-keyed entries, as the symbolize_names transport delivers them.
      b.enqueue(file_path, [{ type: 'user', uuid: 'a' }])
      b.enqueue(file_path, [{ type: 'assistant', uuid: 'b' }, { type: 'user', uuid: 'c' }])
      b.flush

      loaded = store.load(key)
      expect(loaded.map { |e| e['uuid'] }).to eq(%w[a b c])
      expect(loaded.first.keys).to eq(%w[type uuid]) # string keys, JSON-round-trip safe
    end
  end

  it 'skips empty entry batches without creating phantom keys' do
    Async do
      b = batcher
      b.enqueue(file_path, [])
      b.flush
      expect(store.load(key)).to be_nil
    end
  end

  it 'fully ignores an empty frame in eager mode (no phantom bytes or buffered item)' do
    Async do
      # Eager mode (zero thresholds): an empty frame must not accrue phantom
      # bytes/items that would schedule a no-op background drain every frame.
      b = batcher(max_pending_entries: 0, max_pending_bytes: 0)
      b.enqueue(file_path, [])
      expect(b.instance_variable_get(:@pending)).to be_empty
      expect(b.instance_variable_get(:@pending_bytes)).to eq(0)
      expect(b.instance_variable_get(:@pending_entries)).to eq(0)
    end
  end

  it 'drops (with a warning) frames whose file path is not under projects_dir, without appending or erroring' do
    Async do
      b = batcher
      expect do
        b.enqueue('/somewhere/else/x.jsonl', [{ 'type' => 'user' }])
        b.flush
      end.to output(/dropping mirror frame/).to_stderr
    end
    expect(store.size).to eq(0)
    expect(errors).to be_empty
  end

  # Issue #120: on a host with no usable home and no CLAUDE_CONFIG_DIR the
  # projects dir is unknown (SessionStores.projects_dir returns nil). The
  # session must keep running, and the lost mirror must not be silent.
  it 'reports frames it cannot key (no projects dir) via on_error and counts them as dropped' do
    b = nil
    Async do
      b = batcher(projects_dir: nil)
      expect do
        b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'a' }])
        b.flush
      end.to output(/CLAUDE_CONFIG_DIR/).to_stderr
    end
    expect(store.size).to eq(0)
    expect(errors.length).to eq(1)
    expect(errors.first[0]).to be_nil
    expect(errors.first[1]).to match(/home directory.*CLAUDE_CONFIG_DIR/m)
    expect(b.batches_dropped?).to be true
  end

  it 'retries a transient adapter failure and succeeds' do
    flaky = Class.new(ClaudeAgentSDK::SessionStore) do
      attr_reader :attempts

      def initialize
        super
        @attempts = 0
        @saved = nil
      end

      def append(_key, entries)
        @attempts += 1
        raise 'transient' if @attempts < 2

        @saved = entries
      end

      def load(_key) = @saved
    end.new

    Async do
      b = described_class.new(store: flaky, projects_dir: projects, on_error: on_error)
      b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'a' }])
      b.flush
    end
    expect(flaky.attempts).to eq(2)
    expect(errors).to be_empty
    expect(flaky.load(key).first['uuid']).to eq('a')
  end

  it 'reports via on_error after exhausting all attempts' do
    attempts = 0
    failing = Class.new(ClaudeAgentSDK::SessionStore) do
      define_method(:append) do |_key, _entries|
        attempts += 1
        raise 'always'
      end
      def load(_key) = nil
    end.new

    Async do
      b = described_class.new(store: failing, projects_dir: projects, on_error: on_error)
      expect do
        b.enqueue(file_path, [{ 'type' => 'user' }])
        b.flush
      end.to output(/flush failed/).to_stderr
    end
    expect(attempts).to eq(described_class::MIRROR_APPEND_MAX_ATTEMPTS)
    expect(errors.length).to eq(1)
    expect(errors.first[0]).to eq(key)
  end

  it 'does not retry on timeout and reports once' do
    attempts = 0
    slow = Class.new(ClaudeAgentSDK::SessionStore) do
      define_method(:append) do |_key, _entries|
        attempts += 1
        sleep(0.3)
      end
      def load(_key) = nil
    end.new

    Async do
      b = described_class.new(store: slow, projects_dir: projects, on_error: on_error, send_timeout: 0.05)
      b.enqueue(file_path, [{ 'type' => 'user' }])
      b.flush
    end
    expect(attempts).to eq(1) # timeout -> not retried
    expect(errors.length).to eq(1)
    expect(errors.first[1]).to match(/timed out/)
  end

  it 'eager mode flushes in the background after each frame (thresholds zeroed)' do
    Async do
      b = batcher(max_pending_entries: 0, max_pending_bytes: 0)
      b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'x' }])
      Async::Task.current.sleep(0.05) # allow the detached drain to complete
      expect((store.load(key) || []).length).to eq(1)
    end
  end

  it 'preserves append order with no loss or duplication across concurrent eager drains' do
    # Latency-injecting store: append sleeps on its (batcher-spawned) worker
    # thread, so a drain is in flight — holding the semaphore — while later
    # frames enqueue and schedule their own drains. This exercises the
    # detach-before-lock + Async::Semaphore(1) ordering guarantee under genuine
    # concurrency (the sole reason that machinery exists).
    slow_store = Class.new(ClaudeAgentSDK::SessionStore) do
      def initialize
        super
        @entries = []
      end

      attr_reader :entries

      def append(_key, entries)
        sleep(0.002) # plain sleep: runs on the worker thread; thread.join yields the reactor
        @entries.concat(entries)
      end

      def load(_key) = @entries.dup
    end.new

    n = 30
    Async do
      b = described_class.new(store: slow_store, projects_dir: projects, on_error: on_error,
                              max_pending_entries: 0, max_pending_bytes: 0) # eager
      n.times do |i|
        b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => "u#{i}" }])
        Async::Task.current.sleep(0.001) if i.even? # interleave background drains
      end
      b.close
    end

    uuids = slow_store.entries.map { |e| e['uuid'] }
    expect(uuids).to eq(Array.new(n) { |i| "u#{i}" }) # in enqueue order, no dup, no loss
    expect(errors).to be_empty
  end

  # Issue #84: every eager frame used to spawn its own drain task, each
  # detaching its batch before queueing on the lock — a store slower than the
  # frame rate piled up tasks + detached batches without bound. Now at most one
  # background drainer is live; frames arriving while it is busy stay in the
  # pending buffer and are coalesced into its next append.
  describe 'backpressure against a store slower than the frame rate' do
    # Gated store: each append announces itself on `started`, then parks its
    # (batcher-spawned) worker thread on `gate` until the test releases it.
    let(:gated_store) do
      Class.new(ClaudeAgentSDK::SessionStore) do
        attr_reader :entries, :calls, :max_concurrent, :started, :gate

        def initialize
          super
          @entries = []
          @calls = 0
          @live = 0
          @max_concurrent = 0
          @mutex = Mutex.new
          @started = Thread::Queue.new
          @gate = Thread::Queue.new
        end

        def append(_key, entries)
          @mutex.synchronize do
            @calls += 1
            @live += 1
            @max_concurrent = [@max_concurrent, @live].max
          end
          @started.push(true)
          @gate.pop # nil once the gate is closed
          @mutex.synchronize { @entries.concat(entries) }
        ensure
          @mutex.synchronize { @live -= 1 }
        end

        def load(_key) = @mutex.synchronize { @entries.dup }
      end.new
    end

    it 'keeps one drain in flight, coalesces the backlog, and loses nothing on close (eager)' do
      n = 50
      live_drains = 0
      max_live_drains = 0
      max_live_during_ingest = nil
      pending_during_ingest = nil

      Async do |task|
        task.with_timeout(10) do
          b = described_class.new(store: gated_store, projects_dir: projects, on_error: on_error,
                                  max_pending_entries: 0, max_pending_bytes: 0) # eager
          allow(b).to receive(:drain).and_wrap_original do |original|
            live_drains += 1
            max_live_drains = [max_live_drains, live_drains].max
            original.call
          ensure
            live_drains -= 1
          end

          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'u0' }])
          gated_store.started.pop # append #1 is parked on the gate
          # The read loop keeps ingesting while the store is stuck: enqueue
          # must return without suspending and without spawning a drain.
          (1...n).each { |i| b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => "u#{i}" }]) }
          max_live_during_ingest = max_live_drains
          pending_during_ingest = b.instance_variable_get(:@pending).length

          gated_store.gate.close # release append #1 and every later one
          b.close
        end
      end

      expect(max_live_during_ingest).to eq(1) # unfixed: one parked drain per frame
      expect(pending_during_ingest).to eq(n - 1) # backlog buffered, not detached
      expect(gated_store.max_concurrent).to eq(1)
      expect(gated_store.calls).to be <= 3 # u0, then the coalesced backlog
      expect(gated_store.entries.map { |e| e['uuid'] }).to eq(Array.new(n) { |i| "u#{i}" })
      expect(errors).to be_empty
    end

    it 'close flushes frames buffered behind an in-flight background append' do
      Async do |task|
        task.with_timeout(10) do
          b = described_class.new(store: gated_store, projects_dir: projects, on_error: on_error,
                                  max_pending_entries: 0, max_pending_bytes: 0) # eager
          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'a' }])
          gated_store.started.pop # background append parked on the gate
          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'b' }])
          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'c' }])

          closer = task.async { b.close } # barrier: parks behind the in-flight append
          gated_store.gate.close
          closer.wait
          expect(b.instance_variable_get(:@pending)).to be_empty
        end
      end

      expect(gated_store.entries.map { |e| e['uuid'] }).to eq(%w[a b c])
      expect(gated_store.max_concurrent).to eq(1)
      expect(errors).to be_empty
    end

    # The looping drainer re-detaches after its append completes. A #flush
    # barrier that detached OLDER frames is already parked on the lock by
    # then, and Semaphore#release hands the lock straight to it (FIFO), so the
    # drainer's NEWER frames must land after the barrier's — not ahead of it.
    it 'appends a parked flush barrier batch before frames the drainer picks up later' do
      Async do |task|
        task.with_timeout(10) do
          b = described_class.new(store: gated_store, projects_dir: projects, on_error: on_error,
                                  max_pending_entries: 0, max_pending_bytes: 0) # eager
          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'a' }])
          gated_store.started.pop # drainer's append of `a` parked on the gate
          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'b' }])
          flusher = task.async { b.flush } # detaches `b`, parks on the lock
          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'c' }]) # buffered for the drainer

          gated_store.gate.close
          flusher.wait
          b.flush # barrier covering the drainer's `c` iteration
        end
      end

      expect(gated_store.entries.map { |e| e['uuid'] }).to eq(%w[a b c])
      expect(gated_store.max_concurrent).to eq(1)
      expect(errors).to be_empty
    end

    # Teardown corner: Query#close runs batcher.close, then stops the read
    # task (the drainer's parent). A frame the read loop enqueued during the
    # close window sits in @pending (the live drainer would have taken it
    # next), so stopping the read task first loses it — and that loss must
    # surface through batches_dropped?, as the old per-frame parked drain's
    # cancellation did, so resume-from-store teardown preserves the temp dir.
    it 'counts a frame buffered during close as dropped when the read task is stopped first' do
      b = nil
      pending_at_stop = nil
      Async do |task|
        task.with_timeout(10) do
          b = described_class.new(store: gated_store, projects_dir: projects, on_error: on_error,
                                  max_pending_entries: 0, max_pending_bytes: 0) # eager
          resume_reader = Thread::Queue.new
          reader_enqueued = Thread::Queue.new
          reader = task.async do # stands in for Query's read task (drainer's parent)
            b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'a' }])
            resume_reader.pop
            b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'late' }])
            reader_enqueued.push(true)
            resume_reader.pop # parked until stopped
          end
          gated_store.started.pop # drainer's append of `a` parked on the gate

          closer = task.async do # Query#close order: batcher close, then @task.stop
            b.close
            pending_at_stop = b.instance_variable_get(:@pending).length
            reader.stop
          end
          resume_reader.push(true)
          reader_enqueued.pop # `late` buffered behind the live drainer, close parked
          gated_store.gate.close
          closer.wait
        end
      end

      expect(pending_at_stop).to eq(1) # the corner was reached: `late` never detached
      expect(gated_store.entries.map { |e| e['uuid'] }).to eq(%w[a])
      expect(b.batches_dropped?).to be(true)
    end

    it 'does not report a drop when frames buffered during close are drained before teardown ends' do
      b = nil
      Async do |task|
        task.with_timeout(10) do
          b = described_class.new(store: gated_store, projects_dir: projects, on_error: on_error,
                                  max_pending_entries: 0, max_pending_bytes: 0) # eager
          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'a' }])
          gated_store.started.pop
          closer = task.async { b.close }
          b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'late' }]) # during the close window
          gated_store.gate.close
          closer.wait
          b.flush # the still-live drainer (not stopped here) delivers `late`
        end
      end

      expect(gated_store.entries.map { |e| e['uuid'] }).to eq(%w[a late])
      expect(b.batches_dropped?).to be(false)
    end
  end

  it 'close performs a final flush and never raises' do
    Async do
      b = batcher
      b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'z' }])
      expect { b.close }.not_to raise_error
      expect(store.load(key).first['uuid']).to eq('z')
    end
  end

  # M4 regression: errors must be reported before the drain releases the lock.
  # flush/close are barriers — the read loop enqueues its 'end' sentinel right
  # after the end-of-stream flush returns, so an error reported by a still-
  # unwinding background drain landed after 'end' and was never delivered.
  it 'reports on_error before a concurrent flush barrier returns' do
    slow = Class.new(ClaudeAgentSDK::SessionStore) do
      # Exceeds send_timeout -> abandoned + reported as a timeout error.
      def append(_key, _entries) = sleep(0.2)
      def load(_key) = nil
    end.new

    errors_at_barrier = nil
    Async do
      b = described_class.new(store: slow, projects_dir: projects, on_error: on_error,
                              send_timeout: 0.05, max_pending_entries: 0, max_pending_bytes: 0)
      expect do
        b.enqueue(file_path, [{ 'type' => 'user' }]) # schedules a background eager drain
        Async::Task.current.sleep(0.01) # let it start: it holds the lock, append in flight
        b.flush # barrier: must not return before the drain's error is reported
        errors_at_barrier = errors.length
      end.to output(/flush failed/).to_stderr
    end
    expect(errors_at_barrier).to eq(1)
  end

  describe '#batches_dropped?' do
    it 'is false initially and stays false across successful flushes' do
      Async do
        b = batcher
        expect(b.batches_dropped?).to be(false)
        b.enqueue(file_path, [{ 'type' => 'user' }])
        b.flush
        expect(b.batches_dropped?).to be(false)
      end
    end

    it 'turns true after a batch exhausts all attempts' do
      failing = Class.new(ClaudeAgentSDK::SessionStore) do
        def append(_key, _entries) = raise('always')
        def load(_key) = nil
      end.new

      b = nil
      Async do
        b = described_class.new(store: failing, projects_dir: projects, on_error: on_error)
        expect do
          b.enqueue(file_path, [{ 'type' => 'user' }])
          b.flush
        end.to output(/flush failed/).to_stderr
      end
      expect(b.batches_dropped?).to be(true)
    end

    it 'turns true when a frame path cannot be keyed under projects_dir' do
      Async do
        b = batcher
        expect do
          b.enqueue('/somewhere/else/x.jsonl', [{ 'type' => 'user' }])
          b.flush
        end.to output(/dropping mirror frame/).to_stderr
        expect(b.batches_dropped?).to be(true)
      end
    end

    it 'counts a drain cancelled mid-append as dropped (Async::Stop bypasses the rescues)' do
      # Teardown reads batches_dropped? to decide whether the materialized
      # resume dir holds the only copy of some turns; a cancelled flush loses
      # its detached items, so it must count as a drop.
      slow = Class.new(ClaudeAgentSDK::SessionStore) do
        # Long plain sleep on the batcher's worker thread; the drain fiber
        # parks in the thread join, where stop can reach it.
        def append(_key, _entries) = sleep(3)
        def load(_key) = nil
      end.new

      b = nil
      Async do |task|
        b = described_class.new(store: slow, projects_dir: projects, on_error: on_error, send_timeout: 10)
        drainer = task.async do
          b.enqueue(file_path, [{ 'type' => 'user' }])
          b.flush
        end
        task.sleep(0.05) # flush is now parked inside the append join
        drainer.stop
      end
      expect(b.batches_dropped?).to be(true)
    end
  end
end
