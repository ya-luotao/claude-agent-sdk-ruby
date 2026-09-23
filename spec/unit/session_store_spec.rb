# frozen_string_literal: true

require 'spec_helper'
require 'claude_agent_sdk/testing/session_store_conformance'

RSpec.describe ClaudeAgentSDK::InMemorySessionStore do
  it 'passes the full SessionStore conformance suite' do
    expect do
      ClaudeAgentSDK::Testing.run_session_store_conformance(-> { described_class.new })
    end.not_to raise_error
  end

  describe 'conformance suite coverage' do
    [
      {},
      { 'custom_title' => 'first' },
      { 'created_at' => 1_704_067_202_000 },
      { 'first_prompt' => 'later prompt' }
    ].each do |bad_data|
      it "rejects incorrect persisted summary content: #{bad_data.inspect}" do
        broken = Class.new(described_class) do
          define_method(:list_session_summaries) do |project|
            super(project).map do |summary|
              data = bad_data.empty? ? {} : summary['data'].merge(bad_data)
              summary.merge('data' => data)
            end
          end
        end

        expect do
          ClaudeAgentSDK::Testing.run_session_store_conformance(-> { broken.new })
        end.to raise_error(ClaudeAgentSDK::Testing::ConformanceError, /summary data/)
      end
    end

    # M18: the naive one-row-per-append list_sessions previously passed all
    # contracts (only list_session_summaries was guarded against it) and then
    # showed N duplicate sessions in pickers.
    it 'contract 16 catches a one-row-per-append list_sessions' do
      naive = Class.new(described_class) do
        def append(key, entries)
          super
          return if entries.nil? || entries.empty?
          return if key['subpath'] && !key['subpath'].empty?

          (@append_log ||= []) << { 'project_key' => key['project_key'], 'session_id' => key['session_id'] }
        end

        def list_sessions(project_key)
          mtimes = super.to_h { |r| [r['session_id'], r['mtime']] }
          (@append_log || []).filter_map do |k|
            next unless k['project_key'] == project_key

            { 'session_id' => k['session_id'], 'mtime' => mtimes[k['session_id']] }
          end
        end
      end

      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { naive.new })
      end.to raise_error(ClaudeAgentSDK::Testing::ConformanceError, /one row per session after multiple appends/)
    end

    # Improvement 2: append([]) must not create a phantom key (documented on
    # InMemorySessionStore, previously never asserted).
    it 'contract 4 catches a store that creates phantom keys on append([])' do
      phantomizing = Class.new(described_class) do
        def append(key, entries)
          if (entries || []).empty?
            (@phantoms ||= []) << key
            return
          end
          super
        end

        def list_sessions(project_key)
          super + (@phantoms || []).select { |k| k['project_key'] == project_key }
                                   .map { |k| { 'session_id' => k['session_id'], 'mtime' => 2**41 } }
        end
      end

      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { phantomizing.new })
      end.to raise_error(ClaudeAgentSDK::Testing::ConformanceError, /phantom session/)
    end

    # P3: the uuid-dedupe recommendation is advisory ("should"), so it is
    # opt-in — off by default (the reference adapters deliberately skip it).
    it 'check_uuid_dedupe is off by default and flags a non-deduping store when enabled' do
      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { described_class.new })
      end.not_to raise_error

      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { described_class.new }, check_uuid_dedupe: true)
      end.to raise_error(ClaudeAgentSDK::Testing::ConformanceError, /dedupe by entry uuid/)
    end

    it 'check_uuid_dedupe passes for a deduping adapter' do
      deduping = Class.new(described_class) do
        def append(key, entries)
          existing = (load(key) || []).filter_map { |e| e['uuid'] }
          super(key, entries.reject { |e| e['uuid'] && existing.include?(e['uuid']) })
        end
      end

      expect do
        ClaudeAgentSDK::Testing.run_session_store_conformance(-> { deduping.new }, check_uuid_dedupe: true)
      end.not_to raise_error
    end
  end

  describe 'test helpers' do
    let(:store) { described_class.new }
    let(:key) { { 'project_key' => 'proj', 'session_id' => 'sess' } }

    it 'snapshots nested append input and mutable session key strings' do
      input_key = key.transform_values(&:dup)
      entries = [{ 'type' => 'user', 'customTitle' => +'Original',
                   'message' => { 'content' => [{ 'type' => 'text', 'text' => +'Hello' }] } }]
      store.append(input_key, entries)
      mtime = store.list_sessions('proj').first['mtime']
      entries.first['customTitle'].replace('Changed')
      entries.first['message']['content'].first['text'].replace('Changed')
      entries.first['message']['content'] << { 'type' => 'text', 'text' => 'Extra' }
      input_key.each_value { |value| value.replace('changed-key') }

      expect(store.load(key)).to eq([{ 'type' => 'user', 'customTitle' => 'Original',
                                       'message' => { 'content' => [{ 'type' => 'text', 'text' => 'Hello' }] } }])
      expect(store.list_session_summaries('proj').first['data']['custom_title']).to eq('Original')
      expect(store.list_sessions('proj').first['mtime']).to eq(mtime)
      store.append(key, [{ 'type' => 'assistant' }])
      expect(store.list_session_summaries('proj').length).to eq(1)
    end

    %i[load get_entries].each do |method|
      it "detaches nested JSON values returned by #{method}" do
        store.append(key, [{ 'type' => 'user', 'message' => { 'content' => [+'Hello', nil, true, 3] } }])
        mtime = store.list_sessions('proj').first['mtime']
        result = store.public_send(method, key)
        result.first['message']['content'].first.replace('Changed')
        result.first['message']['content'] << false

        expect(store.load(key)).to eq([{ 'type' => 'user', 'message' => { 'content' => ['Hello', nil, true, 3] } }])
        expect(store.list_sessions('proj').first['mtime']).to eq(mtime)
      end
    end

    it 'detaches summary strings, including its session id, from the transcript and index' do
      store.append(key.transform_values(&:dup), [{ 'type' => 'user', 'customTitle' => +'Original' }])
      mtime = store.list_sessions('proj').first['mtime']
      summary = store.list_session_summaries('proj').first
      summary['session_id'].replace('other-session')
      summary['data']['custom_title'].replace('Changed')

      expect(store.load(key).first['customTitle']).to eq('Original')
      expect(store.list_session_summaries('proj').first).to include('session_id' => 'sess', 'mtime' => mtime)
      expect(store.list_session_summaries('proj').first['data']['custom_title']).to eq('Original')
    end

    it 'get_entries returns a copy of stored entries (empty when absent)' do
      expect(store.get_entries(key)).to eq([])
      store.append(key, [{ 'type' => 'user', 'uuid' => 'a' }])
      entries = store.get_entries(key)
      expect(entries).to eq([{ 'type' => 'user', 'uuid' => 'a' }])
      entries << { 'type' => 'mutate' }
      expect(store.get_entries(key).length).to eq(1) # returned copy is detached
    end

    it 'size counts only main transcripts' do
      store.append(key, [{ 'type' => 'user' }])
      store.append(key.merge('subpath' => 'subagents/agent-1'), [{ 'type' => 'user' }])
      store.append({ 'project_key' => 'proj', 'session_id' => 'other' }, [{ 'type' => 'user' }])
      expect(store.size).to eq(2)
    end

    it 'clear resets all state' do
      store.append(key, [{ 'type' => 'user' }])
      store.clear
      expect(store.size).to eq(0)
      expect(store.load(key)).to be_nil
    end

    it 'monotonic mtimes: back-to-back appends produce strictly increasing mtimes' do
      store.append({ 'project_key' => 'p', 'session_id' => 'a' }, [{ 'type' => 'user' }])
      store.append({ 'project_key' => 'p', 'session_id' => 'b' }, [{ 'type' => 'user' }])
      # Other specs order sessions by append order on the strength of this
      # guarantee instead of sleeping between appends.
      mtimes = store.list_sessions('p').to_h { |s| [s['session_id'], s['mtime']] }
      expect(mtimes['b']).to be > mtimes['a']
    end

    it 'list_session_summaries returns copies; mutating one does not corrupt the store' do
      store.append(key, [{ 'type' => 'user', 'uuid' => 'a', 'timestamp' => '2024-01-01T00:00:00.000Z',
                           'customTitle' => 'Original' }])
      summary = store.list_session_summaries('proj').first
      expect(summary['data']['custom_title']).to eq('Original')
      summary['data']['custom_title'] = 'Mutated'
      expect(store.list_session_summaries('proj').first['data']['custom_title']).to eq('Original')
    end
  end
