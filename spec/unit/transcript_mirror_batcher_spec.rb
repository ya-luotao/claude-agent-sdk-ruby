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
end
