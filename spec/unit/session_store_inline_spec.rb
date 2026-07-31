# frozen_string_literal: true

require 'spec_helper'
require 'claude_agent_sdk/testing/session_store_conformance'

# Fiber-native SessionStore adapters (issue #47 phase 3): an adapter may
# declare `callback_scheduling -> :inline`, and its timeout-bounded
# #append/#load calls then run in place on the reactor under a COOPERATIVE
# timeout instead of on a throwaway thread with a hard Thread#join bound.
# Undeclared adapters keep the thread hop byte-for-byte; the outward
# JoinTimeout contract is identical either way.
RSpec.describe 'Fiber-native SessionStore adapters' do
  let(:projects) { '/tmp/cas-inline-base' }
  let(:key) { { 'project_key' => 'pk', 'session_id' => 'sid' } }
  let(:file_path) { "#{projects}/pk/sid.jsonl" }
  let(:errors) { [] }
  let(:on_error) { ->(k, m) { errors << [k, m] } }

  # An InMemory-backed adapter declaring itself fiber-native, with probes
  # capturing the execution context of each append.
  def inline_store_class(&append_body)
    Class.new(ClaudeAgentSDK::InMemorySessionStore) do
      def callback_scheduling = :inline

      define_method(:append) do |k, entries|
        append_body ? append_body.call(k, entries) : super(k, entries)
      end
    end
  end

  # A CONFORMING fiber-native adapter: :inline declarers must dedupe by
  # entry uuid (contract 17b) because inline timeouts are retried with
  # full-batch re-sends.
  def deduping_inline_store_class
    Class.new(ClaudeAgentSDK::InMemorySessionStore) do
      def callback_scheduling = :inline

      def append(key, entries)
        seen = Array(load(key)).filter_map { |e| e['uuid'] }
        fresh = Array(entries).reject { |e| e['uuid'] && seen.include?(e['uuid']) }
        super(key, fresh)
      end
    end
  end

  describe 'FiberBoundary.invoke with timeout + scheduling: :inline' do
    it 'runs in place on the calling fiber with the scheduler live inside a reactor' do
      inner_fiber = nil
      inner_scheduler = :unset
      outer_fiber = nil
      result = nil

      Async do
        outer_fiber = Fiber.current
        result = ClaudeAgentSDK::FiberBoundary.invoke(timeout: 5, scheduling: :inline) do
          inner_fiber = Fiber.current
          inner_scheduler = Fiber.scheduler
          :done
        end
      end.wait

      expect(result).to eq(:done)
      expect(inner_fiber).to be(outer_fiber)
      expect(inner_scheduler).not_to be_nil
    end

    it 'cancels a slow call cooperatively: JoinTimeout, ensure runs, call never completes' do
      ensure_ran = false
      completed = false

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        Async do
          ClaudeAgentSDK::FiberBoundary.invoke(timeout: 0.05, scheduling: :inline) do
            sleep 5 # scheduler-aware: parks the fiber, cancellable
            completed = true
          ensure
            ensure_ran = true
          end
        end.wait
      end.to raise_error(ClaudeAgentSDK::FiberBoundary::JoinTimeout, /timed out after 0.05s/)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 2
      expect(ensure_ran).to be(true)
      expect(completed).to be(false)
    end

    it 'cannot be defeated by a rescue StandardError inside the call' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        Async do
          ClaudeAgentSDK::FiberBoundary.invoke(timeout: 0.05, scheduling: :inline) do
            begin
              sleep 5
            rescue StandardError
              # swallow-everything adapter; must NOT convert the expired
              # deadline into a success (InlineCancellation is not a
              # StandardError, so this rescue never sees it)
            end
            :swallowed
          end
        end.wait
      end.to raise_error(ClaudeAgentSDK::FiberBoundary::JoinTimeout)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    # Regression (codex review): the inline branch used to rescue the SHARED
    # InlineCancellation base, so an OUTER timeout's cancellation delivered
    # while the store call was suspended (nested with_timeout — e.g. a store
    # call inside a timed inline hook) was consumed by the inner rescue,
    # mis-attributed to the inner deadline, and the outer deadline was lost.
    # Each timeout scope now uses a fresh per-invocation subclass and only
    # consumes its own.
    it 'lets an outer timeout cancellation pass through an inner inline store timeout scope' do
      outer_cancel = Class.new(ClaudeAgentSDK::FiberBoundary::InlineCancellation)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect do
        Async do |task|
          task.with_timeout(0.05, outer_cancel) do
            ClaudeAgentSDK::FiberBoundary.invoke(timeout: 5, scheduling: :inline) do
              sleep 10
            end
          end
        end.wait
      end.to raise_error(outer_cancel)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    it 'still attributes an inner timeout correctly under a longer outer scope' do
      outer_cancel = Class.new(ClaudeAgentSDK::FiberBoundary::InlineCancellation)

      expect do
        Async do |task|
          task.with_timeout(5, outer_cancel) do
            ClaudeAgentSDK::FiberBoundary.invoke(timeout: 0.05, scheduling: :inline) do
              sleep 10
            end
          end
        end.wait
      end.to raise_error(ClaudeAgentSDK::FiberBoundary::JoinTimeout, /timed out after 0.05s/)
    end

    it 'falls back to the hard thread-hop bound outside a reactor even with scheduling: :inline' do
      inner_thread = nil
      inner_scheduler = :unset

      expect do
        ClaudeAgentSDK::FiberBoundary.invoke(timeout: 0.05, scheduling: :inline) do
          inner_thread = Thread.current
          inner_scheduler = Fiber.scheduler
          sleep 1 # plain sleep on the worker thread; join(0.05) abandons it
        end
      end.to raise_error(ClaudeAgentSDK::FiberBoundary::JoinTimeout, /timed out after 0.05s/)

      expect(inner_thread).not_to be(Thread.current)
      expect(inner_scheduler).to be_nil
    end
  end

  describe 'SessionStores.store_callback_scheduling' do
    it 'defaults to :thread for adapters that do not declare' do
      expect(ClaudeAgentSDK::SessionStores.store_callback_scheduling(ClaudeAgentSDK::InMemorySessionStore.new))
        .to eq(:thread)
    end

    it 'returns the declared mode, coercing the String form' do
      inline = ClaudeAgentSDK::InMemorySessionStore.new
      def inline.callback_scheduling = :inline
      expect(ClaudeAgentSDK::SessionStores.store_callback_scheduling(inline)).to eq(:inline)

      stringy = ClaudeAgentSDK::InMemorySessionStore.new
      def stringy.callback_scheduling = 'inline'
      expect(ClaudeAgentSDK::SessionStores.store_callback_scheduling(stringy)).to eq(:inline)
    end

    it 'raises ArgumentError for invalid declarations' do
      bad = ClaudeAgentSDK::InMemorySessionStore.new
      def bad.callback_scheduling = :fiber
      expect { ClaudeAgentSDK::SessionStores.store_callback_scheduling(bad) }
        .to raise_error(ArgumentError, /callback_scheduling must return one of/)
    end
  end

  describe 'TranscriptMirrorBatcher with an inline-declared store' do
    it 'runs append on the calling fiber with the scheduler live' do
      captured = {}
      store = inline_store_class do |_k, _entries|
        captured[:fiber] = Fiber.current
        captured[:scheduler] = Fiber.scheduler
      end.new

      Async do
        b = ClaudeAgentSDK::TranscriptMirrorBatcher.new(store: store, projects_dir: projects, on_error: on_error)
        b.enqueue(file_path, [{ 'type' => 'user' }])
        captured[:flush_fiber] = Fiber.current
        b.flush
      end.wait

      expect(captured[:scheduler]).not_to be_nil
      expect(captured[:fiber]).to be(captured[:flush_fiber])
      expect(errors).to be_empty
    end

    # Unlike thread mode (where a timed-out append is abandoned in flight
    # and must not be retried), an inline cancellation is DEFINITE — so the
    # timeout is retried like any other failure, up to the attempt cap.
    it 'retries a cooperative timeout and reports through the existing error path when all attempts expire' do
      attempts = 0
      ensure_ran = false
      store = inline_store_class do |_k, _entries|
        attempts += 1
        begin
          sleep(0.3) # scheduler-aware: cancellable at this suspension point
        ensure
          ensure_ran = true
        end
      end.new

      b = nil
      Async do
        b = ClaudeAgentSDK::TranscriptMirrorBatcher.new(store: store, projects_dir: projects,
                                                        on_error: on_error, send_timeout: 0.05)
        expect do
          b.enqueue(file_path, [{ 'type' => 'user' }])
          b.flush
        end.to output(/flush failed/).to_stderr
      end.wait

      expect(attempts).to eq(ClaudeAgentSDK::TranscriptMirrorBatcher::MIRROR_APPEND_MAX_ATTEMPTS)
      expect(ensure_ran).to be(true)
      expect(errors.length).to eq(1)
      expect(errors.first[1]).to match(/timed out/)
      expect(b.batches_dropped?).to be(true)
    end

    # The retry is what heals a half-applied cancelled append: the full
    # batch is re-sent and uuid dedupe absorbs the overlap.
    it 'heals a half-applied cancelled append on the retry without duplicating entries' do
      attempts = 0
      store = deduping_inline_store_class.new
      underlying_append = store.method(:append)
      store.define_singleton_method(:append) do |k, entries|
        attempts += 1
        if attempts == 1
          # First attempt: persist only the first entry, then park until
          # the cooperative timeout cancels us mid-batch.
          underlying_append.call(k, entries.take(1))
          sleep(5)
        else
          underlying_append.call(k, entries)
        end
      end

      Async do
        b = ClaudeAgentSDK::TranscriptMirrorBatcher.new(store: store, projects_dir: projects,
                                                        on_error: on_error, send_timeout: 0.05)
        b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'u1' }, { 'type' => 'assistant', 'uuid' => 'u2' }])
        b.flush
      end.wait

      expect(attempts).to eq(2)
      expect(errors).to be_empty
      # Exact equality, not include: the retry re-sends the full batch, and
      # the mandatory-for-inline uuid dedupe must absorb the overlap — a
      # duplicated u1 here is the silent-corruption case the contract
      # forbids.
      expect(store.load(key).map { |e| e['uuid'] }).to eq(%w[u1 u2])
    end

    it 'keeps an undeclared store on a scheduler-free worker thread' do
      captured = {}
      store = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        define_method(:append) do |k, entries|
          captured[:thread] = Thread.current
          captured[:scheduler] = Fiber.scheduler
          super(k, entries)
        end
      end.new

      main_thread = Thread.current
      Async do
        b = ClaudeAgentSDK::TranscriptMirrorBatcher.new(store: store, projects_dir: projects, on_error: on_error)
        b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => 'a' }])
        b.flush
      end.wait

      expect(captured[:scheduler]).to be_nil
      expect(captured[:thread]).not_to be(main_thread)
      expect(store.load(key).first['uuid']).to eq('a')
    end

    it 'rejects an invalid callback_scheduling declaration at construction' do
      bad = ClaudeAgentSDK::InMemorySessionStore.new
      def bad.callback_scheduling = :bogus

      expect do
        ClaudeAgentSDK::TranscriptMirrorBatcher.new(store: bad, projects_dir: projects, on_error: on_error)
      end.to raise_error(ArgumentError, /callback_scheduling must return one of/)
    end
  end

  describe 'SessionResume materialization with an inline-declared store' do
    def resume_entry(text)
      { 'type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => text } }
    end

    it 'runs store loads on the calling fiber with the scheduler live' do
      captured = {}
      sid = SecureRandom.uuid
      cwd = Dir.mktmpdir
      store = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def callback_scheduling = :inline

        define_method(:load) do |k|
          captured[:scheduler] = Fiber.scheduler
          captured[:thread] = Thread.current
          super(k)
        end
      end.new
      project_key = ClaudeAgentSDK.project_key_for_directory(cwd)
      store.append({ 'project_key' => project_key, 'session_id' => sid }, [resume_entry('hi')])

      mat = nil
      begin
        Async do
          mat = ClaudeAgentSDK::SessionResume.materialize_resume_session(
            ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: cwd)
          )
        end.wait

        expect(captured[:scheduler]).not_to be_nil
        expect(captured[:thread]).to be(Thread.current)
        expect(mat).not_to be_nil
      ensure
        mat&.cleanup
        FileUtils.remove_entry(cwd) if File.directory?(cwd)
      end
    end

    it 'rejects an invalid declaration at materialization entry, before any store IO' do
      loads = 0
      cwd = Dir.mktmpdir
      store = ClaudeAgentSDK::InMemorySessionStore.new
      def store.callback_scheduling = 42
      store.define_singleton_method(:load) { |_k| loads += 1 }

      begin
        expect do
          ClaudeAgentSDK::SessionResume.materialize_resume_session(
            ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: SecureRandom.uuid, cwd: cwd)
          )
        end.to raise_error(ArgumentError, /callback_scheduling must return one of/)
        expect(loads).to eq(0)
      ensure
        FileUtils.remove_entry(cwd) if File.directory?(cwd)
      end
    end
  end

  describe 'conformance kit contract 17' do
    it 'passes for a deduping declaring adapter and for a non-declaring adapter' do
      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { deduping_inline_store_class.new })
      end.not_to raise_error
      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { ClaudeAgentSDK::InMemorySessionStore.new })
      end.not_to raise_error
    end

    # Contract 17b: uuid dedupe is MANDATORY for :inline declarers (inline
    # timeouts are retried with full-batch re-sends — a non-deduping inline
    # adapter silently duplicates the landed part of a half-applied append),
    # while staying advisory/opt-in for thread-mode adapters.
    it 'fails a non-deduping :inline declarer on the dedupe contract' do
      non_deduping = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def callback_scheduling = :inline
      end
      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { non_deduping.new })
      end.to raise_error(ClaudeAgentSDK::Testing::ConformanceError, /dedupe by entry uuid/)
    end

    it 'fails for a bad declarer' do
      bad = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def callback_scheduling = :sometimes
      end
      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { bad.new })
      end.to raise_error(ClaudeAgentSDK::Testing::ConformanceError, /callback_scheduling declaration/)
    end

    it 'reports a RAISING declarer through ConformanceError, not the raw exception' do
      exploding = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def callback_scheduling
          raise 'declaration exploded'
        end
      end
      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { exploding.new })
      end.to raise_error(ClaudeAgentSDK::Testing::ConformanceError, /declaration raised RuntimeError: declaration exploded/)
    end
  end
end
