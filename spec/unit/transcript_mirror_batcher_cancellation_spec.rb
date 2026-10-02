# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'async/condition'

# A drain takes the pending buffer only once it holds the lock. It used to
# detach first and then queue for the lock, so a #flush cancelled while it
# waited behind an in-flight append (a task stopped, a timeout around the
# caller) took its batch down with it: counted by #batches_dropped?, but never
# appended and never reported through on_error (upstream Python PR #1289).
#
# Every interleaving below is forced with a gate the example controls — a
# Thread::Queue for the default thread-hop store, an Async::Condition for a
# fiber-native one. Nothing waits on a clock.
RSpec.describe ClaudeAgentSDK::TranscriptMirrorBatcher do
  let(:projects) { '/cfg/projects' }
  let(:file_path) { "#{projects}/-Users-dev-app/11111111-1111-4111-8111-111111111111.jsonl" }
  let(:errors) { [] }
  let(:on_error) { ->(key, message) { errors << [key, message] } }

  # Each append announces itself on `started`, then parks its (batcher-spawned)
  # worker thread on `gate` until the example closes it.
  let(:gated_store) do
    Class.new(ClaudeAgentSDK::SessionStore) do
      attr_reader :started, :gate

      def initialize
        super
        @entries = []
        @mutex = Mutex.new
        @started = Thread::Queue.new
        @gate = Thread::Queue.new
      end

      def append(_key, entries)
        @started.push(true)
        @gate.pop # nil once the gate is closed
        @mutex.synchronize { @entries.concat(entries) }
      end

      def load(_key) = @mutex.synchronize { @entries.dup }
      def uuids = load(nil).map { |entry| entry['uuid'] }
    end.new
  end

  # Fiber-native adapter: #append runs in place on the reactor and parks on a
  # condition until the example releases it.
  let(:inline_store) do
    Class.new(ClaudeAgentSDK::SessionStore) do
      attr_reader :uuids

      def initialize
        super
        @uuids = []
        @entered = false
        @released = false
        @gate = Async::Condition.new
      end

      def callback_scheduling = :inline
      def entered? = @entered
      def load(_key) = nil

      def append(_key, entries)
        @entered = true
        @gate.wait until @released
        @uuids.concat(entries.map { |entry| entry['uuid'] })
      end

      def release!
        @released = true
        @gate.signal
      end
    end.new
  end

  def batcher(store)
    described_class.new(store: store, projects_dir: projects, on_error: on_error)
  end

  # A frame as the transport delivers it: symbol keys.
  def frame(uuid)
    [{ type: 'user', uuid: uuid, message: { role: 'user', content: uuid } }]
  end

  it 'keeps the batch of a flush cancelled while it waits behind an in-flight append' do
    b = batcher(gated_store)
    Async do |task|
      task.with_timeout(30) do
        b.enqueue(file_path, frame('one'))
        first = task.async { b.flush } # holds the lock; its append is parked on the gate
        gated_store.started.pop
        b.enqueue(file_path, frame('two'))
        waiter = task.async { b.flush } # queued on the lock behind `first`
        waiter.stop # ... and cancelled there
        b.enqueue(file_path, frame('three'))

        gated_store.gate.close
        first.wait
        b.close
      end
    end.wait

    expect(gated_store.uuids).to eq(%w[one two three])
    expect(b.batches_dropped?).to be(false)
    expect(errors).to be_empty
  end

  it 'keeps it for a fiber-native (inline) store too' do
    b = batcher(inline_store)
    Async do |task|
      task.with_timeout(30) do
        b.enqueue(file_path, frame('one'))
        first = task.async { b.flush } # in place on the reactor, parked on the condition
        expect(inline_store).to be_entered
        b.enqueue(file_path, frame('two'))
        waiter = task.async { b.flush }
        waiter.stop
        b.enqueue(file_path, frame('three'))

        inline_store.release!
        first.wait
        b.close
      end
    end.wait

    expect(inline_store.uuids).to eq(%w[one two three])
    expect(b.batches_dropped?).to be(false)
    expect(errors).to be_empty
  end

  # What a drain HAS detached is still lost with it, and counted: the
  # materialized resume dir then holds the only copy and must be kept.
  it 'still counts a batch as dropped when its drain is cancelled inside the append' do
    b = batcher(gated_store)
    Async do |task|
      task.with_timeout(30) do
        b.enqueue(file_path, frame('one'))
        flusher = task.async { b.flush }
        gated_store.started.pop # the append is in flight: `one` is detached
        flusher.stop
        gated_store.gate.close
      end
    end.wait

    expect(b.batches_dropped?).to be(true)
  end

  # #close does not chase frames that arrive after it detached. With nothing
  # left to drain them they stay buffered, and that counts as a drop.
  it 'counts a frame that arrives during the final append as dropped when nothing drains it' do
    b = batcher(gated_store)
    Async do |task|
      task.with_timeout(30) do
        b.enqueue(file_path, frame('a'))
        closer = task.async { b.close } # detaches `a` under the lock; its append is parked on the gate
        gated_store.started.pop
        b.enqueue(file_path, frame('late')) # below the thresholds: no drain is scheduled for it
        gated_store.gate.close
        closer.wait
      end
    end.wait

    expect(gated_store.uuids).to eq(%w[a])
    expect(b.batches_dropped?).to be(true)
  end
end
