# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'

# Store-backed read helpers: ClaudeAgentSDK.{list_sessions,get_session_info,
# get_session_messages,list_subagents,get_subagent_messages}_from_store.
RSpec.describe 'SessionStore-backed reads' do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:dir) { Dir.mktmpdir }
  let(:project_key) { ClaudeAgentSDK.project_key_for_directory(dir) }
  let(:sid1) { SecureRandom.uuid }
  let(:sid2) { SecureRandom.uuid }

  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def user_entry(session_id, text, timestamp)
    { 'type' => 'user', 'uuid' => SecureRandom.uuid, 'timestamp' => timestamp,
      'sessionId' => session_id, 'message' => { 'content' => text } }
  end

  def seed_two_sessions
    store.append({ 'project_key' => project_key, 'session_id' => sid1 },
                 [user_entry(sid1, 'First prompt', '2024-01-01T00:00:00.000Z')])
    sleep 0.002 # ensure distinct, ordered mtimes
    store.append({ 'project_key' => project_key, 'session_id' => sid2 },
                 [user_entry(sid2, 'Second prompt', '2024-01-02T00:00:00.000Z')])
  end

  describe '.list_sessions_from_store' do
    it 'returns SDKSessionInfo sorted by last_modified descending (summary fast-path)' do
      seed_two_sessions
      infos = ClaudeAgentSDK.list_sessions_from_store(session_store: store, directory: dir)
      expect(infos.map(&:session_id)).to eq([sid2, sid1])
      expect(infos.map(&:summary)).to eq(['Second prompt', 'First prompt'])
      expect(infos).to all(be_a(ClaudeAgentSDK::SDKSessionInfo))
    end

    it 'honors limit and offset' do
      seed_two_sessions
      expect(ClaudeAgentSDK.list_sessions_from_store(session_store: store, directory: dir, limit: 1).map(&:session_id))
        .to eq([sid2])
      expect(ClaudeAgentSDK.list_sessions_from_store(session_store: store, directory: dir, offset: 1).map(&:session_id))
        .to eq([sid1])
    end

    it 'excludes sidechain sessions' do
      store.append({ 'project_key' => project_key, 'session_id' => sid1 },
                   [user_entry(sid1, 'visible', '2024-01-01T00:00:00.000Z')])
      store.append({ 'project_key' => project_key, 'session_id' => sid2 },
                   [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'isSidechain' => true,
                      'timestamp' => '2024-01-02T00:00:00.000Z', 'message' => { 'content' => 'hidden' } }])
      infos = ClaudeAgentSDK.list_sessions_from_store(session_store: store, directory: dir)
      expect(infos.map(&:session_id)).to eq([sid1])
    end

    it 'falls back to list_sessions + load when the store lacks summaries' do
      list_only = list_only_store
      list_only.append({ 'project_key' => project_key, 'session_id' => sid1 },
                       [user_entry(sid1, 'Only prompt', '2024-01-01T00:00:00.000Z')])
      infos = ClaudeAgentSDK.list_sessions_from_store(session_store: list_only, directory: dir)
      expect(infos.map(&:summary)).to eq(['Only prompt'])
    end

    it 'raises when the store implements neither summaries nor list_sessions' do
      minimal = Class.new(ClaudeAgentSDK::SessionStore) do
        def append(_key, _entries); end
        def load(_key); end
      end.new
      expect { ClaudeAgentSDK.list_sessions_from_store(session_store: minimal, directory: dir) }
        .to raise_error(ArgumentError, /neither/)
    end

    it 'coerces a nil adapter mtime instead of crashing the summary fast-path' do
      nm = nil_mtime_store
      nm.append({ 'project_key' => project_key, 'session_id' => sid1 },
                [user_entry(sid1, 'Prompt', '2024-01-01T00:00:00.000Z')])
      infos = nil
      expect { infos = ClaudeAgentSDK.list_sessions_from_store(session_store: nm, directory: dir) }
        .not_to raise_error
      expect(infos.map(&:session_id)).to eq([sid1])
    end
  end

  describe '.get_session_info_from_store' do
    it 'returns info derived from store entries' do
      seed_two_sessions
      info = ClaudeAgentSDK.get_session_info_from_store(session_store: store, session_id: sid1, directory: dir)
      expect(info.summary).to eq('First prompt')
      expect(info.created_at).to eq(Time.iso8601('2024-01-01T00:00:00.000Z').to_f.*(1000).to_i)
    end

    it 'returns nil for an invalid UUID or unknown session' do
      expect(ClaudeAgentSDK.get_session_info_from_store(session_store: store, session_id: 'nope', directory: dir))
        .to be_nil
      expect(ClaudeAgentSDK.get_session_info_from_store(session_store: store, session_id: sid1, directory: dir))
        .to be_nil
    end
  end

  describe '.get_session_messages_from_store' do
    it 'returns the conversation messages' do
      seed_two_sessions
      msgs = ClaudeAgentSDK.get_session_messages_from_store(session_store: store, session_id: sid2, directory: dir)
      expect(msgs.length).to eq(1)
      expect(msgs.first).to be_a(ClaudeAgentSDK::SessionMessage)
      expect(msgs.first.text).to eq('Second prompt')
    end

    it 'returns [] for an invalid UUID or unknown session' do
      expect(ClaudeAgentSDK.get_session_messages_from_store(session_store: store, session_id: 'nope', directory: dir))
        .to eq([])
      expect(ClaudeAgentSDK.get_session_messages_from_store(session_store: store, session_id: sid1, directory: dir))
        .to eq([])
    end
  end

  describe '.list_subagents_from_store / .get_subagent_messages_from_store' do
    before do
      store.append({ 'project_key' => project_key, 'session_id' => sid2 },
                   [user_entry(sid2, 'main', '2024-01-02T00:00:00.000Z')])
      store.append({ 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/agent-abc' },
                   [{ 'type' => 'agent_metadata', 'agentId' => 'abc' },
                    user_entry(sid2, 'Subagent hi', '2024-01-02T00:00:01.000Z')])
    end

    it 'lists subagent IDs' do
      expect(ClaudeAgentSDK.list_subagents_from_store(session_store: store, session_id: sid2, directory: dir))
        .to eq(['abc'])
    end

    it 'reads subagent messages, dropping synthetic agent_metadata entries' do
      msgs = ClaudeAgentSDK.get_subagent_messages_from_store(
        session_store: store, session_id: sid2, agent_id: 'abc', directory: dir
      )
      expect(msgs.length).to eq(1)
      expect(msgs.first.text).to eq('Subagent hi')
    end

    it 'resolves a nested subagents/workflows/<run>/agent-<id> path' do
      store.append(
        { 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/workflows/run1/agent-nested' },
        [user_entry(sid2, 'Nested agent', '2024-01-02T00:00:02.000Z')]
      )
      msgs = ClaudeAgentSDK.get_subagent_messages_from_store(
        session_store: store, session_id: sid2, agent_id: 'nested', directory: dir
      )
      expect(msgs.first.text).to eq('Nested agent')
    end

    it 'raises from list_subagents_from_store when the store lacks list_subkeys' do
      list_only = list_only_store
      expect { ClaudeAgentSDK.list_subagents_from_store(session_store: list_only, session_id: sid2, directory: dir) }
        .to raise_error(ArgumentError, /list_subkeys/)
    end

    it 'does not crash when list_subkeys returns nil (non-conformant adapter)' do
      ns = nil_subkeys_store
      expect(ClaudeAgentSDK.list_subagents_from_store(session_store: ns, session_id: sid2, directory: dir)).to eq([])
      expect(ClaudeAgentSDK.get_subagent_messages_from_store(
               session_store: ns, session_id: sid2, agent_id: 'abc', directory: dir
             )).to eq([])
    end
  end

  # A store implementing only append/load/list_sessions (no summaries/subkeys),
  # to exercise the slow path and the missing-list_subkeys guard.
  def list_only_store
    Class.new(ClaudeAgentSDK::SessionStore) do
      def initialize
        super
        @data = {}
      end

      def append(key, entries)
        (@data[[key['project_key'], key['session_id']]] ||= []).concat(entries)
      end

      def load(key) = @data[[key['project_key'], key['session_id']]]&.dup

      def list_sessions(project_key)
        @data.keys.select { |pk, _| pk == project_key }.map { |_, sid| { 'session_id' => sid, 'mtime' => 1 } }
      end
    end.new
  end

  # A non-conformant store whose summaries/list_sessions report a nil mtime
  # (e.g. a NULL JSONB column), to exercise the nil-mtime coercion. summaries
  # report nil while list_sessions reports a real mtime, so the staleness
  # comparison runs `nil < Integer` (which crashed before coercion).
  def nil_mtime_store
    Class.new(ClaudeAgentSDK::SessionStore) do
      def initialize
        super
        @data = {}
      end

      def append(key, entries)
        (@data[[key['project_key'], key['session_id']]] ||= []).concat(entries)
      end

      def load(key) = @data[[key['project_key'], key['session_id']]]&.dup

      def list_sessions(project_key)
        @data.keys.select { |pk, _| pk == project_key }
             .map { |_, sid| { 'session_id' => sid, 'mtime' => 1_700_000_000_000 } }
      end

      def list_session_summaries(project_key)
        @data.keys.select { |pk, _| pk == project_key }
             .map { |_, sid| { 'session_id' => sid, 'mtime' => nil, 'data' => {} } }
      end
    end.new
  end

  # A non-conformant store whose list_subkeys returns nil (rather than []).
  def nil_subkeys_store
    Class.new(ClaudeAgentSDK::SessionStore) do
      def append(_key, _entries); end
      def load(_key); end
      def list_subkeys(_key); end
    end.new
  end
end
