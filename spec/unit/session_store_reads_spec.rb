# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'

# Store-backed reads: ClaudeAgentSDK.{list_sessions,get_session_info,
# get_session_messages,list_subagents,get_subagent_metadata,
# get_subagent_messages} with session_store:. The deprecated *_from_store
# twins are covered in sessions_api_deprecation_spec.rb.
RSpec.describe 'SessionStore-backed reads' do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:dir) { Dir.mktmpdir }
  let(:project_key) { ClaudeAgentSDK.project_key_for_directory(dir) }
  let(:sid1) { SecureRandom.uuid }
  let(:sid2) { SecureRandom.uuid }
  let(:sid_valid_old) { SecureRandom.uuid }
  let(:sid_valid_new) { SecureRandom.uuid }
  let(:sid_side_prefix) { 'side-' }

  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def user_entry(session_id, text, timestamp)
    { 'type' => 'user', 'uuid' => SecureRandom.uuid, 'timestamp' => timestamp,
      'sessionId' => session_id, 'message' => { 'content' => text } }
  end

  # No sleep between appends: InMemorySessionStore stamps strictly increasing
  # mtimes per append (asserted in session_store_spec), so append order IS
  # recency order regardless of clock resolution.
  def seed_two_sessions
    store.append({ 'project_key' => project_key, 'session_id' => sid1 },
                 [user_entry(sid1, 'First prompt', '2024-01-01T00:00:00.000Z')])
    store.append({ 'project_key' => project_key, 'session_id' => sid2 },
                 [user_entry(sid2, 'Second prompt', '2024-01-02T00:00:00.000Z')])
  end

  describe '.list_sessions with session_store:' do
    it 'returns SDKSessionInfo sorted by last_modified descending (summary fast-path)' do
      seed_two_sessions
      infos = ClaudeAgentSDK.list_sessions(session_store: store, directory: dir)
      expect(infos.map(&:session_id)).to eq([sid2, sid1])
      expect(infos.map(&:summary)).to eq(['Second prompt', 'First prompt'])
      expect(infos).to all(be_a(ClaudeAgentSDK::SDKSessionInfo))
    end

    it 'honors limit and offset' do
      seed_two_sessions
      expect(ClaudeAgentSDK.list_sessions(session_store: store, directory: dir, limit: 1).map(&:session_id))
        .to eq([sid2])
      expect(ClaudeAgentSDK.list_sessions(session_store: store, directory: dir, offset: 1).map(&:session_id))
        .to eq([sid1])
    end

    it 'treats limit: 0 as an empty page (parity with the disk and message readers)' do
      seed_two_sessions
      # Fast path (InMemory implements summaries).
      expect(ClaudeAgentSDK.list_sessions(session_store: store, directory: dir, limit: 0)).to eq([])
      # Slow path (list_sessions + load, no summaries).
      list_only = list_only_store
      list_only.append({ 'project_key' => project_key, 'session_id' => sid1 },
                       [user_entry(sid1, 'Only prompt', '2024-01-01T00:00:00.000Z')])
      expect(ClaudeAgentSDK.list_sessions(session_store: list_only, directory: dir, limit: 0)).to eq([])
    end

    it 'excludes sidechain sessions' do
      store.append({ 'project_key' => project_key, 'session_id' => sid1 },
                   [user_entry(sid1, 'visible', '2024-01-01T00:00:00.000Z')])
      store.append({ 'project_key' => project_key, 'session_id' => sid2 },
                   [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'isSidechain' => true,
                      'timestamp' => '2024-01-02T00:00:00.000Z', 'message' => { 'content' => 'hidden' } }])
      infos = ClaudeAgentSDK.list_sessions(session_store: store, directory: dir)
      expect(infos.map(&:session_id)).to eq([sid1])
    end

    it 'falls back to list_sessions + load when the store lacks summaries' do
      list_only = list_only_store
      list_only.append({ 'project_key' => project_key, 'session_id' => sid1 },
                       [user_entry(sid1, 'Only prompt', '2024-01-01T00:00:00.000Z')])
      infos = ClaudeAgentSDK.list_sessions(session_store: list_only, directory: dir)
      expect(infos.map(&:summary)).to eq(['Only prompt'])
    end

    it 'raises when the store implements neither summaries nor list_sessions' do
      minimal = Class.new(ClaudeAgentSDK::SessionStore) do
        def append(_key, _entries); end
        def load(_key); end
      end.new
      expect { ClaudeAgentSDK.list_sessions(session_store: minimal, directory: dir) }
        .to raise_error(ArgumentError, /neither/)
    end

    it 'coerces a nil adapter mtime instead of crashing the summary fast-path' do
      nm = nil_mtime_store
      nm.append({ 'project_key' => project_key, 'session_id' => sid1 },
                [user_entry(sid1, 'Prompt', '2024-01-01T00:00:00.000Z')])
      infos = nil
      expect { infos = ClaudeAgentSDK.list_sessions(session_store: nm, directory: dir) }
        .not_to raise_error
      expect(infos.map(&:session_id)).to eq([sid1])
    end

    it 'does not crash when list_session_summaries returns nil (non-conformant adapter)' do
      ns = nil_summaries_store
      ns.append({ 'project_key' => project_key, 'session_id' => sid1 },
                [user_entry(sid1, 'Prompt', '2024-01-01T00:00:00.000Z')])
      infos = nil
      expect { infos = ClaudeAgentSDK.list_sessions(session_store: ns, directory: dir) }
        .not_to raise_error
      expect(infos.map(&:session_id)).to eq([sid1]) # degrades to gap-fill via list_sessions
    end

    it 'returns a full page from the summary fast-path even when gap-fill placeholders drop' do
      # Regression: paginating placeholder slots BEFORE resolving them let
      # sidechain/no-summary sessions consume page capacity and then drop,
      # yielding short/empty pages. The two newest here are sidechain; with
      # limit:2 the fast path must skip them and still return 2 valid sessions.
      gf = gap_fill_store
      gf.append({ 'project_key' => project_key, 'session_id' => sid_valid_old },
                [user_entry(sid_valid_old, 'old', '2024-01-01T00:00:01.000Z')])
      gf.append({ 'project_key' => project_key, 'session_id' => sid_valid_new },
                [user_entry(sid_valid_new, 'new', '2024-01-01T00:00:02.000Z')])
      2.times do |i|
        gf.append({ 'project_key' => project_key, 'session_id' => "#{sid_side_prefix}#{i}" },
                  [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'isSidechain' => true,
                     'timestamp' => "2024-01-01T00:00:0#{3 + i}.000Z", 'message' => { 'content' => "s#{i}" } }])
      end

      infos = ClaudeAgentSDK.list_sessions(session_store: gf, directory: dir, limit: 2)
      expect(infos.map(&:session_id)).to eq([sid_valid_new, sid_valid_old]) # full page, sidechain skipped
    end

    it 'degrades one failing row to an empty summary instead of aborting the whole listing' do
      # A single session whose load raises must NOT fail list_sessions
      # (parity with the disk path's per-file rescue and Python's
      # gather(return_exceptions=True) P2-5 fix).
      bad = sid1
      good = sid2
      raising = Class.new(ClaudeAgentSDK::SessionStore) do
        def initialize(bad_sid)
          super()
          @bad = bad_sid
          @store = {}
          @clock = 1_700_000_000_000
        end

        def append(key, entries)
          @store[key['session_id']] ||= { mtime: 0, entries: [] }
          @store[key['session_id']][:entries].concat(entries)
          @store[key['session_id']][:mtime] = (@clock += 1)
        end

        def load(key)
          raise 'backend boom' if key['session_id'] == @bad

          @store.dig(key['session_id'], :entries)
        end

        def list_sessions(_project_key)
          @store.map { |sid, v| { 'session_id' => sid, 'mtime' => v[:mtime] } }
        end
      end.new(bad)

      raising.append({ 'project_key' => project_key, 'session_id' => good },
                     [user_entry(good, 'survivor', '2024-01-01T00:00:00.000Z')])
      raising.append({ 'project_key' => project_key, 'session_id' => bad },
                     [user_entry(bad, 'will fail', '2024-01-02T00:00:00.000Z')])

      infos = nil
      expect { infos = ClaudeAgentSDK.list_sessions(session_store: raising, directory: dir) }
        .not_to raise_error
      by_id = infos.to_h { |i| [i.session_id, i] }
      expect(by_id.keys).to contain_exactly(good, bad)
      expect(by_id[good].summary).to eq('survivor')
      expect(by_id[bad].summary).to eq('') # degraded row kept, empty summary
    end

    # Issue #66: adapters backed by SQL timestamps naturally report mtime as an
    # ISO-8601 String. `-String` is String#-@ (frozen-string dedup), so the
    # old sort silently ordered such listings OLDEST first, and mixed
    # Integer/String listings raised ArgumentError.
    describe 'adapter mtime coercion (issue #66)' do
      let(:iso_sids) { Array.new(3) { SecureRandom.uuid } }

      def seed_controlled(cstore, mtimes, summary_mtimes: {})
        mtimes.each do |sid, mtime|
          cstore.append({ 'project_key' => project_key, 'session_id' => sid },
                        [user_entry(sid, "prompt #{sid}", '2024-01-01T00:00:00.000Z')])
          cstore.listing_mtimes[sid] = mtime
        end
        summary_mtimes.each { |sid, mtime| cstore.summary_mtimes[sid] = mtime }
      end

      [false, true].each do |with_summaries|
        path = with_summaries ? 'summary fast path' : 'list_sessions slow path'

        it "orders ISO-8601 String mtimes newest first on the #{path}" do
          cstore = controlled_mtime_store(with_summaries: with_summaries)
          oldest, middle, newest = iso_sids
          mtimes = { middle => '2024-06-01T00:00:00.000Z', oldest => '2024-01-01T00:00:00.000Z',
                     newest => '2024-12-01T00:00:00.000Z' }
          seed_controlled(cstore, mtimes, summary_mtimes: with_summaries ? mtimes : {})

          infos = ClaudeAgentSDK.list_sessions(session_store: cstore, directory: dir)
          expect(infos.map(&:session_id)).to eq([newest, middle, oldest])
          # limit must cut the OLDEST, not the newest.
          expect(ClaudeAgentSDK.list_sessions(session_store: cstore, directory: dir, limit: 1)
                   .map(&:session_id)).to eq([newest])
        end

        it "orders mixed Integer/String mtimes chronologically on the #{path}" do
          cstore = controlled_mtime_store(with_summaries: with_summaries)
          oldest, middle, newest = iso_sids
          mtimes = { oldest => Time.iso8601('2024-01-01T00:00:00Z').to_i * 1000,
                     middle => '2024-06-01T00:00:00.000Z',
                     newest => (Time.iso8601('2024-12-01T00:00:00Z').to_i * 1000).to_s }
          seed_controlled(cstore, mtimes, summary_mtimes: with_summaries ? mtimes : {})

          infos = nil
          expect { infos = ClaudeAgentSDK.list_sessions(session_store: cstore, directory: dir) }
            .not_to raise_error
          expect(infos.map(&:session_id)).to eq([newest, middle, oldest])
        end
      end

      it 'compares an epoch-Integer sidecar against an ISO-String listing mtime for staleness' do
        cstore = controlled_mtime_store(with_summaries: true)
        stale, fresh = iso_sids
        seed_controlled(cstore,
                        { stale => '2024-06-01T00:00:00.000Z', fresh => '2024-03-01T00:00:00.000Z' },
                        summary_mtimes: { stale => Time.iso8601('2024-01-01T00:00:00Z').to_i * 1000,
                                          fresh => Time.iso8601('2024-03-01T00:00:00Z').to_i * 1000 })
        # A title appended after the stale sidecar was written: only a re-fold
        # from source (the stale path) can see it.
        cstore.frozen_summaries = true
        cstore.append({ 'project_key' => project_key, 'session_id' => stale },
                      [{ 'type' => 'custom-title', 'customTitle' => 'Renamed later' }])

        infos = nil
        expect { infos = ClaudeAgentSDK.list_sessions(session_store: cstore, directory: dir) }
          .not_to raise_error
        expect(infos.map(&:session_id)).to eq([stale, fresh])
        expect(infos.first.summary).to eq('Renamed later') # re-folded, not the stale sidecar
      end
    end

    # Issue #78: sort_by is not stable, so equal mtimes (coarse adapter clocks,
    # bulk imports) ordered arbitrarily between calls and offset/limit paging
    # could skip or repeat sessions. Ties break by session_id ascending.
    describe 'deterministic tiebreak for equal mtimes (issue #78)' do
      let(:tied_sids) { Array.new(5) { SecureRandom.uuid } }

      [false, true].each do |with_summaries|
        path = with_summaries ? 'summary fast path' : 'list_sessions slow path'

        it "pages equal-mtime sessions by session_id with no skips or repeats on the #{path}" do
          cstore = controlled_mtime_store(with_summaries: with_summaries)
          tied_sids.each do |sid|
            cstore.append({ 'project_key' => project_key, 'session_id' => sid },
                          [user_entry(sid, 'tied', '2024-01-01T00:00:00.000Z')])
            cstore.listing_mtimes[sid] = 1_700_000_000_000
            cstore.summary_mtimes[sid] = 1_700_000_000_000 if with_summaries
          end

          full1 = ClaudeAgentSDK.list_sessions(session_store: cstore, directory: dir).map(&:session_id)
          full2 = ClaudeAgentSDK.list_sessions(session_store: cstore, directory: dir).map(&:session_id)
          expect(full1).to eq(tied_sids.sort)
          expect(full2).to eq(full1) # stable across calls despite the adapter reordering its rows

          pages = [0, 2, 4].flat_map do |off|
            ClaudeAgentSDK.list_sessions(session_store: cstore, directory: dir, limit: 2, offset: off)
                          .map(&:session_id)
          end
          expect(pages).to eq(tied_sids.sort)
        end
      end

      it 'breaks ties after coercion, so equal instants in different shapes order by session_id' do
        cstore = controlled_mtime_store(with_summaries: false)
        a, b = tied_sids.first(2).sort
        ms = Time.iso8601('2024-01-01T00:00:00Z').to_i * 1000
        cstore.append({ 'project_key' => project_key, 'session_id' => b }, [user_entry(b, 'b', '2024-01-01T00:00:00Z')])
        cstore.append({ 'project_key' => project_key, 'session_id' => a }, [user_entry(a, 'a', '2024-01-01T00:00:00Z')])
        cstore.listing_mtimes[b] = ms
        cstore.listing_mtimes[a] = '2024-01-01T00:00:00.000Z'

        2.times do
          expect(ClaudeAgentSDK.list_sessions(session_store: cstore, directory: dir).map(&:session_id))
            .to eq([a, b])
        end
      end
    end

    # Issue #121 (1): #66 coerced adapter mtimes only for ordering, so an
    # adapter reporting ISO strings (SQL timestamps through JSON) or Time
    # objects (ActiveRecord updated_at) surfaced them verbatim where
    # SDKSessionInfo#last_modified promises epoch milliseconds.
    describe 'last_modified is epoch-ms Integer whatever the adapter mtime shape (issue #121)' do
      let(:shape_sids) { Array.new(4) { SecureRandom.uuid } }
      let(:ms) { Time.iso8601('2024-06-01T12:00:00Z').to_i * 1000 }

      [false, true].each do |with_summaries|
        path = with_summaries ? 'summary fast path' : 'list_sessions slow path'

        it "coerces ISO, numeric-String, Float and Time mtimes on the #{path}" do
          cstore = controlled_mtime_store(with_summaries: with_summaries)
          iso, numeric, float, time = shape_sids
          mtimes = { iso => '2024-06-01T12:00:00.000Z', numeric => ms.to_s, float => ms.to_f + 0.5,
                     time => Time.at(ms / 1000) }
          mtimes.each do |sid, mtime|
            cstore.append({ 'project_key' => project_key, 'session_id' => sid }, [user_entry(sid, 'p', '2024-01-01T00:00:00Z')])
            cstore.listing_mtimes[sid] = mtime
            cstore.summary_mtimes[sid] = mtime if with_summaries
          end

          infos = ClaudeAgentSDK.list_sessions_from_store(session_store: cstore, directory: dir)
          expect(infos.map(&:last_modified)).to all(be_an(Integer))
          expect(infos.to_h { |i| [i.session_id, i.last_modified] }).to eq(shape_sids.to_h { |sid| [sid, ms] })
        end
      end

      it 'coerces the mtime of a row degraded by a failing gap-fill load' do
        failing = Class.new(ClaudeAgentSDK::SessionStore) do
          def append(_key, _entries); end
          def load(_key) = raise('backend down')
        end.new
        sid = shape_sids.first
        failing.define_singleton_method(:list_sessions) { |_pk| [{ 'session_id' => sid, 'mtime' => '2024-06-01T12:00:00Z' }] }

        infos = nil
        expect { infos = ClaudeAgentSDK.list_sessions_from_store(session_store: failing, directory: dir) }
          .to output(/gap-fill load failed/).to_stderr
        expect(infos.map(&:last_modified)).to eq([ms])
      end

      it 'reads an unusable mtime as 0, the value it sorts by' do
        cstore = controlled_mtime_store(with_summaries: false)
        sid = shape_sids.first
        cstore.append({ 'project_key' => project_key, 'session_id' => sid }, [user_entry(sid, 'p', '2024-01-01T00:00:00Z')])
        cstore.listing_mtimes[sid] = 'not a time'
        expect(ClaudeAgentSDK.list_sessions_from_store(session_store: cstore, directory: dir).map(&:last_modified))
          .to eq([0])
      end
    end
  end

  describe '.get_session_info with session_store:' do
    it 'returns info derived from store entries' do
      seed_two_sessions
      info = ClaudeAgentSDK.get_session_info(session_store: store, session_id: sid1, directory: dir)
      expect(info.summary).to eq('First prompt')
      expect(info.created_at).to eq(Time.iso8601('2024-01-01T00:00:00.000Z').to_f.*(1000).to_i)
    end

    it 'returns nil for an invalid UUID or unknown session' do
      expect(ClaudeAgentSDK.get_session_info(session_store: store, session_id: 'nope', directory: dir))
        .to be_nil
      expect(ClaudeAgentSDK.get_session_info(session_store: store, session_id: sid1, directory: dir))
        .to be_nil
    end

    it 'does not crash on a non-String timestamp (e.g. an epoch integer) in an entry' do
      store.append({ 'project_key' => project_key, 'session_id' => sid1 },
                   [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'timestamp' => 1_700_000_000_000,
                      'sessionId' => sid1, 'message' => { 'content' => 'Hi' } }])
      info = nil
      expect do
        info = ClaudeAgentSDK.get_session_info(session_store: store, session_id: sid1, directory: dir)
      end.not_to raise_error
      expect(info.summary).to eq('Hi')
    end
  end

  describe '.get_session_messages with session_store:' do
    it 'returns the conversation messages' do
      seed_two_sessions
      msgs = ClaudeAgentSDK.get_session_messages(session_store: store, session_id: sid2, directory: dir)
      expect(msgs.length).to eq(1)
      expect(msgs.first).to be_a(ClaudeAgentSDK::SessionMessage)
      expect(msgs.first.text).to eq('Second prompt')
    end

    it 'returns [] for an invalid UUID or unknown session' do
      expect(ClaudeAgentSDK.get_session_messages(session_store: store, session_id: 'nope', directory: dir))
        .to eq([])
      expect(ClaudeAgentSDK.get_session_messages(session_store: store, session_id: sid1, directory: dir))
        .to eq([])
    end
  end

  describe '.list_subagents / .get_subagent_messages with session_store:' do
    # CLI-written subagent entries ALL carry isSidechain: true — fixtures must
    # too, or these specs pass against a pipeline that drops sidechain entries
    # (and therefore returns [] for every real subagent transcript).
    def subagent_entry(session_id, text, timestamp, **extra)
      user_entry(session_id, text, timestamp).merge('isSidechain' => true, **extra)
    end

    before do
      store.append({ 'project_key' => project_key, 'session_id' => sid2 },
                   [user_entry(sid2, 'main', '2024-01-02T00:00:00.000Z')])
      store.append({ 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/agent-abc' },
                   [{ 'type' => 'agent_metadata', 'agentId' => 'abc' },
                    subagent_entry(sid2, 'Subagent hi', '2024-01-02T00:00:01.000Z')])
    end

    it 'lists subagent IDs' do
      expect(ClaudeAgentSDK.list_subagents(session_store: store, session_id: sid2, directory: dir))
        .to eq(['abc'])
    end

    it 'reads the last metadata even before messages arrive and preserves future fields' do
      key = { 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/workflows/run-1/agent-meta' }
      latest = { 'type' => 'agent_metadata', 'agentType' => 'reviewer', 'toolUseId' => 'spawn-new',
                 'parentAgentId' => 'parent-2', 'spawnDepth' => 2, 'futureField' => false }
      store.append(key, [{ 'type' => 'agent_metadata', 'toolUseId' => 'spawn-old' }, latest])

      expect(ClaudeAgentSDK.get_subagent_metadata(
               session_store: store, session_id: sid2, agent_id: 'meta', directory: dir
             )).to eq('agentType' => 'reviewer', 'toolUseId' => 'spawn-new', 'parentAgentId' => 'parent-2',
                      'spawnDepth' => 2, 'futureField' => false)
      expect(store.load(key).last).to eq(latest) # do not mutate an adapter-owned entry
    end

    it 'prefers canonical metadata over a nested duplicate and scopes to the requested session' do
      key = { 'project_key' => project_key, 'session_id' => sid2 }
      store.append(key.merge('subpath' => 'subagents/workflows/run-1/agent-meta'),
                   [{ 'type' => 'agent_metadata', 'toolUseId' => 'nested' }])
      store.append(key.merge('subpath' => 'subagents/agent-meta'),
                   [{ 'type' => 'agent_metadata', 'toolUseId' => 'canonical' }])
      args = { session_store: store, session_id: sid2, agent_id: 'meta', directory: dir }
      expect(ClaudeAgentSDK.get_subagent_metadata(**args)).to eq('toolUseId' => 'canonical')
      expect(ClaudeAgentSDK.get_subagent_metadata(**args, session_id: sid1)).to be_nil
    end

    it 'falls back to the direct subpath without list_subkeys and propagates adapter errors' do
      adapter = double('load-only store')
      key = { 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/agent-meta' }
      allow(adapter).to receive(:load).with(key).and_return([{ 'type' => 'agent_metadata' }])
      args = { session_store: adapter, session_id: sid2, agent_id: 'meta', directory: dir }
      expect(ClaudeAgentSDK.get_subagent_metadata(**args)).to eq({})
      allow(adapter).to receive(:load).with(key).and_return(nil)
      expect(ClaudeAgentSDK.get_subagent_metadata(**args)).to be_nil
      allow(adapter).to receive(:load).with(key).and_raise(IOError, 'offline')
      expect { ClaudeAgentSDK.get_subagent_metadata(**args) }.to raise_error(IOError, 'offline')
    end

    it 'reads subagent messages, dropping synthetic agent_metadata entries' do
      msgs = ClaudeAgentSDK.get_subagent_messages(
        session_store: store, session_id: sid2, agent_id: 'abc', directory: dir
      )
      expect(msgs.length).to eq(1)
      expect(msgs.first.text).to eq('Subagent hi')
      # No toolUseId on the metadata entry -> no parent ids.
      expect(msgs.first.parent_tool_use_id).to be_nil
      expect(msgs.first.parent_agent_id).to be_nil
    end

    # --- parent ids recovered from the agent_metadata entry (Python PR #1207) ---

    it 'stamps toolUseId/parentAgentId from the agent_metadata entry, last one winning' do
      # The metadata is rewritten on resume, so a subagent stream can carry
      # several agent_metadata entries; the last one describes the sidecar.
      sub_key = { 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/agent-multi' }
      root = subagent_entry(sid2, 'hi', '2024-01-02T00:00:01.000Z')
      reply = subagent_entry(sid2, 'hello', '2024-01-02T00:00:02.000Z', 'parentUuid' => root['uuid'])
      store.append(sub_key, [
                     { 'type' => 'agent_metadata', 'agentType' => 'gp', 'toolUseId' => 'toolu_old' },
                     root, reply,
                     { 'type' => 'agent_metadata', 'agentType' => 'gp', 'toolUseId' => 'toolu_new',
                       'parentAgentId' => 'a-parent' }
                   ])

      msgs = ClaudeAgentSDK.get_subagent_messages(
        session_store: store, session_id: sid2, agent_id: 'multi', directory: dir
      )
      expect(msgs.length).to eq(2)
      expect(msgs.map(&:parent_tool_use_id)).to all(eq('toolu_new'))
      expect(msgs.map(&:parent_agent_id)).to all(eq('a-parent'))
    end

    it 'ignores non-String ids on the agent_metadata entry' do
      sub_key = { 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/agent-bad' }
      store.append(sub_key, [
                     { 'type' => 'agent_metadata', 'toolUseId' => 7, 'parentAgentId' => nil },
                     subagent_entry(sid2, 'hi', '2024-01-02T00:00:01.000Z')
                   ])

      msgs = ClaudeAgentSDK.get_subagent_messages(
        session_store: store, session_id: sid2, agent_id: 'bad', directory: dir
      )
      expect(msgs.length).to eq(1)
      expect(msgs.first.parent_tool_use_id).to be_nil
      expect(msgs.first.parent_agent_id).to be_nil
    end

    it 'never sets parent ids on top-level store-backed session messages' do
      msgs = ClaudeAgentSDK.get_session_messages(
        session_store: store, session_id: sid2, directory: dir
      )
      expect(msgs).not_to be_empty
      expect(msgs.map(&:parent_tool_use_id)).to all(be_nil)
      expect(msgs.map(&:parent_agent_id)).to all(be_nil)
    end

    it 'returns the full parentUuid chain for a realistic sidechain transcript' do
      # Regression: the subagent reader must not reuse the main-session pipeline
      # (which rejects isSidechain leaves/entries) — that returned [] for every
      # real subagent transcript.
      root = subagent_entry(sid2, 'chain root', '2024-01-02T00:00:05.000Z')
      reply = { 'type' => 'assistant', 'uuid' => SecureRandom.uuid, 'parentUuid' => root['uuid'],
                'timestamp' => '2024-01-02T00:00:06.000Z', 'sessionId' => sid2, 'isSidechain' => true,
                'message' => { 'content' => 'chain reply' } }
      store.append({ 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/agent-chain' },
                   [root, reply])
      msgs = ClaudeAgentSDK.get_subagent_messages(
        session_store: store, session_id: sid2, agent_id: 'chain', directory: dir
      )
      expect(msgs.map(&:type)).to eq(%w[user assistant])
    end

    it 'prefers the canonical top-level path when a nested path shares the agent-<id>' do
      # Append the nested path FIRST so list_subkeys yields it before the
      # top-level one; a first-match resolver would return the nested transcript.
      store.append(
        { 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/workflows/run1/agent-dup' },
        [subagent_entry(sid2, 'Nested dup', '2024-01-02T00:00:03.000Z')]
      )
      store.append({ 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/agent-dup' },
                   [subagent_entry(sid2, 'Top-level dup', '2024-01-02T00:00:04.000Z')])
      msgs = ClaudeAgentSDK.get_subagent_messages(
        session_store: store, session_id: sid2, agent_id: 'dup', directory: dir
      )
      expect(msgs.first.text).to eq('Top-level dup')
    end

    it 'resolves a nested subagents/workflows/<run>/agent-<id> path' do
      store.append(
        { 'project_key' => project_key, 'session_id' => sid2, 'subpath' => 'subagents/workflows/run1/agent-nested' },
        [subagent_entry(sid2, 'Nested agent', '2024-01-02T00:00:02.000Z')]
      )
      msgs = ClaudeAgentSDK.get_subagent_messages(
        session_store: store, session_id: sid2, agent_id: 'nested', directory: dir
      )
      expect(msgs.first.text).to eq('Nested agent')
    end

    it 'raises from list_subagents when the store lacks list_subkeys' do
      list_only = list_only_store
      expect { ClaudeAgentSDK.list_subagents(session_store: list_only, session_id: sid2, directory: dir) }
        .to raise_error(ArgumentError, /list_subkeys/)
    end

    it 'does not crash when list_subkeys returns nil (non-conformant adapter)' do
      ns = nil_subkeys_store
      expect(ClaudeAgentSDK.list_subagents(session_store: ns, session_id: sid2, directory: dir)).to eq([])
      expect(ClaudeAgentSDK.get_subagent_messages(
               session_store: ns, session_id: sid2, agent_id: 'abc', directory: dir
             )).to eq([])
    end
  end

  # Issue #74: a non-String id used to reach `match?`/`empty?` and raise a deep
  # NoMethodError; it now gets exactly the answer a malformed id gets.
  # Issue #79: agent_id is synthesized into the store subpath
  # `subagents/agent-<agent_id>`, so a malformed one ('/', '..', '%', NUL)
  # must be rejected before any adapter call can see it.
  describe 'id validation at the API boundary (issues #74, #79)' do
    # A load-only store recording every key the SDK hands it.
    let(:recorder) do
      Class.new do
        attr_reader :keys

        def initialize = @keys = []
        def append(_key, _entries) = nil

        def load(key)
          @keys << key
          nil
        end
      end.new
    end

    [nil, 123, :sym, ['x']].each do |bad|
      it "treats session_id #{bad.inspect} like a malformed id on every store reader",
         rbs_incompatible: 'passes out-of-signature input to test its rejection' do
        args = { session_store: recorder, session_id: bad, directory: dir }
        expect(ClaudeAgentSDK.get_session_info(**args)).to be_nil
        expect(ClaudeAgentSDK.get_session_messages(**args)).to eq([])
        expect(ClaudeAgentSDK.list_subagents(**args)).to eq([])
        expect(ClaudeAgentSDK.get_subagent_metadata(**args, agent_id: 'abc')).to be_nil
        expect(ClaudeAgentSDK.get_subagent_messages(**args, agent_id: 'abc')).to eq([])
        expect(recorder.keys).to be_empty
      end

      it "raises ArgumentError (not NoMethodError) for session_id #{bad.inspect} on import_session_to_store",
         rbs_incompatible: 'passes out-of-signature input to test its rejection' do
        expect { ClaudeAgentSDK.import_session_to_store(session_id: bad, session_store: recorder, directory: dir) }
          .to raise_error(ArgumentError, /Invalid session_id/)
      end

      it "treats agent_id #{bad.inspect} like a malformed id on the store subagent readers",
         rbs_incompatible: 'passes out-of-signature input to test its rejection' do
        args = { session_store: recorder, session_id: sid1, agent_id: bad, directory: dir }
        expect(ClaudeAgentSDK.get_subagent_metadata(**args)).to be_nil
        expect(ClaudeAgentSDK.get_subagent_messages(**args)).to eq([])
        expect(recorder.keys).to be_empty
      end
    end

    ['', '.', '..', '../x', 'a/b', 'a\\b', 'x%2Fy', "a\u0000b", 'a b', "abc\n"].each do |bad|
      it "never synthesizes a store subpath from the malformed agent_id #{bad.inspect}" do
        args = { session_store: recorder, session_id: sid1, agent_id: bad, directory: dir }
        expect(ClaudeAgentSDK.get_subagent_metadata(**args)).to be_nil
        expect(ClaudeAgentSDK.get_subagent_messages(**args)).to eq([])
        expect(recorder.keys).to be_empty
      end
    end

    # Shapes the CLI actually writes (hex ids, prefixed prompt-suggestion /
    # compaction ids) must keep resolving.
    %w[a1b2c3d a0123456789abcdef aprompt_suggestion-1a2b3c acompact-4d5e6f agent_1 v1.2].each do |ok|
      it "still reads the well-formed agent_id #{ok.inspect}" do
        ClaudeAgentSDK.get_subagent_messages(session_store: recorder, session_id: sid1,
                                             agent_id: ok, directory: dir)
        expect(recorder.keys).to eq([{ 'project_key' => project_key, 'session_id' => sid1,
                                       'subpath' => "subagents/agent-#{ok}" }])
      end
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

  # A non-conformant store whose list_session_summaries returns nil (rather
  # than []) — e.g. a NULL JSONB read — to exercise the Array() degrade-to-gap-fill.
  def nil_summaries_store
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

      def list_session_summaries(_project_key) = nil
    end.new
  end

  # A store that implements list_sessions + list_session_summaries but maintains
  # NO summaries (always returns []), so every session is a gap-fill placeholder.
  # mtime is a monotonic per-append counter so insertion order == recency order.
  def gap_fill_store
    Class.new(ClaudeAgentSDK::SessionStore) do
      def initialize
        super
        @data = {}
        @mtimes = {}
        @clock = 0
      end

      def append(key, entries)
        k = [key['project_key'], key['session_id']]
        (@data[k] ||= []).concat(entries)
        @clock += 1
        @mtimes[k] = 1_700_000_000_000 + @clock
      end

      def load(key) = @data[[key['project_key'], key['session_id']]]&.dup

      def list_sessions(project_key)
        @data.keys.select { |pk, _| pk == project_key }
                  .map { |pk, sid| { 'session_id' => sid, 'mtime' => @mtimes[[pk, sid]] } }
      end

      def list_session_summaries(_project_key) = []
    end.new
  end

  # A store whose listing (and optionally summary-sidecar) mtimes are set
  # directly by the spec, so adapter-shaped values — ISO-8601 Strings, mixed
  # types, ties — can be exercised. list_sessions rotates its row order on
  # every call, like an adapter query without ORDER BY, so a sort without a
  # total order shows up as cross-call instability instead of passing by
  # accident of insertion order. Summaries are folded from the stored
  # entries at call time unless frozen_summaries is set, in which case the
  # sidecar keeps the fold captured when it was frozen (a stale sidecar).
  def controlled_mtime_store(with_summaries:)
    cstore = Class.new(ClaudeAgentSDK::SessionStore) do
      attr_reader :listing_mtimes, :summary_mtimes, :data

      def initialize
        super
        @data = {}
        @listing_mtimes = {}
        @summary_mtimes = {}
        @calls = 0
        @frozen = nil
      end

      def frozen_summaries=(value)
        @frozen = value ? @data.transform_values(&:dup) : nil
      end

      def append(key, entries)
        (@data[key['session_id']] ||= []).concat(entries)
      end

      def load(key) = @data[key['session_id']]&.dup

      def list_sessions(_project_key)
        @calls += 1
        @listing_mtimes.map { |sid, mtime| { 'session_id' => sid, 'mtime' => mtime } }.rotate(@calls)
      end

      def summary_rows
        source = @frozen || @data
        @summary_mtimes.map do |sid, mtime|
          ClaudeAgentSDK::SessionSummary.fold_session_summary(nil, { 'session_id' => sid }, source.fetch(sid, []))
                                        .merge('mtime' => mtime)
        end.rotate(@calls)
      end
    end.new
    cstore.define_singleton_method(:list_session_summaries) { |_project_key| summary_rows } if with_summaries
    cstore
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
