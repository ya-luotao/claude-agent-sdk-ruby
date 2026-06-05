# frozen_string_literal: true

require 'spec_helper'
require 'claude_agent_sdk/testing/session_store_conformance'

RSpec.describe ClaudeAgentSDK::InMemorySessionStore do
  it 'passes the full SessionStore conformance suite' do
    expect do
      ClaudeAgentSDK::Testing.run_session_store_conformance(-> { described_class.new })
    end.not_to raise_error
  end

  describe 'test helpers' do
    let(:store) { described_class.new }
    let(:key) { { 'project_key' => 'proj', 'session_id' => 'sess' } }

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
      mtimes = store.list_sessions('p').map { |s| s['mtime'] }
      expect(mtimes.uniq.length).to eq(2)
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
