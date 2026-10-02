# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'support/guide_option_sets'
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

  # Every ClaudeAgentOptions the guide builds, read from the parsed code of
  # its Ruby blocks (support/guide_option_sets.rb) rather than from their
  # text: a switch that is commented out, or that only appears in a string,
  # is not there. A `**opts` argument stands for the `opts = { ... }` literal
  # of the same block, which is how the session-resumption model builds its
  # options.
  reader = ClaudeAgentSDKRailsSpec::GuideOptionSets
  guide_text = File.read(File.join(root, guide))
  option_sets = reader.in_markdown(guide_text)
  carries_switch = ->(set) { set.env.to_h[variable] == '1' }

  # An option set in the guide that must not carry the switch goes here,
  # keyed by the heading it sits under, with the reason. None does.
  allowed_without_switch = {}.freeze

  describe "#{guide}, every ClaudeAgentOptions it builds" do
    it 'finds an option set in every section that builds one' do
      expect(option_sets.map(&:heading)).to include(
        'Getting started', "Carrying the caller's state into callbacks", 'ActionCable Streaming',
        'Session Resumption', 'Background Jobs with Error Handling', 'HTTP MCP Servers'
      )
    end

    option_sets.each do |set|
      it "turns auto-memory off in the options under \"#{set.heading}\"" do
        skip allowed_without_switch.fetch(set.heading) if allowed_without_switch.key?(set.heading)

        expect(set.env.to_h).to include(variable => '1'),
                                "#{guide}:#{set.line}: these options are built with env: #{set.env.inspect}"
      end
    end

    # The safeguard itself: comment out one switch at a time, in memory, and
    # the option set it belonged to — and no other — must stop counting.
    option_sets.each_with_index do |set, index|
      next unless set.env_line

      it "stops counting the switch under \"#{set.heading}\" once it is commented out" do
        lines = guide_text.lines
        lines[set.env_line - 1] = lines[set.env_line - 1].sub('env:', '# env:')

        still_carrying = reader.in_markdown(lines.join).map(&carries_switch)

        expected = option_sets.map(&carries_switch)
        expected[index] = false
        expect(carries_switch.call(set)).to be(true)
        expect(still_carrying).to eq(expected)
      end
    end
  end

  describe 'reading the option sets of a guide' do
    fence = '```'
    in_a_guide = ->(code) { reader.in_markdown("## Section\n\n#{fence}ruby\n#{code}\n#{fence}\n") }

    {
      'commented out' => "ClaudeAgentOptions.new(\n  max_turns: 1,\n  # #{switch}\n)",
      'in a trailing comment' => "ClaudeAgentOptions.new(max_turns: 1) # #{switch}",
      'in a =begin / =end comment' => "ClaudeAgentOptions.new(max_turns: 1)\n=begin\nClaudeAgentOptions.new(#{switch})\n=end",
      'inside a string' => "ClaudeAgentOptions.new(append_system_prompt: \"#{switch}\")",
      'under another key' => "ClaudeAgentOptions.new(settings: { #{switch} })",
      "given the value '0'" => "ClaudeAgentOptions.new(env: { '#{variable}' => '0' })",
      'overridden by a later env:' => "ClaudeAgentOptions.new(#{switch}, env: {})",
      'missing because there are no arguments' => 'ClaudeAgentOptions.new',
      'behind a splat that is not a hash literal of the block' => 'ClaudeAgentOptions.new(**defaults)'
    }.each do |shape, code|
      it "does not count a switch that is #{shape}" do
        expect(in_a_guide.call(code).map(&carries_switch)).to eq([false])
      end
    end

    {
      'among the keywords' => "ClaudeAgentSDK::ClaudeAgentOptions.new(max_turns: 1, #{switch})",
      'next to other variables' => "ClaudeAgentOptions.new(env: { 'ANTHROPIC_API_KEY' => ENV.fetch('KEY'), '#{variable}' => '1' })",
      'in the hash literal a **splat stands for' => "opts = {\n  #{switch} # here\n}\nClaudeAgentOptions.new(**opts)",
      'in a call without parentheses' => "ClaudeAgentSDK::ClaudeAgentOptions.new #{switch}"
    }.each do |shape, code|
      it "counts a switch that is #{shape}" do
        expect(in_a_guide.call(code).map(&carries_switch)).to eq([true])
      end
    end

    it 'reports the heading and the lines of the call and of its env: in the guide' do
      markdown = "# Guide\n\n## Section\n\n#{fence}ruby\nopts = {\n  #{switch}\n}\nClaudeAgentOptions.new(**opts)\n#{fence}\n"

      expect(reader.in_markdown(markdown).map(&:to_h)).to eq(
        [{ heading: 'Section', line: 9, env: { variable => '1' }, env_line: 7 }]
      )
    end

    it 'refuses a Ruby block that does not parse, naming its section' do
      expect { in_a_guide.call('def (') }.to raise_error(ArgumentError, /"Section" does not parse/)
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
