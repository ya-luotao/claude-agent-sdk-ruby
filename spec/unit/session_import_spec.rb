# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe 'ClaudeAgentSDK.import_session_to_store' do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:config_dir) { Dir.mktmpdir }
  let(:cwd) { Dir.mktmpdir }
  let(:project_key) { ClaudeAgentSDK.project_key_for_directory(cwd) }
  let(:project_dir) { File.join(config_dir, 'projects', project_key) }
  let(:sid) { SecureRandom.uuid }

  around do |example|
    prev = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
    ENV['CLAUDE_CONFIG_DIR'] = config_dir
    example.run
  ensure
    prev.nil? ? ENV.delete('CLAUDE_CONFIG_DIR') : (ENV['CLAUDE_CONFIG_DIR'] = prev)
    FileUtils.remove_entry(config_dir) if File.directory?(config_dir)
    FileUtils.remove_entry(cwd) if File.directory?(cwd)
  end

  def jsonl_line(text)
    JSON.generate('type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => text })
  end

  def write_main_transcript
    FileUtils.mkdir_p(project_dir)
    File.write(File.join(project_dir, "#{sid}.jsonl"), "#{jsonl_line('one')}\n#{jsonl_line('two')}\n")
  end

  it 'raises ArgumentError for an invalid UUID' do
    expect do
      ClaudeAgentSDK.import_session_to_store(session_id: 'not-a-uuid', session_store: store, directory: cwd)
    end.to raise_error(ArgumentError, /Invalid session_id/)
  end

  it 'raises Errno::ENOENT when the session file is not found' do
    expect do
      ClaudeAgentSDK.import_session_to_store(session_id: sid, session_store: store, directory: cwd)
    end.to raise_error(Errno::ENOENT)
  end

  it 'replays the local transcript into the store under the on-disk project key' do
    write_main_transcript
    ClaudeAgentSDK.import_session_to_store(session_id: sid, session_store: store, directory: cwd)

    entries = store.load('project_key' => project_key, 'session_id' => sid)
    expect(entries.length).to eq(2)
    expect(entries.map { |e| e['message']['content'] }).to eq(%w[one two])
    # Keyed so it is resumable from the original cwd.
    expect(store.list_sessions(project_key).map { |s| s['session_id'] }).to eq([sid])
  end

  # P2: a truncated trailing line is an ordinary interrupted-CLI artifact;
  # every read path tolerates it, so an import must not abort mid-way with a
  # raw JSON::ParserError leaving a partial store import behind.
  it 'skips an unparseable trailing line with a warning instead of aborting mid-import' do
    FileUtils.mkdir_p(project_dir)
    File.write(File.join(project_dir, "#{sid}.jsonl"),
               "#{jsonl_line('one')}\n#{jsonl_line('two')}\n{\"type\":\"user\",\"uuid\":\"trunc")

    expect do
      ClaudeAgentSDK.import_session_to_store(session_id: sid, session_store: store, directory: cwd)
    end.to output(/skipped unparseable line 3/).to_stderr

    entries = store.load('project_key' => project_key, 'session_id' => sid)
    expect(entries.map { |e| e['message']['content'] }).to eq(%w[one two])
  end

  it 'batches appends by batch_size' do
    write_main_transcript
    calls = []
    recorder = Class.new(ClaudeAgentSDK::SessionStore) do
      define_method(:append) { |_key, entries| calls << entries.length }
      def load(_key) = nil
    end.new
    ClaudeAgentSDK.import_session_to_store(session_id: sid, session_store: recorder, directory: cwd, batch_size: 1)
    expect(calls).to eq([1, 1]) # two entries, batch_size 1 -> two appends
  end

  it 'imports with the default batch size when batch_size is explicitly nil' do
    # Regression: the normalization guard used bare batch_size.positive?, so
    # the one invalid value optional params commonly produce (nil) crashed with
    # NoMethodError instead of defaulting.
    write_main_transcript
    ClaudeAgentSDK.import_session_to_store(session_id: sid, session_store: store, directory: cwd, batch_size: nil)
    expect(store.load('project_key' => project_key, 'session_id' => sid).length).to eq(2)
  end

  it 'imports subagent transcripts and reconstructs agent_metadata from the .meta.json sidecar' do
    write_main_transcript
    sub_dir = File.join(project_dir, sid, 'subagents')
    FileUtils.mkdir_p(sub_dir)
    File.write(File.join(sub_dir, 'agent-x.jsonl'), "#{jsonl_line('sub line')}\n")
    File.write(File.join(sub_dir, 'agent-x.meta.json'), JSON.generate('agentType' => 'researcher'))

    ClaudeAgentSDK.import_session_to_store(session_id: sid, session_store: store, directory: cwd)

    sub_key = { 'project_key' => project_key, 'session_id' => sid, 'subpath' => 'subagents/agent-x' }
    entries = store.load(sub_key)
    expect(entries.map { |e| e['type'] }).to contain_exactly('user', 'agent_metadata')
    meta = entries.find { |e| e['type'] == 'agent_metadata' }
    expect(meta['agentType']).to eq('researcher')
    expect(store.list_subkeys('project_key' => project_key, 'session_id' => sid)).to eq(['subagents/agent-x'])
  end

  it 'skips subagents when include_subagents is false' do
    write_main_transcript
    FileUtils.mkdir_p(File.join(project_dir, sid, 'subagents'))
    File.write(File.join(project_dir, sid, 'subagents', 'agent-x.jsonl'), "#{jsonl_line('sub')}\n")

    ClaudeAgentSDK.import_session_to_store(session_id: sid, session_store: store, directory: cwd,
                                           include_subagents: false)
    expect(store.list_subkeys('project_key' => project_key, 'session_id' => sid)).to eq([])
  end
end
