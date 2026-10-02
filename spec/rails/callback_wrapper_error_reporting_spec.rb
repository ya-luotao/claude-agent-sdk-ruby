# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'support/scripted_cli_transport'

# What Rails.error — the reporter Sentry, Honeybadger, AppSignal and Solid
# Errors subscribe to — receives when SDK callbacks go through the wrapper's
# executor branch (production: no reloading, concurrency allowed).
#
# `executor.wrap` reports what passes through it as an unhandled error (a
# StandardError on Rails 7.1, any Exception on current releases). Around an
# SDK callback that is wrong twice: the SDK handles most callback failures
# itself (a hook or tool error becomes an error response, an observer error
# is swallowed, a cancellation is control flow), and the one that does escape
# was reported from a thread with none of the caller's context, after which
# Rails skips it at the request / job layer as already reported. So the
# wrapper enters the executor without reporting.
RSpec.describe 'ClaudeAgentSDK::Railtie.callback_wrapper and Rails.error' do
  let(:app) { Rails.application }
  let(:wrapper) { ClaudeAgentSDK::Railtie.callback_wrapper }
  # A fresh executor per example, so hooks registered here never leak.
  let(:executor) { Class.new(ActiveSupport::Executor) }
  let(:error) { Class.new(StandardError).new('boom') }
  # A Rails.error subscriber; reports arrive on callback threads.
  let(:subscriber) do
    Class.new do
      attr_reader :reports

      def initialize
        @reports = Thread::Queue.new
      end

      def report(error, handled:, context:, source: nil, **)
        @reports << { error: error, handled: handled, source: source, context: context }
      end
    end.new
  end

  around do |example|
    config = app.config
    saved = [config.enable_reloading, config.allow_concurrency]
    config.enable_reloading = false
    config.allow_concurrency = nil
    Rails.error.subscribe(subscriber)
    example.run
  ensure
    Rails.error.unsubscribe(subscriber)
    ActiveSupport::ExecutionContext.clear
    config.enable_reloading, config.allow_concurrency = saved
  end

  before { allow(app).to receive(:executor).and_return(executor) }

  def drain(queue)
    Array.new(queue.size) { queue.pop }
  end

  def reported
    drain(subscriber.reports)
  end

  # The FiberBoundary hop in :thread scheduling: the callback runs on a thread
  # of its own, and what it raises is raised again on the caller.
  def call_on_thread(invocation)
    Thread.new do
      Thread.current.report_on_exception = false
      wrapper.call(invocation)
    end.value
  end

  # The caller: a job (a request likewise) runs inside the executor, sets its
  # context, and reports what escapes it under its own source.
  def as_a_job
    executor.wrap(source: 'application.active_job') do
      Rails.error.set_context(job: 'ChatAgentJob')
      yield
    end
  end

  def caller_report
    include(error: error, handled: false, source: 'application.active_job', context: include(job: 'ChatAgentJob'))
  end

  describe 'an exception from a wrapped callback' do
    it 'propagates unchanged and is not reported by the wrapper' do
      expect { call_on_thread(-> { raise error }) }.to raise_error(equal(error))

      expect(reported).to be_empty
    end

    it "is left to the caller's reporter, which has the caller's context" do
      expect { as_a_job { call_on_thread(-> { raise error }) } }.to raise_error(equal(error))

      expect(reported).to contain_exactly(caller_report)
    end

    it 'is not reported when it is a cancellation (hook timeout or CLI cancel under :inline scheduling)' do
      [Async::Stop, Class.new(ClaudeAgentSDK::FiberBoundary::InlineCancellation)].each do |cancellation|
        expect { call_on_thread(-> { raise cancellation }) }.to raise_error(cancellation)
      end

      expect(reported).to be_empty
    end
  end

  describe 'the executor around a wrapped callback' do
    let(:events) { Thread::Queue.new }

    before do
      queue = events # the hook blocks are instance_exec'd on the executor
      executor.to_run { queue << :run }
      executor.to_complete { queue << :complete }
    end

    it 'runs its run and complete hooks once each' do
      result = call_on_thread(lambda {
        events << :callback
        :result
      })

      expect(result).to eq(:result)
      expect(drain(events)).to eq(%i[run callback complete])
    end

    it 'runs them once each when the callback raises' do
      callback = lambda {
        events << :callback
        raise error
      }

      expect { call_on_thread(callback) }.to raise_error(equal(error))
      expect(drain(events)).to eq(%i[run callback complete])
    end
  end

  describe 'over a whole query' do
    let(:frames) { ClaudeAgentSDKRailsSpec::Frames }

    def run_query(turn, **options, &block)
      transport = ClaudeAgentSDKRailsSpec::ScriptedCLITransport.new(turns: [turn])
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_wrapper: wrapper, **options)
      ClaudeAgentSDK.query(prompt: 'hi', options: options, transport: transport, &block || proc {})
      transport
    end

    it "leaves a message-block exception to the caller's reporter, with the caller's context" do
      expect do
        as_a_job do
          run_query(frames.text_turn) { |message| raise error if message.is_a?(ClaudeAgentSDK::ResultMessage) }
        end
      end.to raise_error(equal(error))

      expect(reported).to contain_exactly(caller_report)
    end

    it 'reports nothing when an observer raises: the SDK swallows it' do
      observer = Class.new do
        include ClaudeAgentSDK::Observer

        def on_message(_message)
          raise 'observer boom'
        end
      end.new

      run_query(frames.text_turn, observers: [observer])

      expect(reported).to be_empty
    end

    it 'reports nothing when a hook raises: the SDK answers the CLI with an error response' do
      hook = ->(_input, _tool_use_id, _context) { raise 'hook boom' }
      hooks = { 'PreToolUse' => [ClaudeAgentSDK::HookMatcher.new(hooks: [hook])] }

      transport = run_query(frames.tool_turn(ask: [:hook]), hooks: hooks)

      expect(transport.control_responses.values).to contain_exactly(include(subtype: 'error', error: 'hook boom'))
      expect(reported).to be_empty
    end

    it 'reports nothing when an SDK MCP tool raises: the model gets an error result' do
      tool = ClaudeAgentSDK.create_tool('lookup', 'Look up a record', { id: Integer }) { |_args| raise 'tool boom' }
      server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'app', tools: [tool])

      transport = run_query(frames.tool_turn(ask: [:tool]), mcp_servers: { 'app' => server })

      expect(transport.control_responses.values).to contain_exactly(
        include(subtype: 'success', response: include(mcp_response: include(result: include(isError: true))))
      )
      expect(reported).to be_empty
    end
  end
end
