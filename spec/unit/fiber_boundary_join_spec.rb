# frozen_string_literal: true

require 'spec_helper'
require 'async'

# FiberBoundary.invoke waits for its worker thread with Thread#join. Under a
# fiber scheduler, join parks the fiber, and MRI treats ANY wakeup that finds
# the thread still alive as "timed out": join returns nil (and Thread#value
# then returns nil too) although nothing has finished. Such a wakeup does not
# have to belong to this join. When a hop's thread ends it queues a wakeup
# for the waiting fiber; if an exception (Async::Stop, a deadline) is raised
# into the fiber before that wakeup is consumed, the wakeup stays queued and
# resumes whatever the fiber waits on next — the next hop.
#
# So only "the thread has finished" or "the deadline has really passed" may
# end the wait.
RSpec.describe ClaudeAgentSDK::FiberBoundary, 'waiting for the worker thread' do
  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Runs the given hop on a fiber that has a stale wakeup queued for it. The
  # hop gets two queues: it must push to +started+ from its worker and then
  # block that worker on +release+.pop. Returns whether the hop was over
  # before its worker was released, and what it returned or raised.
  #
  # No clock is involved: every step waits on a queue or on thread state.
  def hop_after_stale_wakeup # rubocop:disable Metrics/AbcSize -- one linear interleaving, annotated step by step
    first_started = Thread::Queue.new
    first_release = Thread::Queue.new
    started = Thread::Queue.new
    release = Thread::Queue.new
    outcome = Thread::Queue.new

    Sync do |root|
      child = root.async do
        ClaudeAgentSDK.offload do
          first_started << Thread.current
          first_release.pop
        end
      ensure
        # The second hop of the same fiber, entered while the first hop's
        # wakeup is still queued.
        outcome << begin
          yield started, release
        rescue StandardError => e
          e
        end
      end

      first_thread = root.with_timeout(10) { first_started.pop }
      first_release << true
      # The first worker ends and queues the wakeup for the child's fiber.
      # This fiber keeps the reactor thread meanwhile, so the child is not
      # resumed yet.
      Thread.pass while first_thread.alive?
      stopper = root.async { child.stop } # Async::Stop into the not-yet-resumed fiber: it unwinds into the ensure
      root.with_timeout(10) { started.pop } # the second worker is running, and blocked
      3.times { root.yield } # the stale wakeup, queued before all of this, has had its turn

      over_before_release = !outcome.empty?
      release << true
      stopper.wait
      [over_before_release, root.with_timeout(10) { outcome.pop }]
    end
  end

  it 'does not return from an unbounded hop (ClaudeAgentSDK.offload) while its block is still running' do
    over_before_release, result = hop_after_stale_wakeup do |started, release|
      ClaudeAgentSDK.offload do
        started << true
        release.pop
        :finished
      end
    end

    aggregate_failures do
      expect(over_before_release).to be(false)
      expect(result).to eq(:finished)
    end
  end

  it 'does not report a timeout for a bounded hop whose deadline has not passed' do
    over_before_release, result = hop_after_stale_wakeup do |started, release|
      described_class.invoke(timeout: 60) do
        started << true
        release.pop
        :finished
      end
    end

    aggregate_failures do
      expect(over_before_release).to be(false)
      expect(result).to eq(:finished)
    end
  end

  describe 'a deadline that really passes' do
    let(:release) { Thread::Queue.new }

    after { release.close } # the abandoned worker's pop returns and its thread ends

    # The worker outlives the deadline by a wide margin but not forever: on a
    # Ruby whose Thread#join(limit) cannot expire under a scheduler (3.2.0)
    # the example then fails after that margin instead of hanging the suite.
    def outlive_the_deadline
      release.pop(timeout: 5)
    end

    it 'raises JoinTimeout inside a reactor, and not before the deadline' do
      started = monotonic

      expect do
        Sync { described_class.invoke(timeout: 0.05) { outlive_the_deadline } }
      end.to raise_error(described_class::JoinTimeout, 'timed out after 0.05s')
      expect(monotonic - started).to be > 0.049
    end

    it 'raises JoinTimeout outside a reactor, and not before the deadline' do
      started = monotonic

      expect do
        described_class.invoke(timeout: 0.05) { outlive_the_deadline }
      end.to raise_error(described_class::JoinTimeout, 'timed out after 0.05s')
      expect(monotonic - started).to be > 0.049
    end
  end

  it 'returns the value of a bounded hop that finishes in time' do
    expect(Sync { described_class.invoke(timeout: 60) { :in_time } }).to eq(:in_time)
    expect(described_class.invoke(timeout: 60) { :in_time }).to eq(:in_time)
  end
end
