# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::OptionWarnings do
  before { described_class.reset! }
  after { described_class.reset! }

  def options_with(can_use_tool: proc { |*| }, **attrs)
    ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: can_use_tool, **attrs)
  end

  def warning_for(options)
    captured = +''
    original = $stderr
    $stderr = StringIO.new(captured)
    begin
      described_class.warn_if_can_use_tool_shadowed(options)
    ensure
      $stderr = original
    end
    captured
  end

  it 'is silent when can_use_tool is not set' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(allowed_tools: ['Read'], permission_mode: 'bypassPermissions')
    expect(warning_for(options)).to be_empty
  end

  it 'is silent when nothing shadows the callback' do
    expect(warning_for(options_with)).to be_empty
  end

  it 'warns that bypassPermissions fully shadows the callback' do
    output = warning_for(options_with(permission_mode: 'bypassPermissions'))
    expect(output).to include('bypassPermissions')
    expect(output).to include('can_use_tool will not be invoked')
  end

  it 'prefers the bypassPermissions message over naming allowed_tools entries' do
    output = warning_for(options_with(permission_mode: 'bypassPermissions', allowed_tools: ['Read']))
    expect(output).to include('bypassPermissions')
    expect(output).not_to include('will not be invoked for')
  end

  it 'stays silent for acceptEdits' do
    expect(warning_for(options_with(permission_mode: 'acceptEdits'))).to be_empty
  end

  it 'names tools allowed outright, deduplicated across redundant spellings' do
    output = warning_for(options_with(allowed_tools: ['Read', 'Read()', 'Grep(*)', 'Bash(ls:*)']))
    expect(output).to include('can_use_tool will not be invoked for: Read, Grep')
    expect(output).not_to include('Bash')
  end

  it 'ignores real specifiers and malformed entries' do
    output = warning_for(options_with(allowed_tools: ['Bash(ls:*)', 'Bash(ls:*', 'Read(*x', '(*)', '  ']))
    expect(output).to be_empty
  end

  it "treats skills: 'all' as a bare Skill entry" do
    output = warning_for(options_with(skills: 'all'))
    expect(output).to include('can_use_tool will not be invoked for: Skill')
  end

  it 'does not treat named skills as shadowing' do
    expect(warning_for(options_with(skills: ['pdf']))).to be_empty
  end

  it 'emits each distinct message once per process' do
    options = options_with(allowed_tools: ['Read'])
    first = warning_for(options)
    second = warning_for(options)
    other = warning_for(options_with(allowed_tools: ['Grep']))

    expect(first).to include('Read')
    expect(second).to be_empty
    expect(other).to include('Grep')
  end
end
