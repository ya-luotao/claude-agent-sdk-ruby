# frozen_string_literal: true

require 'spec_helper'

# Store-backed mutation helpers (*_via_store), the counterparts to the disk-path
# rename/tag/delete/fork in session_mutations_spec.rb. Exercised against the
# InMemorySessionStore reference adapter.
RSpec.describe 'SessionStore-backed mutations' do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:project_key) { ClaudeAgentSDK.project_key_for_directory('.') }
  let(:session_id) { '11111111-1111-4111-8111-111111111111' }
  let(:key) { { 'project_key' => project_key, 'session_id' => session_id } }

  def seed_transcript(extra = [])
    store.append(key, [
      { 'type' => 'user', 'uuid' => 'u1', 'sessionId' => session_id,
        'timestamp' => '2026-01-01T00:00:00.000Z',
        'message' => { 'role' => 'user', 'content' => 'hello world' } },
      { 'type' => 'assistant', 'uuid' => 'a1', 'parentUuid' => 'u1', 'sessionId' => session_id,
        'timestamp' => '2026-01-01T00:00:01.000Z',
        'message' => { 'role' => 'assistant', 'content' => 'hi' } }
    ] + extra)
  end

  describe '.rename_session_via_store' do
    it 'appends a custom-title entry carrying a fresh uuid + timestamp' do
      seed_transcript
      ClaudeAgentSDK.rename_session_via_store(session_store: store, session_id: session_id, title: '  New Title  ')
      last = store.get_entries(key).last
      expect(last['type']).to eq('custom-title')
      expect(last['customTitle']).to eq('New Title')
      expect(last['sessionId']).to eq(session_id)
      expect(last['uuid']).to match(ClaudeAgentSDK::Sessions::UUID_RE)
      expect(last['timestamp']).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it 'rejects an invalid UUID and an empty title' do
      expect { ClaudeAgentSDK.rename_session_via_store(session_store: store, session_id: 'nope', title: 'x') }
        .to raise_error(ArgumentError)
      expect { ClaudeAgentSDK.rename_session_via_store(session_store: store, session_id: session_id, title: '   ') }
        .to raise_error(ArgumentError)
    end
  end

  describe '.tag_session_via_store' do
    it 'appends a tag entry with uuid + timestamp' do
      seed_transcript
      ClaudeAgentSDK.tag_session_via_store(session_store: store, session_id: session_id, tag: 'important')
      last = store.get_entries(key).last
      expect(last['type']).to eq('tag')
      expect(last['tag']).to eq('important')
      expect(last['uuid']).to match(ClaudeAgentSDK::Sessions::UUID_RE)
    end

    it 'writes an empty-string tag when clearing with nil' do
      seed_transcript
      ClaudeAgentSDK.tag_session_via_store(session_store: store, session_id: session_id, tag: nil)
      expect(store.get_entries(key).last['tag']).to eq('')
    end

    it 'rejects a tag that becomes empty after sanitization' do
      expect { ClaudeAgentSDK.tag_session_via_store(session_store: store, session_id: session_id, tag: "\u200b\u200c\u200d") }
        .to raise_error(ArgumentError)
    end
  end

  describe '.delete_session_via_store' do
    it 'cascades to subkeys on a store that implements #delete' do
      seed_transcript
      store.append(key.merge('subpath' => 'subagents/agent-1'), [{ 'type' => 'user', 'uuid' => 's1' }])
      ClaudeAgentSDK.delete_session_via_store(session_store: store, session_id: session_id)
      expect(store.load(key)).to be_nil
      expect(store.load(key.merge('subpath' => 'subagents/agent-1'))).to be_nil
    end

    it 'is a no-op on a WORM store that does not implement #delete' do
      worm = Class.new(ClaudeAgentSDK::SessionStore) do
        def initialize
          super
          @h = {}
        end

        def append(key, entries)
          (@h[key.values_at('project_key', 'session_id').join('/')] ||= []).concat(entries)
        end

        def load(key)
          @h[key.values_at('project_key', 'session_id').join('/')]
        end
      end.new
      worm.append(key, [{ 'type' => 'user', 'uuid' => 'x' }])
      expect { ClaudeAgentSDK.delete_session_via_store(session_store: worm, session_id: session_id) }
        .not_to raise_error
      expect(worm.load(key)).not_to be_nil
    end

    it 'rejects an invalid UUID' do
      expect { ClaudeAgentSDK.delete_session_via_store(session_store: store, session_id: 'bad') }
        .to raise_error(ArgumentError)
    end
  end

  describe '.fork_session_via_store' do
    it 'remaps UUIDs, stamps forkedFrom, and writes under a new session key' do
      seed_transcript
      result = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id)
      forked_id = result.session_id
      expect(forked_id).to match(ClaudeAgentSDK::Sessions::UUID_RE)
      expect(forked_id).not_to eq(session_id)

      forked = store.load('project_key' => project_key, 'session_id' => forked_id)
      user = forked.find { |e| e['type'] == 'user' }
      expect(user['uuid']).not_to eq('u1')
      expect(user['sessionId']).to eq(forked_id)
      expect(user['forkedFrom']).to eq({ 'sessionId' => session_id, 'messageUuid' => 'u1' })
    end

    it 'derives the fork title from the source customTitle (P0-1: scans raw entries)' do
      seed_transcript([{ 'type' => 'custom-title', 'customTitle' => 'Source Title', 'sessionId' => session_id,
                         'uuid' => 'ct1', 'timestamp' => '2026-01-01T00:00:02.000Z' }])
      result = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id)
      forked = store.load('project_key' => project_key, 'session_id' => result.session_id)
      ct = forked.reverse.find { |e| e['type'] == 'custom-title' }
      expect(ct['customTitle']).to eq('Source Title (fork)')
    end

    it 'falls back to the source aiTitle when there is no customTitle' do
      seed_transcript([{ 'type' => 'aiTitle', 'aiTitle' => 'AI Derived', 'sessionId' => session_id,
                         'uuid' => 'ai1', 'timestamp' => '2026-01-01T00:00:02.000Z' }])
      result = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id)
      forked = store.load('project_key' => project_key, 'session_id' => result.session_id)
      ct = forked.reverse.find { |e| e['type'] == 'custom-title' }
      expect(ct['customTitle']).to eq('AI Derived (fork)')
    end

    it "falls back to 'Forked session (fork)' when no title or prompt is extractable" do
      # Regression: extract_first_prompt_from_head returns '' (truthy) for a
      # session with no qualifying prompt; without empty->nil normalization the
      # fork was titled literally " (fork)".
      store.append(key, [
                     { 'type' => 'assistant', 'uuid' => 'a1', 'sessionId' => session_id,
                       'timestamp' => '2026-01-01T00:00:01.000Z',
                       'message' => { 'role' => 'assistant', 'content' => 'hi' } }
                   ])
      result = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id)
      forked = store.load('project_key' => project_key, 'session_id' => result.session_id)
      ct = forked.reverse.find { |e| e['type'] == 'custom-title' }
      expect(ct['customTitle']).to eq('Forked session (fork)')
    end

    it 'honors an explicit title without the (fork) suffix' do
      seed_transcript
      result = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id, title: 'Explicit')
      forked = store.load('project_key' => project_key, 'session_id' => result.session_id)
      expect(forked.reverse.find { |e| e['type'] == 'custom-title' }['customTitle']).to eq('Explicit')
    end

    it 'truncates at up_to_message_id (inclusive)' do
      # up_to_message_id must be a UUID (matches the disk path); seed transcript
      # entries with UUID-shaped message uuids so we can slice at one.
      cut = '22222222-2222-4222-8222-222222222222'
      store.append(key, [
                     { 'type' => 'user', 'uuid' => '33333333-3333-4333-8333-333333333333', 'sessionId' => session_id,
                       'timestamp' => '2026-01-01T00:00:00.000Z',
                       'message' => { 'role' => 'user', 'content' => 'first' } },
                     { 'type' => 'assistant', 'uuid' => cut, 'sessionId' => session_id,
                       'timestamp' => '2026-01-01T00:00:01.000Z',
                       'message' => { 'role' => 'assistant', 'content' => 'mid' } },
                     { 'type' => 'user', 'uuid' => '44444444-4444-4444-8444-444444444444', 'sessionId' => session_id,
                       'timestamp' => '2026-01-01T00:00:02.000Z',
                       'message' => { 'role' => 'user', 'content' => 'after cutoff' } }
                   ])
      result = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id, up_to_message_id: cut)
      forked = store.load('project_key' => project_key, 'session_id' => result.session_id)
      transcript = forked.select { |e| %w[user assistant].include?(e['type']) }
      expect(transcript.size).to eq(2) # first + cut, not the entry after the cutoff
    end

    it 'stamps a fresh uuid + timestamp on the content-replacement trailer' do
      seed_transcript([{ 'type' => 'content-replacement', 'sessionId' => session_id,
                         'replacements' => [{ 'foo' => 'bar' }] }])
      result = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id)
      forked = store.load('project_key' => project_key, 'session_id' => result.session_id)
      cr = forked.find { |e| e['type'] == 'content-replacement' }
      expect(cr['sessionId']).to eq(result.session_id)
      expect(cr['uuid']).to match(ClaudeAgentSDK::Sessions::UUID_RE)
      expect(cr['timestamp']).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it 'raises Errno::ENOENT for a session absent from the store' do
      expect { ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id) }
        .to raise_error(Errno::ENOENT)
    end

    it 'rejects invalid UUIDs' do
      expect { ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: 'bad') }
        .to raise_error(ArgumentError)
      seed_transcript
      expect { ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: session_id, up_to_message_id: 'bad') }
        .to raise_error(ArgumentError)
    end
  end
end