end

RSpec.describe ClaudeAgentSDK::SessionStore do
  describe '.implements?' do
    let(:full) { ClaudeAgentSDK::InMemorySessionStore.new }
    let(:minimal) do
      Class.new(described_class) do
        def append(_key, _entries); end
        def load(_key); end
      end.new
    end
    let(:base) { described_class.new }

    it 'is true for an overridden optional method' do
      expect(described_class.implements?(full, :delete)).to be true
      expect(described_class.implements?(full, :list_subkeys)).to be true
    end

    it 'is false for an inherited (unoverridden) optional method' do
      expect(described_class.implements?(minimal, :delete)).to be false
      expect(described_class.implements?(base, :list_sessions)).to be false
    end

    it 'is false when the store does not respond to the method at all' do
      expect(described_class.implements?(Object.new, :delete)).to be false
    end

    it 'is true for a duck-typed adapter that does not subclass SessionStore' do
      duck = Class.new do
        def append(_key, _entries); end
        def load(_key); end
        def delete(_key); end
      end.new
      expect(described_class.implements?(duck, :delete)).to be true
      expect(described_class.implements?(duck, :list_sessions)).to be false
    end
  end

  describe 'required methods on the base class' do
    it 'raise NotImplementedError' do
      base = described_class.new
      expect { base.append({}, []) }.to raise_error(NotImplementedError)
      expect { base.load({}) }.to raise_error(NotImplementedError)
    end
  end
