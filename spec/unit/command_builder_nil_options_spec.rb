# frozen_string_literal: true

require 'spec_helper'

# allowed_tools, disallowed_tools, add_dirs and extra_args are filled with
# their defaults by the constructor, and their signatures are nilable: "nil
# only when set to nil afterwards". `options.dup_with(allowed_tools: nil)` or
# `options.extra_args = nil` — the natural way to clear one — kept the nil,
# and the builder then called a method on it.
RSpec.describe ClaudeAgentSDK::CommandBuilder do
  def argv(options)
    described_class.new('/usr/bin/claude', options).build
  end

  populated = {
    allowed_tools: ['Read'],
    disallowed_tools: ['Bash'],
    add_dirs: ['/work/shared'],
    extra_args: { 'debug-to-stderr' => nil }
  }.freeze

  # What each option contributes to the command when it is set.
  contributions = {
    allowed_tools: ['--allowedTools', 'Read'],
    disallowed_tools: ['--disallowedTools', 'Bash'],
    add_dirs: ['--add-dir', '/work/shared'],
    extra_args: ['--debug-to-stderr']
  }.freeze

  {
    '#dup_with' => ->(options, name) { options.dup_with(name => nil) },
    'its writer' => ->(options, name) { options.tap { |opts| opts.public_send(:"#{name}=", nil) } }
  }.each do |way, clear|
    populated.each_key do |name|
      it "builds the command without #{name} once it is set to nil through #{way}" do
        options = clear.call(ClaudeAgentSDK::ClaudeAgentOptions.new(**populated), name)
        expected = argv(ClaudeAgentSDK::ClaudeAgentOptions.new(**populated.except(name)))

        expect(options.public_send(name)).to be_nil
        expect(argv(options)).to eq(expected)
        expect(expected).not_to include(*contributions.fetch(name))
        expect(expected).to include(*contributions.except(name).values.flatten)
      end
    end
  end

  it 'builds the default command when all four are nil, and leaves them nil' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new
    populated.each_key { |name| options.public_send(:"#{name}=", nil) }

    expect(argv(options)).to eq(argv(ClaudeAgentSDK::ClaudeAgentOptions.new))
    expect(populated.keys.map { |name| options.public_send(name) }).to all(be_nil)
  end

  it 'still adds the Skill rule that skills implies when allowed_tools is nil' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(skills: %w[pdf]).dup_with(allowed_tools: nil)
    cmd = argv(options)

    expect(cmd[cmd.index('--allowedTools') + 1]).to eq('Skill(pdf)')
  end
end
