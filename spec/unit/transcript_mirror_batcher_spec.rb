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
