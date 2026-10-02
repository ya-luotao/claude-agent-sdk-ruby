# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'support/booted_app'

# Combining a wrapper of your own with Railtie.callback_wrapper: which side
# of `rails.call` your code is on decides what the callback sees.
#
# In production the Rails wrapper enters the executor, whose run hooks start
# every execution from a clean slate (Rails resets CurrentAttributes and the
# error context there). In development it stays out of the executor. So a
# wrapper that sets state around `rails.call` works in development and loses
# Current and the error context in production only — while Time.zone and log
# tags, which the executor does not reset, survive in both. docs/rails.md
# ("Writing your own wrapper") states the rule; these examples pin it against
# the hooks a booted application of each Rails version really registers.
RSpec.describe 'Composing a wrapper with ClaudeAgentSDK::Railtie.callback_wrapper' do
  callbacks = %w[message_block observer hook can_use_tool tool]
  everything = { 'user' => 'alice', 'time_zone' => 'Tokyo', 'log_tags' => ['req-123'],
                 'error_context' => { 'request_id' => 'req-123' } }
  # What the executor's run hooks reset, and what they leave alone.
  after_executor_reset = everything.merge('user' => nil, 'error_context' => {})

  def seen_with(composition, reloading:)
    observed = ClaudeAgentSDKRailsSpec::BootedApp.observe(reloading: reloading, isolation: :thread)
    observed.fetch("query/thread/state set #{composition} the Rails wrapper")
  end

  context 'in production (the Rails wrapper enters the executor)' do
    it 'keeps state set inside rails.call' do
      seen = seen_with('inside', reloading: false)

      callbacks.each { |kind| expect(seen.fetch(kind)).to contain_exactly(include(everything)), "in #{kind}" }
    end

    it 'resets Current and the error context set around rails.call, and nothing else' do
      seen = seen_with('outside', reloading: false)

      callbacks.each do |kind|
        expect(seen.fetch(kind)).to contain_exactly(include(after_executor_reset)), "in #{kind}"
      end
    end
  end

  context 'in development (code reloading: the Rails wrapper stays out of the executor)' do
    it 'keeps state set inside rails.call' do
      seen = seen_with('inside', reloading: true)

      callbacks.each { |kind| expect(seen.fetch(kind)).to contain_exactly(include(everything)), "in #{kind}" }
    end

    it 'keeps state set around rails.call too, which is what hides the production loss' do
      seen = seen_with('outside', reloading: true)

      callbacks.each { |kind| expect(seen.fetch(kind)).to contain_exactly(include(everything)), "in #{kind}" }
    end
  end
end
