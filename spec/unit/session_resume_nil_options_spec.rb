# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'
require 'fileutils'

# ClaudeAgentOptions fills `env` and `load_timeout_ms` with their defaults in
# the constructor only. Both attributes are nilable, and the natural ways to
# clear one afterwards — `options.dup_with(env: nil)`, `options.env = nil` —
# leave nil in place. Store-backed resume has to read them as their defaults
# (60 s; no overrides) rather than raise NoMethodError on nil.
RSpec.describe ClaudeAgentSDK::SessionResume do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:cwd) { Dir.mktmpdir }
  let(:caller_config_dir) { Dir.mktmpdir }
  let(:sid) { SecureRandom.uuid }
  let(:materializations) { [] }
  let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: cwd) }

  # Without options.env the child's config dir is the parent's: point that at
  # a scratch directory, so nothing is seeded from the developer's own.
  around do |example|
    previous = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
    ENV['CLAUDE_CONFIG_DIR'] = caller_config_dir
    example.run
  ensure
    previous.nil? ? ENV.delete('CLAUDE_CONFIG_DIR') : (ENV['CLAUDE_CONFIG_DIR'] = previous)
  end

  before do
    allow(described_class).to receive(:read_keychain_credentials).and_return(nil)
    store.append({ 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => sid },
                 [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'sessionId' => sid,
                    'message' => { 'role' => 'user', 'content' => 'hello' } }])
  end

  after do
    materializations.each(&:cleanup)
    [cwd, caller_config_dir].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def materialize(options)
    described_class.materialize_resume_session(options).tap { |materialized| materializations << materialized if materialized }
  end

  it 'bounds the store calls by the 60 s default when load_timeout_ms is nil' do
    allow(ClaudeAgentSDK::FiberBoundary).to receive(:invoke).and_call_original

    materialized = materialize(options.dup_with(load_timeout_ms: nil))

    expect(materialized.resume_session_id).to eq(sid)
    expect(ClaudeAgentSDK::FiberBoundary).to have_received(:invoke).with(hash_including(timeout: 60.0)).at_least(:once)
  end

  it 'still honors an explicit load_timeout_ms of 0' do
    allow(ClaudeAgentSDK::FiberBoundary).to receive(:invoke).and_return([])

    materialize(options.dup_with(load_timeout_ms: 0))

    expect(ClaudeAgentSDK::FiberBoundary).to have_received(:invoke).with(hash_including(timeout: 0.0)).at_least(:once)
  end

  it 'materializes from the parent environment and repoints the options when env is nil' do
    File.write(File.join(caller_config_dir, 'settings.json'), '{"apiKeyHelper":"/bin/print-key"}')
    without_env = options.dup_with(env: nil)

    materialized = materialize(without_env)
    applied = described_class.apply_materialized_options(without_env, materialized)

    expect(File.read(File.join(materialized.config_dir, 'settings.json'))).to eq('{"apiKeyHelper":"/bin/print-key"}')
    expect(applied.env).to eq('CLAUDE_CONFIG_DIR' => materialized.config_dir)
    expect(applied.resume).to eq(sid)
    expect(without_env.env).to be_nil # the caller's options are left as they were
  end

  it 'gets Client past materialization with both set back to nil' do
    cleared = options.dup_with(env: nil, load_timeout_ms: nil)
    client = ClaudeAgentSDK::Client.new(options: cleared)

    applied = client.send(:materialize_resume, cleared)
    materializations << client.instance_variable_get(:@materialized)

    expect(applied.env).to eq('CLAUDE_CONFIG_DIR' => materializations.first.config_dir)
    expect(applied.resume).to eq(sid)
  end
end
