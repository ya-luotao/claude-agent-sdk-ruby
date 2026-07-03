# frozen_string_literal: true

require 'claude_agent_sdk'

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
end
