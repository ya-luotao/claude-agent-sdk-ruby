# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'support/booted_app'

# What an SDK callback sees of the request (or job) that runs the agent, and
# the recipe docs/rails.md gives for carrying that state into callbacks.
#
# Callbacks run on a thread or fiber Rails never set up, so whatever Rails
# keeps per execution — Current attributes, Time.zone, log tags, the error
# context — reads as its default there, with or without the Railtie wrapper.
# docs/rails.md ("Request state does not follow into callbacks") says so and
# prints a wrapper that captures the state on the caller and restores it in
# each callback; the child process evaluates that block verbatim.
#
# Observed in a booted application (support/booted_app.rb), one child process
# per configuration: production and development (code reloading, where the
# Railtie wrapper stays out of the executor), default :thread scheduling
# under both isolation levels, and :inline under fiber isolation, its
# documented precondition. ActiveRecord's role / shard / prevent_writes are
# not covered here: the Rails gemfiles carry no ActiveRecord.
RSpec.describe 'Request state inside SDK callbacks' do
  callbacks = %w[message_block observer hook can_use_tool tool]
  caller_state = { 'user' => 'alice', 'time_zone' => 'Tokyo', 'log_tags' => ['req-123'],
                   'error_context' => { 'request_id' => 'req-123' }, 'locale' => 'de' }
  # The locale is left out: what a callback gets by itself depends on i18n.
  rails_defaults = { 'user' => nil, 'time_zone' => 'UTC', 'log_tags' => [], 'error_context' => {} }

  # What the SDK answered the CLI with: the hook's output, the permission
  # result and the tool's result, in the order the CLI asked.
  let(:answers) do
    tool_result = include('content' => [{ 'type' => 'text', 'text' => 'found' }])
    [
      { 'subtype' => 'success', 'response' => {} },
      { 'subtype' => 'success', 'response' => { 'behavior' => 'allow', 'updatedInput' => { 'id' => 7 } } },
      { 'subtype' => 'success', 'response' => { 'mcp_response' => include('result' => tool_result) } }
    ]
  end

  def booted_app(reloading:, isolation:)
    ClaudeAgentSDKRailsSpec::BootedApp.observe(reloading: reloading, isolation: isolation)
  end

  { 'production' => false, 'development (code reloading)' => true }.each do |environment, reloading|
    [%i[thread thread], %i[fiber inline], %i[fiber thread]].each do |isolation, scheduling|
      { 'ClaudeAgentSDK.query' => 'query', 'Client.open' => 'client' }.each do |entry_point, api|
        context "in #{environment}, #{isolation} isolation, callback_scheduling: :#{scheduling}, #{entry_point}" do
          let(:observed) { booted_app(reloading: reloading, isolation: isolation) }
          let(:with_railtie_wrapper) { observed.fetch("#{api}/#{scheduling}/railtie") }
          let(:with_recipe) { observed.fetch("#{api}/#{scheduling}/recipe") }
          # Only a Client's message block and observers run on the fiber
          # that called the SDK, and only under :inline scheduling.
          let(:on_caller_fiber) { scheduling == :inline && api == 'client' ? %w[message_block observer] : [] }

          # The callback ran once, saw this state, on the caller's fiber or not.
          def once_with(state, kind)
            contain_exactly(include(state.merge('on_caller_fiber' => on_caller_fiber.include?(kind))))
          end

          it 'boots the application it describes' do
            expect(observed).to include('reloading' => reloading, 'isolation' => isolation.to_s,
                                        'logger' => 'ActiveSupport::BroadcastLogger')
            expect(with_railtie_wrapper.fetch('caller')).to contain_exactly(
              include(caller_state.merge('on_caller_fiber' => true))
            )
          end

          it 'shows Rails defaults to every callback off the caller fiber, with Railtie.callback_wrapper alone' do
            callbacks.each do |kind|
              state = on_caller_fiber.include?(kind) ? caller_state : rails_defaults
              expect(with_railtie_wrapper.fetch(kind)).to once_with(state, kind), "in #{kind}"
            end
          end

          it 'hands I18n.locale down to every callback by itself when i18n keeps it in fiber storage (1.15+)' do
            i18n = observed.fetch('i18n')
            skip "i18n #{i18n} keeps the locale per thread or fiber" if Gem::Version.new(i18n) < Gem::Version.new('1.15')

            callbacks.each do |kind|
              expect(with_railtie_wrapper.fetch(kind)).to contain_exactly(include('locale' => 'de')), "in #{kind}"
            end
          end

          it 'shows the caller state to every callback, once, with the documented recipe' do
            expect(with_recipe).not_to include('error')
            callbacks.each do |kind|
              expect(with_recipe.fetch(kind)).to once_with(caller_state, kind), "in #{kind}"
            end
          end

          it "hands the callbacks' return values back unchanged through the documented recipe" do
            expect(with_railtie_wrapper.fetch('answers')).to match(answers)
            expect(with_recipe.fetch('answers')).to match(answers)
          end
        end
      end
    end
  end

  # The capture must happen per call: a wrapper is fixed for the lifetime of
  # the session it was passed to.
  describe 'a recipe wrapper built by one request and still in use during another (a long-lived Client)' do
    let(:turns) { booted_app(reloading: false, isolation: :thread).fetch('reused wrapper').fetch('turns') }
    let(:later_request) { turns.last }

    it 'shows the callbacks of the later request the state of the first one' do
      expect(later_request.fetch('caller')).to contain_exactly(
        include('user' => 'bob', 'time_zone' => 'Berlin', 'log_tags' => ['req-456'],
                'error_context' => { 'request_id' => 'req-456' }, 'locale' => 'fr')
      )
      callbacks.each do |kind|
        expect(later_request.fetch(kind)).to contain_exactly(include(caller_state)), "in #{kind}"
      end
    end
  end

  # Rails.logger.tagged { } on a broadcast runs its block once per tagged
  # logger; the recipe pushes and pops the tags instead.
  describe 'the documented recipe with two tagged loggers in the Rails.logger broadcast' do
    [%i[thread thread], %i[fiber inline]].each do |isolation, scheduling|
      context "under callback_scheduling: :#{scheduling}" do
        let(:observed) { booted_app(reloading: false, isolation: isolation).fetch('two tagged loggers') }

        it 'runs every callback once and hands its return value back' do
          expect(observed).not_to include('error')
          callbacks.each do |kind|
            expect(observed.fetch(kind)).to contain_exactly(include(caller_state)), "in #{kind}"
          end
          expect(observed.fetch('answers')).to match(answers)
        end

        it 'tags the lines callbacks log on both loggers, once' do
          expect(observed.fetch('logs').size).to eq(2)
          expect(observed.fetch('logs')).to all(
            match_array(['caller', *callbacks].map { |kind| "[req-123] seen by #{kind}" })
          )
        end
      end
    end
  end
end
