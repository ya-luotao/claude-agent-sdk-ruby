# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'stringio'

# Issue #126: one sessions function per operation, with an optional
# session_store:. The *_from_store / *_via_store twins remain as deprecated
# shims through 1.x (removed in 2.0). Path behaviour itself is covered by sessions_spec.rb /
# session_mutations_spec.rb (disk) and session_store_reads_spec.rb /
# session_mutations_store_spec.rb (store); this spec pins the routing, the
# kwarg reconciliation, and the shims' warn-once contract.
RSpec.describe 'Sessions API consolidation' do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:sid) { '11111111-1111-4111-8111-111111111111' }
  let(:up_to) { '22222222-2222-4222-8222-222222222222' }
  let(:result) { Object.new }

  before { ClaudeAgentSDK::Deprecation.reset! }
  after { ClaudeAgentSDK::Deprecation.reset! }

  def capture_stderr
    captured = +''
    original = $stderr
    $stderr = StringIO.new(captured)
    begin
      yield
    ensure
      $stderr = original
    end
    captured
  end

  # SDKSessionInfo / SessionMessage define no ==; compare their attributes.
  def state(obj)
    obj.instance_variables.to_h { |ivar| [ivar, obj.instance_variable_get(ivar)] }
  end

  # merged name => [implementation module, disk impl, store impl (== twin name),
  #                 kwargs shared by both paths]
  cases = {
    list_sessions: [ClaudeAgentSDK::Sessions, :list_sessions_from_store,
                    { directory: '/p', limit: 5, offset: 2 }],
    get_session_info: [ClaudeAgentSDK::Sessions, :get_session_info_from_store,
                       { session_id: 'S', directory: '/p' }],
    get_session_messages: [ClaudeAgentSDK::Sessions, :get_session_messages_from_store,
                           { session_id: 'S', directory: '/p', limit: 5, offset: 2 }],
    list_subagents: [ClaudeAgentSDK::Sessions, :list_subagents_from_store,
                     { session_id: 'S', directory: '/p' }],
    get_subagent_metadata: [ClaudeAgentSDK::Sessions, :get_subagent_metadata_from_store,
                            { session_id: 'S', agent_id: 'a1', directory: '/p' }],
    get_subagent_messages: [ClaudeAgentSDK::Sessions, :get_subagent_messages_from_store,
                            { session_id: 'S', agent_id: 'a1', directory: '/p', limit: 5, offset: 2 }],
    rename_session: [ClaudeAgentSDK::SessionMutations, :rename_session_via_store,
                     { session_id: 'S', title: 'T', directory: '/p' }],
    tag_session: [ClaudeAgentSDK::SessionMutations, :tag_session_via_store,
                  { session_id: 'S', tag: 'x', directory: '/p' }],
    delete_session: [ClaudeAgentSDK::SessionMutations, :delete_session_via_store,
                     { session_id: 'S', directory: '/p' }],
    fork_session: [ClaudeAgentSDK::SessionMutations, :fork_session_via_store,
                   { session_id: 'S', directory: '/p', up_to_message_id: 'M', title: 'T' }]
  }

  cases.each do |name, (impl, twin, kwargs)|
    describe ".#{name}", rbs_incompatible: 'stubs the implementation to return an Object.new sentinel' do
      it 'uses the local-disk implementation when session_store is omitted' do
        disk_kwargs = name == :list_sessions ? kwargs.merge(include_worktrees: true) : kwargs
        expect(impl).to receive(name).with(**disk_kwargs).and_return(result)
        expect(impl).not_to receive(twin)

        expect(ClaudeAgentSDK.public_send(name, **kwargs)).to be(result)
      end

      it 'uses the local-disk implementation for an explicit session_store: nil' do
        allow(impl).to receive(name).and_return(result)
        expect(impl).not_to receive(twin)

        expect(ClaudeAgentSDK.public_send(name, **kwargs, session_store: nil)).to be(result)
      end

      it 'uses the store implementation, with identical arguments, when session_store is given' do
        expect(impl).to receive(twin).with(session_store: store, **kwargs).and_return(result)
        expect(impl).not_to receive(name)

        expect(ClaudeAgentSDK.public_send(name, **kwargs, session_store: store)).to be(result)
      end
    end

    describe ".#{twin} (deprecated)",
             rbs_incompatible: 'returns an Object.new sentinel; asserts the warning location' do
      it 'warns once per process, naming the replacement and the caller, and still returns the same result' do
        expect(impl).to receive(twin).with(session_store: store, **kwargs).twice.and_return(result)

        line = __LINE__ + 1
        first = capture_stderr { expect(ClaudeAgentSDK.public_send(twin, session_store: store, **kwargs)).to be(result) }
        second = capture_stderr { expect(ClaudeAgentSDK.public_send(twin, session_store: store, **kwargs)).to be(result) }

        expect(first.lines.size).to eq(1)
        expect(first).to include("ClaudeAgentSDK.#{twin} is deprecated and will be removed in 2.0; " \
                                 "use ClaudeAgentSDK.#{name}(session_store: store")
        expect(first).to start_with("#{__FILE__}:#{line}: warning: ")
        expect(second).to be_empty
      end
    end
  end

  it 'warns separately for each deprecated method' do
    output = capture_stderr do
      ClaudeAgentSDK.list_sessions_from_store(session_store: store)
      ClaudeAgentSDK.list_sessions_from_store(session_store: store)
      ClaudeAgentSDK.get_session_messages_from_store(session_store: store, session_id: sid)
    end

    expect(output.lines.size).to eq(2)
    expect(output).to include('list_sessions_from_store', 'get_session_messages_from_store')
  end

  it 'warns exactly once under concurrent first calls' do
    output = capture_stderr do
      Array.new(16) { Thread.new { ClaudeAgentSDK.list_sessions_from_store(session_store: store) } }.each(&:join)
    end

    expect(output.scan('list_sessions_from_store is deprecated').size).to eq(1)
  end

  it 'never lets a broken $stderr turn a deprecated call into an error' do
    broken = StringIO.new
    broken.close
    original = $stderr
    $stderr = broken
    begin
      expect(ClaudeAgentSDK.list_sessions_from_store(session_store: store)).to eq([])
    ensure
      $stderr = original
    end
  end

  it 'is silenced by $VERBOSE = nil (-W0)' do
    verbose = $VERBOSE
    $VERBOSE = nil
    output = capture_stderr { ClaudeAgentSDK.list_sessions_from_store(session_store: store) }
    expect(output).to be_empty
  ensure
    $VERBOSE = verbose
  end

  it 'keeps a deprecated twin failing on a nil store instead of falling back to local disk',
     rbs_incompatible: 'passes session_store: nil where a store is required' do
    expect(ClaudeAgentSDK::Sessions).not_to receive(:list_sessions)
    capture_stderr do
      expect { ClaudeAgentSDK.list_sessions_from_store(session_store: nil) }
        .to raise_error(ArgumentError, /implements neither list_session_summaries nor list_sessions/)
    end
  end

  describe 'list_sessions include_worktrees: (disk only)' do
    it 'forwards an explicit value to the disk path unchanged, nil included' do
      [true, false, nil].each do |value|
        expect(ClaudeAgentSDK::Sessions).to receive(:list_sessions)
          .with(directory: nil, limit: nil, offset: 0, include_worktrees: value).and_return([])
        ClaudeAgentSDK.list_sessions(include_worktrees: value)
      end
    end

    it 'accepts the default true with a session_store, explicit or not' do
      expect(ClaudeAgentSDK::Sessions).to receive(:list_sessions_from_store)
        .with(session_store: store, directory: nil, limit: nil, offset: 0).twice.and_return([])
      expect(ClaudeAgentSDK::Sessions).not_to receive(:list_sessions)

      expect(ClaudeAgentSDK.list_sessions(session_store: store)).to eq([])
      expect(ClaudeAgentSDK.list_sessions(session_store: store, include_worktrees: true)).to eq([])
    end

    it 'raises instead of silently ignoring include_worktrees: false/nil with a session_store' do
      expect(ClaudeAgentSDK::Sessions).not_to receive(:list_sessions_from_store)
      { false => /include_worktrees: false applies only to local-disk listing/,
        nil => /include_worktrees: nil applies only to local-disk listing/ }.each do |value, message|
        expect { ClaudeAgentSDK.list_sessions(session_store: store, include_worktrees: value) }
          .to raise_error(ArgumentError, message)
      end
    end
  end

  # End to end against the reference adapter: each shim returns exactly what
  # the merged form does.
  describe 'shim results match the merged form on a real store' do
    let(:project_key) { ClaudeAgentSDK.project_key_for_directory(nil) }
    let(:key) { { 'project_key' => project_key, 'session_id' => sid } }

    before do
      store.append(key, [
                     { 'type' => 'user', 'uuid' => up_to, 'sessionId' => sid, 'timestamp' => '2026-01-01T00:00:00.000Z',
                       'message' => { 'role' => 'user', 'content' => 'hello world' } }
                   ])
      store.append(key.merge('subpath' => 'subagents/agent-a1'), [
                     { 'type' => 'agent_metadata', 'agentType' => 'general' },
                     { 'type' => 'user', 'uuid' => SecureRandom.uuid, 'sessionId' => sid,
                       'message' => { 'role' => 'user', 'content' => 'sub' } }
                   ])
    end

    it 'agrees for every reader' do
      capture_stderr do
        expect(ClaudeAgentSDK.list_sessions_from_store(session_store: store).map { |o| state(o) })
          .to eq(ClaudeAgentSDK.list_sessions(session_store: store).map { |o| state(o) })
        expect(ClaudeAgentSDK.get_session_info_from_store(session_store: store, session_id: sid).then { |o| state(o) })
          .to eq(ClaudeAgentSDK.get_session_info(session_store: store, session_id: sid).then { |o| state(o) })
        expect(ClaudeAgentSDK.get_session_messages_from_store(session_store: store, session_id: sid).map { |o| state(o) })
          .to eq(ClaudeAgentSDK.get_session_messages(session_store: store, session_id: sid).map { |o| state(o) })
        expect(ClaudeAgentSDK.list_subagents_from_store(session_store: store, session_id: sid))
          .to eq(ClaudeAgentSDK.list_subagents(session_store: store, session_id: sid)).and eq(['a1'])
        expect(ClaudeAgentSDK.get_subagent_metadata_from_store(session_store: store, session_id: sid, agent_id: 'a1'))
          .to eq(ClaudeAgentSDK.get_subagent_metadata(session_store: store, session_id: sid, agent_id: 'a1'))
          .and eq('agentType' => 'general')
        expect(ClaudeAgentSDK.get_subagent_messages_from_store(session_store: store, session_id: sid, agent_id: 'a1')
                             .map { |o| state(o) })
          .to eq(ClaudeAgentSDK.get_subagent_messages(session_store: store, session_id: sid, agent_id: 'a1').map { |o| state(o) })
      end
    end

    it 'applies every mutation to the store' do
      capture_stderr do
        expect(ClaudeAgentSDK.rename_session_via_store(session_store: store, session_id: sid, title: 'Renamed')).to be_nil
        expect(ClaudeAgentSDK.tag_session_via_store(session_store: store, session_id: sid, tag: 'keep')).to be_nil
        info = ClaudeAgentSDK.get_session_info(session_store: store, session_id: sid)
        expect([info.custom_title, info.tag]).to eq(%w[Renamed keep])

        forked = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: sid, title: 'Fork')
        expect(forked).to be_a(ClaudeAgentSDK::ForkSessionResult)
        expect(ClaudeAgentSDK.get_session_info(session_store: store, session_id: forked.session_id).custom_title)
          .to eq('Fork')

        ClaudeAgentSDK.delete_session_via_store(session_store: store, session_id: sid)
        expect(ClaudeAgentSDK.get_session_info(session_store: store, session_id: sid)).to be_nil
      end
    end
  end
end
