# frozen_string_literal: true

require_relative 'rails_helper'
require 'tmpdir'
require 'generators/claude_agent_sdk/install/install_generator'

# The Rails guide, its two examples and the generated initializer describe
# one process that serves every user from one working directory. The CLI's
# auto-memory is kept per project directory, every session reads it, and a
# session on the claude_code preset writes it without a permission check
# (setting_sources: [] does not turn it off) — so one user's "remember ..."
# would reach every other user's session. Those option sets therefore carry
# the switch that turns auto-memory off, and its value matters: the CLI reads
# '0' / 'false' as "force on", over autoMemoryEnabled: false.
RSpec.describe 'Auto-memory isolation in the Rails guide, examples and initializer' do
  root = File.expand_path('../..', __dir__)
  variable = 'CLAUDE_CODE_DISABLE_AUTO_MEMORY'
  switch = "env: { '#{variable}' => '1' }"
  guide = 'docs/rails.md'
  actioncable_example = 'examples/rails_actioncable_example.rb'
  background_job_example = 'examples/rails_background_job_example.rb'
  template = 'lib/generators/claude_agent_sdk/install/templates/claude_agent_sdk.rb.tt'

  # An example script's classes, loaded under a module of their own so they
  # stay out of this process's top level. The demo at the bottom of each
  # script only runs when the script is the program.
  define_method(:load_example) do |path|
    Module.new.tap { |namespace| load(File.join(root, path), namespace) }
  end

  [guide, actioncable_example, background_job_example, template].each do |path|
    it "#{path} never gives the variable a value other than '1'" do
      values = File.read(File.join(root, path)).scan(/#{variable}['"]?\s*(?:=>|=|:)\s*(['"]?\w+['"]?)/).flatten

      expect(values).not_to be_empty
      expect(values).to all(eq("'1'"))
    end
  end

  describe guide do
    let(:ruby_blocks) { File.read(File.join(root, guide)).scan(/^```ruby\n(.*?)^```$/m).flatten }

    it 'turns auto-memory off in the ActionCable chat job' do
      chat_job = ruby_blocks.find { |block| block.include?('class ChatAgentJob') }

      expect(chat_job).to include("preset: 'claude_code'").and include(switch)
    end

    it 'turns auto-memory off in the session-resumption options' do
      build_options = ruby_blocks.find { |block| block.include?('def build_options') }

      expect(build_options).to include(switch)
    end
  end

  describe actioncable_example do
    it 'opens every chat session with auto-memory off' do
      options = nil
      allow(ClaudeAgentSDK::Client).to receive(:open) { |**kwargs| options = kwargs.fetch(:options) }

      load_example(actioncable_example)::ChatExecutor.new(chat_id: 'chat_1', message_id: 'msg_1').execute('hi')

      expect(options.system_prompt).to include(preset: 'claude_code')
      expect(options.env).to include(variable => '1')
    end
  end

  describe background_job_example do
    it 'builds every job session with auto-memory off' do
      example = load_example(background_job_example)

      options = example::ChatAgentJob.new.send(:build_options, example::ChatSession.new(id: 'session_1'))

      expect(options.system_prompt).to include(preset: 'claude_code')
      expect(options.env).to include(variable => '1')
    end
  end

  describe 'the generated initializer' do
    let(:destination) { Dir.mktmpdir('claude_agent_sdk_generator') }
    let(:initializer) { File.join(destination, 'config/initializers/claude_agent_sdk.rb') }

    before do
      generate = -> { ClaudeAgentSDK::Generators::InstallGenerator.start([], destination_root: destination) }
      expect(&generate).to output.to_stdout
    end

    after do
      FileUtils.rm_rf(destination)
      ClaudeAgentSDK.reset_configuration
    end

    it 'offers the switch as a commented default' do
      expect(File.read(initializer)).to include("    # #{switch},\n")

      load initializer

      expect(ClaudeAgentSDK::ClaudeAgentOptions.new.env).not_to include(variable)
    end

    it 'turns auto-memory off for every session once the line is uncommented, next to a per-call env' do
      File.write(initializer, File.read(initializer).sub("# #{switch}", switch))
      load initializer

      expect(ClaudeAgentSDK::ClaudeAgentOptions.new.env).to eq(variable => '1')
      expect(ClaudeAgentSDK::ClaudeAgentOptions.new(env: { 'ANTHROPIC_API_KEY' => 'key' }).env).to eq(
        variable => '1', 'ANTHROPIC_API_KEY' => 'key'
      )
    end
  end
end
