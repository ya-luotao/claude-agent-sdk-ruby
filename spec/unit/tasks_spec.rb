# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

# `require 'claude_agent_sdk/tasks'` from a plain (non-Rails) Rakefile — the
# Dockerfile use case. Run in a child process: loading rake here would patch
# String (#ext, #pathmap) under the whole suite. The Rails side (Railtie,
# Rails.root) is covered by spec/rails.
RSpec.describe 'claude_agent_sdk/tasks' do
  # The deps legs (gemfiles/floor|latest.gemfile) bundle runtime deps only.
  before { skip 'rake is not in this bundle' unless Gem.loaded_specs.key?('rake') }

  # Stubs CLIInstaller in the child (no network) and prints what it was asked.
  def run_task(env = {})
    code = <<~RUBY
      require 'claude_agent_sdk/tasks'
      installer = ClaudeAgentSDK::CLIInstaller
      installer.define_singleton_method(:install_pinned) { |dir:| warn "pinned dir=\#{dir.inspect}"; '/fake/claude' }
      installer.define_singleton_method(:install) { |version:, dir:| warn "install \#{version} dir=\#{dir.inspect}"; '/fake/claude' }
      Rake::Task['claude_agent_sdk:install_cli'].invoke
      exit(defined?(ClaudeAgentSDK::Client) ? 3 : 0)
    RUBY
    lib_dir = File.expand_path('../../lib', __dir__)
    Open3.capture3(env, RbConfig.ruby, '-I', lib_dir, '-e', code)
  end

  it 'installs the pinned CLI relative to the working directory, loading only the installer' do
    out, err, status = run_task('CLAUDE_CLI_VERSION' => nil)

    expect(status.exitstatus).to eq(0), err
    expect(err).to include('pinned dir=nil')
    expect(out).to include("(#{ClaudeAgentSDK::CLIInstaller::PINNED_CLI_VERSION}) installed at /fake/claude")
  end

  it 'installs CLAUDE_CLI_VERSION= instead of the pin when given' do
    out, err, status = run_task('CLAUDE_CLI_VERSION' => 'latest')

    expect(status.exitstatus).to eq(0), err
    expect(err).to include('install latest dir=nil')
    expect(out).to include('(latest) installed at /fake/claude')
  end
end
