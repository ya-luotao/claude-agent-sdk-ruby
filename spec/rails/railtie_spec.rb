# frozen_string_literal: true

require_relative 'rails_helper'
require 'open3'
require 'rake'
require 'rbconfig'

RSpec.describe ClaudeAgentSDK::Railtie do
  def run_ruby(code)
    lib_dir = File.expand_path('../../lib', __dir__)
    Open3.capture3(RbConfig.ruby, '-I', lib_dir, '-e', code)
  end

  it 'is registered as a Rails::Railtie' do
    expect(Rails::Railtie.subclasses).to include(described_class)
  end

  it 'loads when Rails is required before the SDK (the Bundler.require order)' do
    code = "require 'rails'; require 'claude_agent_sdk'; exit(defined?(ClaudeAgentSDK::Railtie) ? 0 : 1)"
    _out, err, status = run_ruby(code)
    expect(status.exitstatus).to eq(0), "expected the Railtie to load after `require 'rails'`: #{err}"
  end

  it 'stays out of a process that has Rails installed but does not load it' do
    code = "require 'claude_agent_sdk'; exit(defined?(ClaudeAgentSDK::Railtie) || defined?(Rails) ? 1 : 0)"
    _out, err, status = run_ruby(code)
    expect(status.exitstatus).to eq(0), "a non-Rails require must load neither Rails nor the Railtie: #{err}"
  end

  describe 'rake tasks' do
    let(:task) { Rake::Task['claude_agent_sdk:install_cli'] }
    let(:vendor_dir) { Rails.root.join('vendor', 'claude').to_s }

    around do |example|
      previous = Rake.application
      Rake.application = Rake::Application.new
      # What `rake -T` / `bin/rails -T` turn on; descriptions are dropped otherwise.
      Rake::TaskManager.record_task_metadata = true
      Rails.application.load_tasks
      example.run
    ensure
      Rake::TaskManager.record_task_metadata = false
      Rake.application = previous
    end

    def run_task
      task.reenable
      expect { task.invoke }.to output(%r{installed at /fake/claude}).to_stdout
    end

    it 'defines claude_agent_sdk:install_cli with a description' do
      expect(Rake::Task.task_defined?('claude_agent_sdk:install_cli')).to be(true)
      expect(task.comment).to include('vendor/claude')
    end

    it 'installs the pinned CLI into Rails.root/vendor/claude' do
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:install_pinned).and_return('/fake/claude')

      run_task

      expect(ClaudeAgentSDK::CLIInstaller).to have_received(:install_pinned).with(dir: vendor_dir)
    end

    it 'installs CLAUDE_CLI_VERSION= instead of the pin when given' do
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:install).and_return('/fake/claude')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('CLAUDE_CLI_VERSION', '').and_return('2.1.200')

      run_task

      expect(ClaudeAgentSDK::CLIInstaller).to have_received(:install).with(version: '2.1.200', dir: vendor_dir)
    end

    it 'treats an empty CLAUDE_CLI_VERSION= as unset' do
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:install_pinned).and_return('/fake/claude')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('CLAUDE_CLI_VERSION', '').and_return(' ')

      run_task

      expect(ClaudeAgentSDK::CLIInstaller).to have_received(:install_pinned).with(dir: vendor_dir)
    end

    it 'defines the task once when the app also requires claude_agent_sdk/tasks' do
      load File.expand_path('../../lib/claude_agent_sdk/tasks.rb', __dir__)

      expect(task.actions.size).to eq(1)
    end
  end
end
