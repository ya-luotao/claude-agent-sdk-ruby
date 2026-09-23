# frozen_string_literal: true

require_relative 'rails_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'generators/claude_agent_sdk/install/install_generator'

RSpec.describe ClaudeAgentSDK::Generators::InstallGenerator do
  let(:destination) { Dir.mktmpdir('claude_agent_sdk_generator') }
  let(:initializer) { File.join(destination, 'config/initializers/claude_agent_sdk.rb') }
  let(:gitignore) { File.join(destination, '.gitignore') }
  let(:template) { File.expand_path('../../lib/generators/claude_agent_sdk/install/templates/claude_agent_sdk.rb.tt', __dir__) }

  after do
    FileUtils.rm_rf(destination)
    ClaudeAgentSDK.reset_configuration
  end

  def generate
    described_class.start([], destination_root: destination)
  end

  def vendor_claude_lines
    File.readlines(gitignore, chomp: true).count { |line| line.strip.match?(%r{\A/?vendor/claude/?\z}) }
  end

  it 'is found by `bin/rails generate claude_agent_sdk:install`' do
    expect(Rails::Generators.find_by_namespace('claude_agent_sdk:install')).to eq(described_class)
  end

  it 'creates the initializer and prints the next steps' do
    expect { generate }.to output(%r{claude_agent_sdk:install_cli.*docs/rails\.md}m).to_stdout

    expect(File.read(initializer)).to eq(File.read(template))
  end

  it 'writes an initializer that Ruby accepts' do
    silence_stdout { generate }

    _out, err, status = Open3.capture3(RbConfig.ruby, '-c', initializer)
    expect(status.success?).to be(true), err
  end

  it 'writes an initializer that configures valid defaults with the Rails callback wrapper' do
    silence_stdout { generate }

    load initializer
    options = ClaudeAgentSDK::ClaudeAgentOptions.new

    expect(options.callback_wrapper).to respond_to(:call)
    expect(options.callback_wrapper.call(-> { :ran })).to eq(:ran)
  end

  it 'only references real ClaudeAgentOptions options, commented or not' do
    # Entries of the default_options Hash, live or commented out (4-space indent).
    keys = File.read(template).scan(/^ {4}(?:# )?([a-z_]+): /).flatten.uniq

    expect(keys).to include('model', 'permission_mode', 'cli_path', 'observers', 'callback_wrapper')
    keys.each do |key|
      expect(ClaudeAgentSDK::ClaudeAgentOptions.method_defined?("#{key}=")).to be(true), "unknown option #{key}"
    end
  end

  describe '.gitignore' do
    it 'is created with the vendored CLI entry when missing' do
      silence_stdout { generate }

      expect(vendor_claude_lines).to eq(1)
    end

    it 'gains the entry exactly once across repeated runs' do
      File.write(gitignore, "/log/*\n/tmp/*\n")

      2.times { silence_stdout { generate } }

      expect(vendor_claude_lines).to eq(1)
      expect(File.read(gitignore)).to start_with("/log/*\n/tmp/*\n\n# Claude Code CLI")
    end

    it 'is left untouched when another spelling already ignores vendor/claude' do
      File.write(gitignore, "/log/*\nvendor/claude\n")

      silence_stdout { generate }

      expect(File.read(gitignore)).to eq("/log/*\nvendor/claude\n")
    end

    it 'starts the entry on its own line when the file lacks a trailing newline' do
      File.write(gitignore, '/log/*')

      silence_stdout { generate }

      expect(File.read(gitignore)).to eq("/log/*\n\n# Claude Code CLI vendored by `bin/rails " \
                                         "claude_agent_sdk:install_cli`\n/vendor/claude/\n")
    end
  end

  def silence_stdout(&block)
    expect(&block).to output.to_stdout
  end
end
