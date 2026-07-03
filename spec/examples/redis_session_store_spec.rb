# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'claude_agent_sdk/testing/session_store_conformance'

# Gated live spec: runs only when the `redis` gem is installed (optional
# :examples Bundler group) AND SESSION_STORE_REDIS_URL points at a reachable
# server. Otherwise the whole group is filtered out (parity with Python's
# importorskip + env-gated live suite). To run:
#
#   docker run -d -p 6379:6379 redis:7-alpine
#   SESSION_STORE_REDIS_URL=redis://localhost:6379/0 \
#     bundle config set --local with examples && bundle exec rspec spec/examples/
REDIS_AVAILABLE = begin
  require 'redis'
  require_relative '../../examples/session_stores/redis_session_store'
  url = ENV.fetch('SESSION_STORE_REDIS_URL', nil)
  if url
    probe = Redis.new(url: url)
    probe.ping
    probe.close
    true
  else
    false
  end
rescue LoadError, StandardError
  false
end

RSpec.describe 'RedisSessionStore', if: REDIS_AVAILABLE do
  let(:client) { Redis.new(url: ENV.fetch('SESSION_STORE_REDIS_URL')) }
  let(:prefixes) { [] }

  after do
    # Never FLUSHDB: SESSION_STORE_REDIS_URL may point at shared infrastructure
    # (the README invites it), so wiping the DB would destroy unrelated keys.
    # Delete only the keys under prefixes this run created.
    prefixes.each { |p| delete_namespace(p) }
    client.close
  end

  # Fresh, isolated key namespace per make_store call so conformance contracts
  # don't leak state into one another (mirrors the Postgres spec's per-call
  # random table).
  def fresh_store
    prefix = "cst_test_#{SecureRandom.hex(6)}"
    prefixes << prefix
    RedisSessionStore.new(client: client, prefix: prefix)
  end

  # SCAN + UNLINK every key the adapter wrote under this prefix (adapter keys are
  # always "<prefix>:<...>"). Cursor-based and prefix-scoped, so it never touches
  # keys outside this run's namespace.
  def delete_namespace(prefix)
    client.scan_each(match: "#{prefix}:*").each_slice(512) { |batch| client.unlink(*batch) }
  end

  it 'passes the full SessionStore conformance suite' do
    expect do
      ClaudeAgentSDK::Testing.run_session_store_conformance(-> { fresh_store })
    end.not_to raise_error
  end

  it 'round-trips append/load and indexes the session' do
    s = fresh_store
    key = { 'project_key' => 'pk', 'session_id' => 'sid' }
    s.append(key, [{ 'type' => 'user', 'uuid' => 'a' }, { 'type' => 'assistant', 'uuid' => 'b' }])
    expect(s.load(key)).to eq([{ 'type' => 'user', 'uuid' => 'a' }, { 'type' => 'assistant', 'uuid' => 'b' }])

    listed = s.list_sessions('pk')
    expect(listed.map { |e| e['session_id'] }).to eq(['sid'])
    expect(listed.first['mtime']).to be > 1_000_000_000_000
  end

  it 'cascades delete to subpath lists and the session index' do
    s = fresh_store
    main = { 'project_key' => 'pk', 'session_id' => 'sid' }
    sub  = { 'project_key' => 'pk', 'session_id' => 'sid', 'subpath' => 'subagents/agent-1' }
    s.append(main, [{ 'type' => 'user', 'uuid' => 'm' }])
    s.append(sub,  [{ 'type' => 'user', 'uuid' => 's' }])

    s.delete(main)
    expect(s.load(main)).to be_nil
    expect(s.load(sub)).to be_nil
    expect(s.list_sessions('pk')).to be_empty
    expect(s.list_subkeys(main)).to be_empty
  end
end
