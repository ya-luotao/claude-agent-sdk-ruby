# frozen_string_literal: true

# The run-end ceiling's timer, without a clock. Query::RunLifecycle takes a
# sleeper — `sleeper.call(seconds) { ... }`, returning a handle that responds
# to #stop — and this one never wakes by itself: it keeps every arm, and the
# example decides which one wakes and when.
#
#   sleeper = FakeSleeper.new
#   query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true, sleeper: sleeper)
#   ...
#   sleeper.fire        # the sleep of the arm that is pending is over
#   sleeper.fire_stale  # an arm that was stopped or replaced wakes anyway: it was already waking up
#
# What the lifecycle believes is read from the lifecycle (#ceiling_armed?);
# what it did to its sleeper is read here (#arms, #stops, #pending_arms).
# A lifecycle that keeps track of its sleeper has at most one arm pending,
# the one it holds: an earlier arm it replaced without stopping stays in
# #pending_arms, where an example can see it, and makes #fire refuse.
class FakeSleeper
  # One call of the sleeper: the handle the lifecycle holds.
  class Arm
    attr_reader :seconds

    def initialize(sleeper, seconds, on_wake)
      @sleeper = sleeper
      @seconds = seconds
      @on_wake = on_wake
      @stopped = false
      @woken = false
    end

    def stop
      @stopped = true
      @sleeper.stopped
    end

    # Neither stopped nor woken: the sleep is still running.
    def pending?
      !@stopped && !@woken
    end

    def wake
      @woken = true
      @on_wake.call
    end
  end

  # Every arm so far, oldest first, and how many times a handle was stopped.
  attr_reader :arms, :stops

  # Called inside every Arm#stop, for an example that needs to see the state a
  # stop finds (a real stop hands the reactor to whatever else is ready).
  attr_accessor :on_stop

  def initialize
    @arms = []
    @stops = 0
    @on_stop = nil
  end

  def call(seconds, &on_wake)
    arm = Arm.new(self, seconds, on_wake)
    @arms << arm
    arm
  end

  def stopped
    @stops += 1
    @on_stop&.call
  end

  # Every arm that is still sleeping, oldest first: one at most, unless a
  # sleeper was replaced without being stopped.
  def pending_arms
    @arms.select(&:pending?)
  end

  # Some arm is still sleeping.
  def armed?
    !pending_arms.empty?
  end

  # The pending arm's sleep is over.
  def fire
    pending = pending_arms
    raise "FakeSleeper#fire: #{pending.length} arms are pending, not one" unless pending.length == 1

    pending.first.wake
  end

  # The latest arm that is no longer pending (stopped, or already woken)
  # wakes: the sleeper it stood for was past its sleep when it was stopped or
  # replaced, and still runs its block.
  def fire_stale
    arm = @arms.reject(&:pending?).last
    raise 'FakeSleeper#fire_stale: every arm is still pending' unless arm

    arm.wake
  end
end
