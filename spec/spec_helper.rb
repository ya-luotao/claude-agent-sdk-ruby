# frozen_string_literal: true

# Coverage (COVERAGE=1; CI's main Ruby 3.4 leg). Must start before the SDK is
# required. simplecov lives only in the main Gemfile, so the floor/latest/rails
# bundles never load it. track_files lists lib files the main suite never
# requires too (railtie.rb and the rake tasks run only on the rails leg, which
# does not collect coverage), so untested files show up at 0% instead of
# silently dropping out of the report.
if ENV['COVERAGE'] == '1'
  require 'simplecov'
  SimpleCov.start do
    enable_coverage :branch
    add_filter '/spec/'
    track_files 'lib/**/*.rb'
  end
end

require 'claude_agent_sdk'

# async logs failed tasks through the console gem, which binds its output
# stream to whatever $stderr is on first use — and forces XTerm formatting
# under GITHUB_ACTIONS=true. If that first use lands inside an example that
# has swapped $stderr for a StringIO, every later task failure dies with
# NoMethodError (StringIO#winsize) instead of the task's own error. Bind it to
# the real stderr now, before any example can swap it.
Console.logger

# Load test helpers
Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Include test helpers
  config.include TestHelpers

  # Configure output format
  config.color = true
  config.tty = true
  config.formatter = :documentation if ENV['CI']

  # Run specs in random order to surface order dependencies
  config.order = :random
  Kernel.srand config.seed

  # Integration specs (tagged :integration) are skipped by default. RUN_INTEGRATION=1
  # is the canonical gate and runs the full suite, including the real-CLI specs
  # (which self-skip when the `claude` CLI or ANTHROPIC_API_KEY is absent).
  # RUN_REAL_INTEGRATION is accepted as a backward-compatible alias: the real-CLI
  # suite once required it as a second gate, now unified into RUN_INTEGRATION.
  run_integration = ENV['RUN_INTEGRATION'] || ENV.fetch('RUN_REAL_INTEGRATION', nil)
  config.filter_run_excluding :integration unless run_integration

  # Show the slowest examples
  config.profile_examples = 10 if ENV['PROFILE']

  # SubprocessCLITransport's at-exit registry is process-wide, so an entry one
  # example leaves in it is seen by whichever example runs next: the suite
  # used to fail for the seeds (81, 124) that ran a registry example right
  # after a leaking one. Fail the example that leaked, and hand the next one
  # an empty registry either way. This runs after a group's own `after`
  # hooks. Snapshot and clear in one step under the registry's own mutex: a
  # fallback-termination worker started by an earlier example may still be
  # deregistering on its own thread.
  config.after do
    transport = ClaudeAgentSDK::SubprocessCLITransport
    leaked = transport.active_processes_mutex.synchronize do
      entries = transport.active_processes.to_a
      transport.active_processes.clear
      entries
    end

    leak = "this example left #{leaked.size} process(es) in SubprocessCLITransport's at-exit registry " \
           "(#{leaked.inspect}): close the transport it connected, or deregister what it registered"
    expect(leaked).to be_empty, leak
  end
end
