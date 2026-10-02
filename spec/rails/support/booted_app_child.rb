# frozen_string_literal: true

# Runs in a child process started by booted_app.rb: boots a real Rails
# application, plays requests that run an agent against a scripted CLI, and
# prints what every kind of SDK callback saw of the request's state.
#
#   RAILS_ENV             production, or development (code reloading enabled)
#   BOOTED_APP_ISOLATION  thread | fiber
#
# Plain Ruby, no RSpec: the parent asserts on the JSON printed at the end.
require 'rails'
require 'claude_agent_sdk' # after Rails, as Bundler.require does: this loads the Railtie
require 'json'
require 'stringio'
require 'tmpdir'
require_relative 'scripted_cli_transport'

# What an application has in app/models/current.rb.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
end

module ClaudeAgentSDKRailsSpec
  LOG = StringIO.new

  class BootedApplication < Rails::Application
    config.root = Dir.mktmpdir('claude_agent_sdk_booted_app')
    config.load_defaults "#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}"
    config.eager_load = false
    config.enable_reloading = Rails.env.development?
    config.secret_key_base = 'booted-app-child'
    config.i18n.available_locales = %i[en de fr]
    # A tagged logger, as generated production.rb files set up. Rails wraps
    # it in an ActiveSupport::BroadcastLogger at boot.
    config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(LOG))
    # docs/rails.md, "Fiber workers": what a fiber-isolated host sets.
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber if ENV['BOOTED_APP_ISOLATION'] == 'fiber'
  end

  # The recipe as printed in docs/rails.md: the first Ruby block after MARKER
  # is evaluated verbatim, so the guide cannot drift from what runs here.
  module DocumentedRecipe
    GUIDE = File.expand_path('../../../docs/rails.md', __dir__)
    MARKER = '<!-- spec/rails/request_state_spec.rb runs the next code block verbatim -->'

    # @return [String, nil] why the recipe could not be loaded
    def self.load
      before, marker, after = File.read(GUIDE).partition(MARKER)
      code = after[/^```ruby\n(.*?)^```$/m, 1]
      return "docs/rails.md has no Ruby block after #{MARKER}" if marker.empty? || code.nil?

      prelude = before + marker + after[/\A.*?^```ruby\n/m]
      TOPLEVEL_BINDING.eval(code, GUIDE, prelude.count("\n") + 1)
      nil
    end
  end

  # What callbacks saw, by kind of callback, in the order they ran.
  class Recorder
    include ClaudeAgentSDK::Observer

    def initialize
      @lock = Mutex.new
      @turns = [Hash.new { |seen, kind| seen[kind] = [] }]
    end

    # The request that is calling the SDK: observations are relative to it.
    def caller!
      @caller_fiber = Fiber.current
      record('caller')
    end

    def next_turn!
      @lock.synchronize { @turns << Hash.new { |seen, kind| seen[kind] = [] } }
    end

    def record(kind)
      Rails.logger.info("seen by #{kind}")
      snapshot = {
        'user' => Current.user,
        'time_zone' => Time.zone.name,
        'log_tags' => Rails.logger.formatter.current_tags.dup,
        'error_context' => ActiveSupport::ExecutionContext.to_h,
        'locale' => I18n.locale.to_s,
        'on_caller_fiber' => Fiber.current.equal?(@caller_fiber)
      }
      @lock.synchronize { @turns.last[kind] << snapshot }
    end

    # Observer and message block see every message; one observation each is
    # enough, and the result is the one every turn has.
    def on_message(message)
      record('observer') if message.is_a?(ClaudeAgentSDK::ResultMessage)
    end

    def message_block
      ->(message) { record('message_block') if message.is_a?(ClaudeAgentSDK::ResultMessage) }
    end

    def turns
      @lock.synchronize { @turns.map(&:dup) }
    end
  end

  # Requests (or jobs) that run an agent. Each one runs inside the executor
  # with the state a controller or job would have set, and its agent turn
  # fires every kind of SDK callback: PreToolUse hook, can_use_tool, an SDK
  # MCP tool, an observer and the message block.
  class Requests
    ALICE = { user: 'alice', zone: 'Tokyo', request_id: 'req-123', locale: :de }.freeze
    BOB = { user: 'bob', zone: 'Berlin', request_id: 'req-456', locale: :fr }.freeze

    def initialize(recipe_error)
      @recipe_error = recipe_error
      # Fiber-isolated hosts (solid_queue fiber workers, Falcon) run a request
      # or job as a task on a reactor; thread-isolated ones on a plain thread.
      @reactor = ActiveSupport::IsolatedExecutionState.isolation_level == :fiber
    end

    # One request, one agent run.
    def run(api:, scheduling:, wrapper:)
      return { 'error' => @recipe_error } if wrapper == 'recipe' && @recipe_error

      recorder = Recorder.new
      responses = {}
      in_executor do
        with_request_state(**ALICE) do
          recorder.caller!
          options = options_for(recorder, scheduling: scheduling, wrapper: wrapper_named(wrapper))
          run_agent(api, options, recorder, responses)
        end
      end
      recorder.turns.first.merge('answers' => answers(responses))
    end

    # A wrapper of the application's own that sets request state itself,
    # composed with the Rails wrapper from the outside or from the inside
    # (docs/rails.md, "Writing your own wrapper"). The caller sets nothing.
    def run_composing(side)
      rails = ClaudeAgentSDK::Railtie.callback_wrapper
      state = ->(invocation) { with_request_state(**ALICE) { invocation.call } }
      wrapper = if side == 'outside'
                  ->(invocation) { state.call(-> { rails.call(invocation) }) }
                else
                  ->(invocation) { rails.call(-> { state.call(invocation) }) }
                end
      recorder = Recorder.new
      in_executor do
        run_agent('query', options_for(recorder, scheduling: :thread, wrapper: wrapper), recorder, {})
      end
      recorder.turns.first
    end

    # One Client connected by a first request, with a wrapper built there,
    # and used again by a second request with different state.
    def run_reusing_a_wrapper
      return { 'error' => @recipe_error } if @recipe_error

      recorder = Recorder.new
      Sync do
        client = nil
        in_this_executor(**ALICE) do
          recorder.caller!
          options = options_for(recorder, scheduling: :thread, wrapper: wrapper_named('recipe'))
          client = ClaudeAgentSDK::Client.new(options: options, transport_class: ScriptedCLITransport,
                                              transport_args: { turns: [Frames.tool_turn, Frames.tool_turn] })
          client.connect
          take_turn(client, recorder)
        end
        recorder.next_turn!
        in_this_executor(**BOB) do
          recorder.caller!
          take_turn(client, recorder)
        end
      ensure
        client&.disconnect
      end
      { 'turns' => recorder.turns }
    end

    # The same request with a second tagged logger in Rails.logger's broadcast.
    def run_with_two_tagged_loggers(scheduling:)
      second_log = StringIO.new
      second = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(second_log))
      Rails.logger.broadcast_to(second)
      LOG.rewind
      LOG.truncate(0)
      seen = run(api: 'query', scheduling: scheduling, wrapper: 'recipe')
      seen.merge('logs' => [LOG.string, second_log.string].map { |log| log.lines(chomp: true) })
    ensure
      Rails.logger.stop_broadcasting_to(second)
    end

    private

    def in_executor(&)
      return Rails.application.executor.wrap(&) unless @reactor

      Async { Rails.application.executor.wrap(&) }.wait
    end

    def in_this_executor(**state, &block)
      Rails.application.executor.wrap { with_request_state(**state, &block) }
    end

    # What a controller's callbacks (or a job) set before calling the SDK.
    # The executor resets Current and the error context when the request ends.
    def with_request_state(user:, zone:, request_id:, locale:, &)
      Current.user = user
      Rails.error.set_context(request_id: request_id)
      Rails.logger.push_tags(request_id) # as Rails::Rack::Logger tags a request
      I18n.with_locale(locale) { Time.use_zone(zone, &) }
    ensure
      Rails.logger.pop_tags
    end

    def wrapper_named(name)
      case name
      when 'railtie' then ClaudeAgentSDK::Railtie.callback_wrapper # what the generated initializer configures
      when 'recipe' then AgentContext.callback_wrapper # docs/rails.md: built per call, on the caller
      else raise ArgumentError, "unknown wrapper #{name}"
      end
    end

    def options_for(recorder, scheduling:, wrapper:)
      hook = lambda do |_input, _tool_use_id, _context|
        recorder.record('hook')
        {}
      end
      can_use_tool = lambda do |_tool_name, _input, _context|
        recorder.record('can_use_tool')
        ClaudeAgentSDK::PermissionResultAllow.new
      end
      tool = ClaudeAgentSDK.create_tool('lookup', 'Look up a record', { id: Integer }) do |_args|
        recorder.record('tool')
        { content: [{ type: 'text', text: 'found' }] }
      end
      ClaudeAgentSDK::ClaudeAgentOptions.new(
        hooks: { 'PreToolUse' => [ClaudeAgentSDK::HookMatcher.new(hooks: [hook])] },
        can_use_tool: can_use_tool,
        mcp_servers: { 'app' => ClaudeAgentSDK.create_sdk_mcp_server(name: 'app', tools: [tool]) },
        observers: [recorder], callback_scheduling: scheduling.to_sym, callback_wrapper: wrapper
      )
    end

    def run_agent(api, options, recorder, responses)
      transport_args = { turns: [Frames.tool_turn], control_responses: responses }
      if api == 'client'
        ClaudeAgentSDK::Client.open(options: options, transport_class: ScriptedCLITransport,
                                    transport_args: transport_args) { |client| take_turn(client, recorder) }
      else
        ClaudeAgentSDK.query(prompt: 'Look up record 7', options: options,
                             transport: ScriptedCLITransport.new(**transport_args), &recorder.message_block)
      end
    end

    def take_turn(client, recorder)
      client.query('Look up record 7')
      client.receive_response(&recorder.message_block)
    end

    # What the SDK answered the CLI's hook, permission and tool requests with
    # — the callbacks' return values, as they came back through the wrapper.
    def answers(responses)
      responses.values.map { |response| response.slice(:subtype, :response, :error) }
    end
  end
end

Rails.application.initialize!

requests = ClaudeAgentSDKRailsSpec::Requests.new(ClaudeAgentSDKRailsSpec::DocumentedRecipe.load)
isolation = ActiveSupport::IsolatedExecutionState.isolation_level
# :inline needs fiber isolation (the SDK warns otherwise); :thread works under both.
schedulings = isolation == :fiber ? %w[inline thread] : %w[thread]

observed = {
  'rails' => Rails.version, 'reloading' => Rails.application.config.reloading_enabled?,
  'isolation' => isolation.to_s, 'logger' => Rails.logger.class.name
}
%w[query client].product(schedulings, %w[railtie recipe]).each do |api, scheduling, wrapper|
  observed["#{api}/#{scheduling}/#{wrapper}"] = requests.run(api: api, scheduling: scheduling, wrapper: wrapper)
end
%w[outside inside].each do |side|
  observed["query/thread/state set #{side} the Rails wrapper"] = requests.run_composing(side)
end
observed['reused wrapper'] = requests.run_reusing_a_wrapper
observed['two tagged loggers'] = requests.run_with_two_tagged_loggers(scheduling: schedulings.first)

puts "BOOTED_APP_RESULT #{JSON.generate(observed)}"
FileUtils.rm_rf(Rails.root.to_s)
