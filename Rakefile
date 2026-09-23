# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'yard'
# claude_agent_sdk:install_cli, through the same plain-Rakefile entry point
# the docs give non-Rails apps (the scheduled integration workflow uses it).
require 'claude_agent_sdk/tasks'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

YARD::Rake::YardocTask.new do |t|
  t.files = ['lib/**/*.rb']
  t.options = ['--markup', 'markdown']
end

namespace :rbs do
  desc 'Validate the RBS signatures in sig/'
  task :validate do
    ruby Gem.bin_path('rbs', 'rbs'), '-I', 'sig', 'validate'
  end

  # The suite again, under rbs's runtime type checker: every call into a
  # ClaudeAgentSDK class or module that has a signature in sig/ is checked
  # against it (arguments, blocks and return values), and a mismatch raises.
  # rbs/test/setup is loaded with -r after Bundler (not through RUBYOPT, which
  # would load it inside `bundle exec` before the bundle is set up). Examples
  # tagged `rbs_incompatible: '<reason>'` are left out: each one deliberately
  # passes or plants values outside the signatures (bad-input handling,
  # sentinel objects, warning locations the checker's wrapper frames shift).
  task :test_env do
    ENV['RBS_TEST_TARGET'] ||= 'ClaudeAgentSDK::*'
    ENV['RBS_TEST_OPT'] ||= '-I sig'
    ENV['RBS_TEST_DOUBLE_SUITE'] ||= 'rspec' # RSpec doubles are not type-checked
    ENV['RBS_TEST_LOGLEVEL'] ||= 'error'
  end

  desc 'Run the spec suite with RBS runtime type checking of the public API'
  RSpec::Core::RakeTask.new(:test) do |t|
    t.ruby_opts = ['-rrbs/test/setup']
    t.rspec_opts = ['--tag', '~rbs_incompatible']
  end
  Rake::Task['rbs:test'].enhance(['rbs:test_env'])
end

task default: %i[spec rubocop]
