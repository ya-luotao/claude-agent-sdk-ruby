# frozen_string_literal: true

require 'spec_helper'
require 'json'

# Version strings and copies that no code path reads, so nothing fails when
# one of them is forgotten in a release or a CLI pin bump. Each example pins
# one of them to its source of truth.
RSpec.describe 'release lockstep' do
  let(:root) { File.expand_path('../..', __dir__) }

  def read_json(path)
    JSON.parse(File.read(File.join(root, path)))
  end

  # Relative path => content, for every file under dir.
  def tree(dir)
    base = File.join(root, dir)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: base)
       .select { |path| File.file?(File.join(base, path)) }
       .to_h { |path| [path, File.binread(File.join(base, path))] }
  end

  it 'gives the Claude Code plugin the gem version' do
    plugin = read_json('plugins/claude-agent-ruby/.claude-plugin/plugin.json')

    expect(plugin['version']).to eq(ClaudeAgentSDK::VERSION)
  end

  # The CLI takes a plugin's version from its plugin.json; a `version` on the
  # marketplace entry is ignored when the two differ, and `claude plugin
  # validate --strict` rejects the mismatch. One place to bump is enough.
  it 'declares no version on the marketplace entry' do
    marketplace = read_json('.claude-plugin/marketplace.json')
    entry = marketplace.fetch('plugins').find { |plugin| plugin['name'] == 'claude-agent-ruby' }

    expect(entry).not_to be_nil
    expect(entry).not_to have_key('version')
  end

  # The skill is published twice: at the repository root and inside the
  # plugin. An edit to one copy only would ship two different skills.
  it 'keeps the two copies of the skill identical' do
    root_copy = tree('skills')
    plugin_copy = tree('plugins/claude-agent-ruby/skills/claude-agent-ruby')

    expect(root_copy).not_to be_empty
    expect(plugin_copy.keys).to match_array(root_copy.keys)
    expect(plugin_copy.reject { |path, content| root_copy[path] == content }.keys).to eq([])
  end

  # The CLI version to install is CLIInstaller::PINNED_CLI_VERSION, which
  # moves with every pin bump; a literal in the README is stale the day after
  # it is written. The minimum requirement (2.0.0) is the only CLI version
  # the README states.
  it 'names no CLI release (2.1.x) in the README' do
    readme = File.read(File.join(root, 'README.md'))

    expect(readme.scan(/\b2\.1\.\d+\b/)).to eq([])
  end
end
