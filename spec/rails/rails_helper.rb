# frozen_string_literal: true

# Rails integration specs. They load railties/ActiveSupport, which patch core
# classes process-wide, so they never run inside the default suite (the root
# .rspec excludes spec/rails). Run them in their own process against a Rails
# bundle, with this directory's options file replacing the root one:
#
#   BUNDLE_GEMFILE=gemfiles/rails_8.gemfile bundle exec rspec --options spec/rails/.rspec
#
# Each spec file requires this helper itself: the options file deliberately
# has no --require, because Rails must be loaded BEFORE the SDK for the
# SDK's `if defined?(Rails::Railtie)` hook to load the Railtie the way a
# real app's Bundler.require does.

require 'rails'
require 'tmpdir'
require_relative '../spec_helper'

module ClaudeAgentSDKRailsSpec
  # A minimal, never-initialized application: enough for Rails.root,
  # Rails.application.config and the executor.
  class Application < Rails::Application
    config.root = Dir.mktmpdir('claude_agent_sdk_rails_app')
    config.eager_load = false
    config.logger = Logger.new(nil)
  end
end

RSpec.configure do |config|
  config.after(:suite) { FileUtils.rm_rf(Rails.root.to_s) }
end
