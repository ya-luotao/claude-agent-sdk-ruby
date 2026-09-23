# frozen_string_literal: true

require_relative 'rails_helper'

RSpec.describe 'ClaudeAgentSDK::Railtie.callback_wrapper' do
  let(:app) { Rails.application }
  let(:wrapper) { ClaudeAgentSDK::Railtie.callback_wrapper }
  # A fresh executor per example, so lock hooks registered here never leak.
  let(:executor) { Class.new(ActiveSupport::Executor) }
  let(:connection_handler) { double('connection_handler', clear_active_connections!: nil) }

  around do |example|
    config = app.config
    saved = [config.enable_reloading, config.allow_concurrency]
    example.run
  ensure
    config.enable_reloading, config.allow_concurrency = saved
  end

  before do
    allow(app).to receive(:executor).and_return(executor)
    stub_const('ActiveRecord::Base', double('ActiveRecord::Base', connection_handler: connection_handler))
  end

  def configure(reloading:, allow_concurrency: nil)
    app.config.enable_reloading = reloading
    app.config.allow_concurrency = allow_concurrency
  end

  # The FiberBoundary hop in :thread scheduling: the callback runs on a
  # thread of its own. A bounded join so a regression fails instead of hanging.
  def call_on_thread(invocation = -> { :result })
    thread = Thread.new { wrapper.call(invocation) }
    raise 'callback thread did not finish (deadlock?)' unless thread.join(5)

    thread.value
  end

  context 'in production (no reloading, concurrency allowed)' do
    before { configure(reloading: false) }

    it 'runs the callback inside the executor' do
      in_executor = nil
      result = call_on_thread(lambda {
        in_executor = executor.active?
        :result
      })

      expect(result).to eq(:result)
      expect(in_executor).to be(true)
      expect(connection_handler).not_to have_received(:clear_active_connections!)
    end

    it 'also wraps under allow_concurrency = :unsafe with reloading (railties registers no lock then)' do
      configure(reloading: true, allow_concurrency: :unsafe)
      in_executor = nil
      call_on_thread(-> { in_executor = executor.active? })

      expect(in_executor).to be(true)
    end
  end

  context 'with code reloading enabled (development)' do
    before { configure(reloading: true) }

    it 'runs the callback outside the executor and releases AR connections' do
      in_executor = nil
      result = call_on_thread(lambda {
        in_executor = executor.active?
        :result
      })

      expect(result).to eq(:result)
      expect(in_executor).to be_falsey # nil on Rails 8.1: no execution state on a fresh thread
      expect(connection_handler).to have_received(:clear_active_connections!).with(:all)
    end

    it 'releases AR connections when the callback raises, and re-raises unchanged' do
      error = Class.new(StandardError)
      expect { wrapper.call(-> { raise error, 'boom' }) }.to raise_error(error, 'boom')
      expect(connection_handler).to have_received(:clear_active_connections!).with(:all)
    end

    it 'skips the release when ActiveRecord is not loaded' do
      hide_const('ActiveRecord')

      expect(call_on_thread).to eq(:result)
    end

    it 'completes while a reloader waits to unload (the :thread scheduling deadlock)' do
      # What railties registers when reloading is enabled.
      executor.register_hook(Rails::Application::Finisher::InterlockHook, outer: true)
      interlock = ActiveSupport::Dependencies.interlock
      parent_holds_share = Thread::Queue.new
      reloader_status_during_callback = nil
      reloader = nil

      # Request A: inside the executor (holding an interlock share), blocked
      # on the SDK callback thread.
      parent = Thread.new do
        executor.wrap do
          parent_holds_share << true
          Thread.pass until reloader&.status == 'sleep'
          call_on_thread(lambda {
            reloader_status_during_callback = reloader.status
            :result
          })
        end
      end
      parent_holds_share.pop

      # Request B: the Reloader, queued for the exclusive unload lock.
      reloader = Thread.new do
        executor.wrap do
          interlock.start_unloading
          interlock.done_unloading
        end
      end

      begin
        expect(parent.join(5)).not_to be_nil, 'request thread deadlocked'
        expect(reloader.join(5)).not_to be_nil, 'reloader deadlocked'
      ensure
        [parent, reloader].each(&:kill)
      end
      expect(parent.value).to eq(:result)
      # The reloader really was parked on the unload lock while the callback ran.
      expect(reloader_status_during_callback).to eq('sleep')
    end
  end

  context 'with allow_concurrency = false' do
    before { configure(reloading: false, allow_concurrency: false) }

    it 'runs the callback outside the executor, whose monitor the caller holds' do
      executor.register_hook(Rails::Application::Finisher::MonitorHook.new, outer: true)

      parent = Thread.new { executor.wrap { call_on_thread } }
      begin
        expect(parent.join(5)).not_to be_nil, 'request thread deadlocked'
      ensure
        parent.kill
      end
      expect(parent.value).to eq(:result)
      expect(connection_handler).to have_received(:clear_active_connections!).with(:all)
    end
  end

  context 'when the executor is already active on this context (:inline scheduling)' do
    before { configure(reloading: true) }

    it 'calls straight through without releasing the caller-owned connections' do
      result = executor.wrap { wrapper.call(-> { :result }) }

      expect(result).to eq(:result)
      expect(connection_handler).not_to have_received(:clear_active_connections!)
    end
  end

  it 'calls straight through when no Rails application exists' do
    allow(Rails).to receive(:application).and_return(nil)

    expect(wrapper.call(-> { :result })).to eq(:result)
  end
end
