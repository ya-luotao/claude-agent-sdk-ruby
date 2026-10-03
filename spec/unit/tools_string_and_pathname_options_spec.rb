# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'pathname'
require 'tmpdir'

# Two forms a Ruby caller writes naturally and the command builder had no
# branch for, so they were dropped without a word:
#
#   tools: 'Read,Grep'   the CLI's own --tools syntax. No flag was sent, so
#                        the session got EVERY built-in tool, not two.
#   a Pathname           where a path is expected. settings: Pathname sent no
#                        --settings at all; SystemPromptFile#path and a plugin
#                        path put the Pathname itself on the command line,
#                        which the spawn rejects ("no implicit conversion of
#                        Pathname into String").
RSpec.describe 'tools as a String and paths as Pathnames' do
  # The command line built for these options.
  def argv(**options)
    ClaudeAgentSDK::CommandBuilder.new('/usr/bin/claude', ClaudeAgentSDK::ClaudeAgentOptions.new(**options)).build
  end

  # The value that follows +flag+ on that command line (nil without the flag).
  def flag_value(cmd, flag)
    index = cmd.index(flag)
    index && cmd[index + 1]
  end

  describe 'tools: as a String' do
    it 'builds the command line the Array of the same names builds' do
      expect(argv(tools: 'Read,Grep')).to eq(argv(tools: %w[Read Grep]))
    end

    it 'is passed to --tools as written: it is the CLI\'s own syntax' do
      values = ['Read,Grep', 'Read', 'default', ''].map { |tools| flag_value(argv(tools: tools), '--tools') }

      expect(values).to eq(['Read,Grep', 'Read', 'default', ''])
    end

    it 'still sends no --tools flag for a value of another class',
       rbs_incompatible: 'passes values outside the signature of tools to show they are still ignored' do
      expect([42, :default, true].map { |tools| argv(tools: tools) }).to eq([argv] * 3)
    end
  end

  describe 'settings: as a Pathname' do
    it 'builds the command line the String path builds' do
      path = '/srv/app/config/claude.json'

      expect(argv(settings: Pathname.new(path))).to eq(argv(settings: path))
      expect(flag_value(argv(settings: Pathname.new(path)), '--settings')).to eq(path)
    end

    it 'is read and merged with the sandbox option like the String path, relative to the CLI\'s cwd' do
      Dir.mktmpdir('pathname-settings') do |dir|
        File.write(File.join(dir, 'claude.json'), JSON.generate(permissions: { deny: ['WebFetch'] }))
        absolute = File.join(dir, 'claude.json')
        forms = [
          { settings: Pathname.new(absolute) },
          { settings: Pathname.new('claude.json'), cwd: dir },
          { settings: Pathname.new('claude.json'), cwd: Pathname.new(dir) }
        ]

        merged = forms.map { |form| JSON.parse(flag_value(argv(sandbox: { enabled: true }, **form), '--settings')) }

        expect(merged).to eq([{ 'permissions' => { 'deny' => ['WebFetch'] }, 'sandbox' => { 'enabled' => true } }] * 3)
        expect(argv(sandbox: { enabled: true }, settings: Pathname.new(absolute)))
          .to eq(argv(sandbox: { enabled: true }, settings: absolute))
      end
    end

    # A String is tried as inline JSON first and taken for a path when it does
    # not parse. A Pathname says which of the two it is.
    it 'is a path even when its name would parse as JSON' do
      expect(flag_value(argv(settings: Pathname.new('42')), '--settings')).to eq('42')
    end
  end

  describe 'the path of a system prompt file, as a Pathname' do
    path = '/srv/app/prompts/reviewer.md'
    {
      'a SystemPromptFile' => ClaudeAgentSDK::SystemPromptFile.new(path: Pathname.new(path)),
      'a Hash' => { type: 'file', path: Pathname.new(path) },
      'a Hash with a Symbol type and String keys' => { 'type' => :file, 'path' => Pathname.new(path) }
    }.each do |form, system_prompt|
      it "reaches the command line as a String for #{form}" do
        cmd = argv(system_prompt: system_prompt)

        expect(cmd).to all(be_a(String))
        expect(cmd).to eq(argv(system_prompt: ClaudeAgentSDK::SystemPromptFile.new(path: path)))
        expect(flag_value(cmd, '--system-prompt-file')).to eq(path)
      end
    end

    it 'stays the Pathname the caller gave on the typed value' do
      pathname = Pathname.new(path)
      prompt = ClaudeAgentSDK::SystemPromptFile.new(path: pathname)

      expect(prompt.path).to equal(pathname)
      expect(prompt.to_h).to eq(type: 'file', path: pathname)
    end
  end

  describe 'a plugin path as a Pathname' do
    path = '/srv/app/plugins/review'
    {
      'an SdkPluginConfig' => ClaudeAgentSDK::SdkPluginConfig.new(path: Pathname.new(path)),
      'a Hash' => { type: 'local', path: Pathname.new(path) },
      'a Hash with String keys' => { 'type' => 'local', 'path' => Pathname.new(path) }
    }.each do |form, plugin|
      it "reaches the command line as a String for #{form}" do
        cmd = argv(plugins: [plugin])

        expect(cmd).to all(be_a(String))
        expect(cmd).to eq(argv(plugins: [ClaudeAgentSDK::SdkPluginConfig.new(path: path)]))
        expect(flag_value(cmd, '--plugin-dir')).to eq(path)
      end
    end

    it 'stays the Pathname the caller gave on the typed value' do
      pathname = Pathname.new(path)
      plugin = ClaudeAgentSDK::SdkPluginConfig.new(path: pathname)

      expect(plugin.path).to equal(pathname)
      expect(plugin.to_h).to eq(type: 'local', path: pathname)
    end
  end
end
