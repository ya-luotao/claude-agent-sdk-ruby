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

  # Filter to skip slow integration tests by default
  config.filter_run_excluding :integration unless ENV['RUN_INTEGRATION']

  # Show the slowest examples
  config.profile_examples = 10 if ENV['PROFILE']
end
