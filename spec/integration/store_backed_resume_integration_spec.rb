# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'
require 'json'
require 'fileutils'

RSpec.describe 'Store-backed resume through the real Claude CLI', :integration do
  # Gated by RUN_INTEGRATION and self-skipping, like real_cli_integration_spec.rb:
  # this spawns the real `claude` CLI and makes two small, budget-capped API calls.
  before do
    skip 'Claude CLI is not available on PATH' unless system('command -v claude >/dev/null 2>&1')
    skip 'ANTHROPIC_API_KEY is required for real CLI integration tests' if ENV['ANTHROPIC_API_KEY'].to_s.empty?
  end

  # A disposable config dir, so the first turn's local transcript lands where
  # the example can delete it before resuming. No auth is copied: the CLI
  # authenticates with ANTHROPIC_API_KEY, which also keeps the SDK's macOS
  # Keychain bridge out of the picture.
  around do |example|
    previous_config_dir = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
    Dir.mktmpdir('cas-store-resume') do |directory|
      @config_dir = File.join(directory, 'config')
      @project_dir = File.join(directory, 'project')
      FileUtils.mkdir_p(@project_dir)
      ENV['CLAUDE_CONFIG_DIR'] = @config_dir
      example.run
    end
  ensure
    if previous_config_dir
      ENV['CLAUDE_CONFIG_DIR'] = previous_config_dir
    else
      ENV.delete('CLAUDE_CONFIG_DIR')
    end
  end

  def run_turn(prompt, options)
    messages = []
    ClaudeAgentSDK.query(prompt: prompt, options: options) { |message| messages << message }

    result = messages.grep(ClaudeAgentSDK::ResultMessage).last
    expect(result).to be_a(ClaudeAgentSDK::ResultMessage)
    expect(result.is_error).to be(false)
    expect(messages.grep(ClaudeAgentSDK::MirrorErrorMessage)).to be_empty
    result
  end

  it 'mirrors a turn into a SessionStore, then resumes the session from the store alone' do
    store = ClaudeAgentSDK::InMemorySessionStore.new
    marker = "MARK-#{SecureRandom.hex(4)}"
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(model: 'haiku', setting_sources: [], tools: [],
                                                     max_budget_usd: 0.05, cwd: @project_dir, session_store: store)
    materialized = []
    allow(ClaudeAgentSDK::SessionResume).to receive(:materialize_resume_session).and_wrap_original do |original, opts|
      original.call(opts).tap { |resume| materialized << resume if resume }
    end

    first = run_turn("Remember this code for later: #{marker}. Reply with exactly: OK", options)
    key = { 'project_key' => ClaudeAgentSDK.project_key_for_directory(@project_dir), 'session_id' => first.session_id }
    mirrored = store.load(key)
    expect(JSON.generate(mirrored)).to include(marker) # the turn reached the store
    expect(materialized).to be_empty # nothing to resume yet

    # Leave the store as the only copy: what the CLI resumes below is what the
    # SDK materialized from it, not the transcript the first turn left on disk.
    FileUtils.rm_rf(File.join(@config_dir, 'projects'))

    second = run_turn('What code did I ask you to remember? Reply with the code only.',
                      options.dup_with(resume: first.session_id))

    expect(second.session_id).to eq(first.session_id)
    expect(second.result.to_s).to include(marker) # the history came back
    expect(materialized.length).to eq(1)
    expect(File).not_to exist(materialized.first.config_dir) # temp config dir (credential copies) removed
    resumed = store.load(key)
    expect(resumed.length).to be > mirrored.length # the resumed turn was mirrored on top ...
    uuids = resumed.filter_map { |entry| entry['uuid'] }
    expect(uuids.uniq.length).to eq(uuids.length) # ... and the materialized history was not mirrored again
  end
end
