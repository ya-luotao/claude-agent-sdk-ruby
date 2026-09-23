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

  describe 'CLI discovery root' do
    let(:initializer) { described_class.instance.initializers.find { |i| i.name == 'claude_agent_sdk.cli_installer_root' } }

    after { ClaudeAgentSDK::CLIInstaller.root = nil }

    it 'runs before config/initializers, so an app initializer can override it' do
      expect(initializer.before).to eq(:load_config_initializers)
    end

    it 'is set on boot, before config/initializers, which can still override it' do
      Dir.mktmpdir('claude_agent_sdk_boot') do |app_root|
        FileUtils.mkdir_p(File.join(app_root, 'config/initializers'))
        File.write(File.join(app_root, 'config/initializers/claude_agent_sdk.rb'), <<~RUBY)
          $root_seen_by_initializer = ClaudeAgentSDK::CLIInstaller.root
          ClaudeAgentSDK::CLIInstaller.root = '/opt/agents'
        RUBY
        code = <<~RUBY
          require 'rails'
          require 'claude_agent_sdk'
          class BootApp < Rails::Application
            config.root = #{app_root.dump}
            config.eager_load = false
            config.logger = Logger.new(nil)
          end
          Rails.application.initialize!
          puts $root_seen_by_initializer, ClaudeAgentSDK::CLIInstaller.root
        RUBY

        out, err, status = run_ruby(code)

        expect(status.success?).to be(true), err
        expect(out.lines(chomp: true)).to eq([app_root, '/opt/agents'])
      end
    end

    it 'points CLIInstaller at Rails.root, whatever the process cwd' do
      initializer.run(Rails.application)

      expect(ClaudeAgentSDK::CLIInstaller.root).to eq(Rails.root.to_s)
      Dir.chdir(Dir.tmpdir) do
        expect(ClaudeAgentSDK::CLIInstaller.default_dir).to eq(Rails.root.join('vendor', 'claude').to_s)
      end
    end

    it 'leaves a root the app already set alone' do
      ClaudeAgentSDK::CLIInstaller.root = '/opt/agents'

      initializer.run(Rails.application)

      expect(ClaudeAgentSDK::CLIInstaller.root).to eq('/opt/agents')
    end

    it 'lets the vendored binary under Rails.root win discovery from another cwd' do
      binary = Rails.root.join('vendor', 'claude', 'claude').to_s
      FileUtils.mkdir_p(File.dirname(binary))
      File.write(binary, "#!/bin/sh\n")
      File.chmod(0o755, binary)
      initializer.run(Rails.application)

      Dir.chdir(Dir.tmpdir) do
        expect(ClaudeAgentSDK::CLIInstaller.installed_path).to eq(binary)
      end
    ensure
      FileUtils.rm_rf(Rails.root.join('vendor').to_s)
    end
  end

  describe 'rake tasks' do
    let(:task) { Rake::Task['claude_agent_sdk:install_cli'] }
    let(:vendor_dir) { Rails.root.join('vendor', 'claude').to_s }

    after { ClaudeAgentSDK::CLIInstaller.root = nil }

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

    it 'installs under an explicitly set CLIInstaller.root, where discovery looks' do
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:install_pinned).and_return('/fake/claude')
      ClaudeAgentSDK::CLIInstaller.root = '/opt/agents'

      run_task

      expect(ClaudeAgentSDK::CLIInstaller).to have_received(:install_pinned).with(dir: nil)
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
