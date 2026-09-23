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

task default: %i[spec rubocop]
