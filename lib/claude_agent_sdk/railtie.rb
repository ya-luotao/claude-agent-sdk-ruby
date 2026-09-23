# frozen_string_literal: true

module ClaudeAgentSDK
  # Rails integration. Loaded by lib/claude_agent_sdk.rb only when
  # Rails::Railtie is already defined (Bundler.require runs after
  # `require 'rails'`), so non-Rails processes never see it.
  #
  # Deliberately minimal: it contributes the `claude_agent_sdk:*` rake tasks
  # and nothing else. It installs nothing into callback dispatch — the
  # generated initializer (`bin/rails g claude_agent_sdk:install`) opts in
  # to {.callback_wrapper} explicitly, where it is visible and removable.
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path('tasks/claude_agent_sdk.rake', __dir__)
    end

    # A `callback_wrapper` (see ClaudeAgentOptions#callback_wrapper) that
    # gives SDK callbacks Rails' connection hygiene without deadlocking
    # development code reloading.
    #
    # The obvious wrapper, `->(inv) { Rails.application.executor.wrap { inv.call } }`,
    # deadlocks whenever the executor carries a process-wide lock:
    #
    # - With code reloading enabled, every executor holds a share of the
    #   ActiveSupport::Dependencies interlock. In the default `:thread`
    #   scheduling the request/job thread (already inside the executor, so
    #   already holding a share) blocks on the FiberBoundary thread running
    #   the callback. If a reload starts meanwhile (another request after the
    #   agent edited an app file), the reloader queues for the exclusive
    #   unload lock, and the callback thread's own `executor.wrap` then waits
    #   behind it for a new share — which the reloader can never get while
    #   the parent's share is held. Three-way deadlock.
    # - With `config.allow_concurrency = false`, the executor holds a
    #   process-wide monitor that the parent thread already owns, so the
    #   callback thread's `executor.wrap` blocks every time.
    #
    # So, per invocation:
    #
    # 1. Executor already active on this execution context (`:inline`
    #    scheduling, or a callback running on the caller's own thread) —
    #    call straight through; the enclosing executor already owns cleanup.
    # 2. Executor carries a lock (the two cases above, mirroring railties'
    #    `configure_executor_for_concurrency`) — call WITHOUT entering the
    #    executor, then return this thread's ActiveRecord connections to the
    #    pool. The caller's executor still covers the callback: its share of
    #    the interlock keeps a reload from unloading code under it until the
    #    whole SDK call returns.
    # 3. Otherwise (production: no reloading, concurrency allowed) — run the
    #    callback inside `Rails.application.executor.wrap`.
    #
    # The configuration is read on every call, so the same wrapper is correct
    # in every environment.
    #
    # @return [Proc] a callable suitable for `callback_wrapper:`
    # @example config/initializers/claude_agent_sdk.rb
    #   ClaudeAgentSDK.configure do |config|
    #     config.default_options = { callback_wrapper: ClaudeAgentSDK::Railtie.callback_wrapper }
    #   end
    def self.callback_wrapper
      lambda do |invocation|
        app = ::Rails.application
        next invocation.call if app.nil? || app.executor.active?
        next app.executor.wrap { invocation.call } unless executor_locks?(app.config)

        begin
          invocation.call
        ensure
          release_active_record_connections
        end
      end
    end

    # Whether railties registered a process-wide lock hook on the executor
    # (Rails::Application::Finisher, initializer
    # :configure_executor_for_concurrency).
    def self.executor_locks?(config)
      return true if config.allow_concurrency == false
      return false if config.allow_concurrency == :unsafe

      config.reloading_enabled?
    end
    private_class_method :executor_locks?

    # What the executor's ActiveRecord completion hook does for a callback
    # that ran on a thread of its own. Explicit :all — the no-argument form
    # is deprecated on Rails 7.1.
    def self.release_active_record_connections
      return unless defined?(::ActiveRecord::Base)

      ::ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
    end
    private_class_method :release_active_record_connections
  end
end