end

RSpec.describe ClaudeAgentSDK::SessionStores do
  describe '.file_path_to_session_key' do
    let(:base) { '/home/u/.claude/projects' }

    it 'maps a main transcript path' do
      key = described_class.file_path_to_session_key("#{base}/proj-key/abc-123.jsonl", base)
      expect(key).to eq('project_key' => 'proj-key', 'session_id' => 'abc-123')
    end

    it 'maps a subagent transcript path with a /-joined subpath' do
      key = described_class.file_path_to_session_key("#{base}/proj-key/sess-id/subagents/agent-1.jsonl", base)
      expect(key).to eq('project_key' => 'proj-key', 'session_id' => 'sess-id', 'subpath' => 'subagents/agent-1')
    end

    it 'returns nil for a path not under projects_dir' do
      expect(described_class.file_path_to_session_key('/elsewhere/x.jsonl', base)).to be_nil
    end

    it 'returns nil for a nil or empty file_path instead of raising' do
      # A malformed transcript_mirror frame (missing filePath) must not raise
      # TypeError out of do_flush and drop the whole coalesced drain batch.
      expect(described_class.file_path_to_session_key(nil, base)).to be_nil
      expect(described_class.file_path_to_session_key('', base)).to be_nil
    end

    it 'returns nil for a file directly under projects_dir (no project_key dir)' do
      expect(described_class.file_path_to_session_key("#{base}/loose.jsonl", base)).to be_nil
    end

    it 'returns nil for an unrecognized 3-component shape' do
      expect(described_class.file_path_to_session_key("#{base}/pk/sess/foo.jsonl", base)).to be_nil
    end

    it 'maps a project_key whose name begins with ".." (segment check, not string prefix)' do
      # Regression: a leading-".." *string* check would drop this valid frame.
      # The guard compares the first path *segment* against "..", so "..foo" maps.
      key = described_class.file_path_to_session_key("#{base}/..foo/abc-123.jsonl", base)
      expect(key).to eq('project_key' => '..foo', 'session_id' => 'abc-123')
    end

    it 'still rejects a genuine ".." traversal segment' do
      expect(described_class.file_path_to_session_key('/home/u/.claude/other/x.jsonl', base)).to be_nil
    end
  end

  describe '.validate_session_store_options' do
    def options(**kwargs)
      ClaudeAgentSDK::ClaudeAgentOptions.new(**kwargs)
    end

    let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }

    it 'is a no-op when no session_store is set' do
      expect { described_class.validate_session_store_options(options) }.not_to raise_error
    end

    it 'accepts a valid store with default options' do
      expect { described_class.validate_session_store_options(options(session_store: store)) }.not_to raise_error
    end

    it 'raises for an invalid session_store_flush' do
      expect do
        described_class.validate_session_store_options(options(session_store: store, session_store_flush: 'sometimes'))
      end.to raise_error(ArgumentError, /invalid session_store_flush/)
    end

    it 'raises when the store does not implement the required #append/#load' do
      # Regression: a subclass inheriting the base stubs only failed at first
      # use, with NotImplementedError — a ScriptError that escapes every
      # rescue StandardError layer and kills the reactor.
      load_only = Class.new(ClaudeAgentSDK::SessionStore) do
        def load(_key); end
      end.new
      expect do
        described_class.validate_session_store_options(options(session_store: load_only))
      end.to raise_error(ArgumentError, /must implement #append/)

      append_only = Class.new(ClaudeAgentSDK::SessionStore) do
        def append(_key, _entries); end
      end.new
      expect do
        described_class.validate_session_store_options(options(session_store: append_only))
      end.to raise_error(ArgumentError, /must implement #load/)
    end

    it 'raises when continue_conversation is set without resume and the store lacks list_sessions' do
      minimal = Class.new(ClaudeAgentSDK::SessionStore) do
        def append(_key, _entries); end
        def load(_key); end
      end.new
      expect do
        described_class.validate_session_store_options(options(session_store: minimal, continue_conversation: true))
      end.to raise_error(ArgumentError, /list_sessions/)
    end

    it 'allows continue_conversation with a minimal store when resume is set (resume wins)' do
      minimal = Class.new(ClaudeAgentSDK::SessionStore) do
        def append(_key, _entries); end
        def load(_key); end
      end.new
      expect do
        described_class.validate_session_store_options(
          options(session_store: minimal, continue_conversation: true, resume: 'abc')
        )
      end.not_to raise_error
    end

    it 'raises when combined with enable_file_checkpointing' do
      expect do
        described_class.validate_session_store_options(options(session_store: store, enable_file_checkpointing: true))
      end.to raise_error(ArgumentError, /enable_file_checkpointing/)
    end
  end

  describe '.projects_dir' do
    around do |example|
      previous = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
      example.run
    ensure
      previous.nil? ? ENV.delete('CLAUDE_CONFIG_DIR') : (ENV['CLAUDE_CONFIG_DIR'] = previous)
    end

    it 'honors a non-empty options.env CLAUDE_CONFIG_DIR override' do
      ENV['CLAUDE_CONFIG_DIR'] = '/ambient'
      expect(described_class.projects_dir('CLAUDE_CONFIG_DIR' => '/custom')).to eq('/custom/projects')
    end

    it 'maps an explicit nil override to the default config dir, not the parent ENV' do
      # The transport unsets the var for the child on an explicit nil, so the
      # CLI writes under ~/.claude — the parent's CLAUDE_CONFIG_DIR would point
      # the batcher at a dir the subprocess never writes to.
      ENV['CLAUDE_CONFIG_DIR'] = '/ambient'
      expect(described_class.projects_dir('CLAUDE_CONFIG_DIR' => nil))
        .to eq(File.join(File.expand_path('~/.claude'), 'projects'))
    end

    it 'maps an explicit empty-string override to the default config dir too' do
      ENV['CLAUDE_CONFIG_DIR'] = '/ambient'
      expect(described_class.projects_dir('CLAUDE_CONFIG_DIR' => ''))
        .to eq(File.join(File.expand_path('~/.claude'), 'projects'))
    end

    it 'falls back to the parent ENV when options.env has no CLAUDE_CONFIG_DIR key' do
      ENV['CLAUDE_CONFIG_DIR'] = '/ambient'
      expect(described_class.projects_dir('OTHER' => 'x')).to eq('/ambient/projects')
      expect(described_class.projects_dir(nil)).to eq('/ambient/projects')
    end
  end
end

RSpec.describe 'ClaudeAgentSDK.project_key_for_directory' do
  it 'derives a sanitized key for an explicit directory' do
    Dir.mktmpdir do |dir|
      key = ClaudeAgentSDK.project_key_for_directory(dir)
      expect(key).to be_a(String)
      expect(key).to match(/\A[A-Za-z0-9-]+\z/) # non-alphanumerics sanitized to hyphens
      # Deterministic for the same directory.
      expect(ClaudeAgentSDK.project_key_for_directory(dir)).to eq(key)
    end
  end

  it 'defaults to the current working directory when nil' do
    expect(ClaudeAgentSDK.project_key_for_directory).to eq(ClaudeAgentSDK.project_key_for_directory(Dir.pwd))
  end
end
