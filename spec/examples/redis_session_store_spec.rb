# frozen_string_literal: true

require 'spec_helper'
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

  before { client.flushdb }
  after do
    client.flushdb
    client.close
  end

  it 'passes the full SessionStore conformance suite' do
    expect do
      ClaudeAgentSDK::Testing.run_session_store_conformance(
        lambda {
          client.flushdb
          RedisSessionStore.new(client: client, prefix: 'transcripts')
        }
      )
    end.not_to raise_error
  end

  it 'round-trips append/load and indexes the session' do
    s = RedisSessionStore.new(client: client, prefix: 't')
    key = { 'project_key' => 'pk', 'session_id' => 'sid' }
    s.append(key, [{ 'type' => 'user', 'uuid' => 'a' }, { 'type' => 'assistant', 'uuid' => 'b' }])
    expect(s.load(key)).to eq([{ 'type' => 'user', 'uuid' => 'a' }, { 'type' => 'assistant', 'uuid' => 'b' }])

    listed = s.list_sessions('pk')
    expect(listed.map { |e| e['session_id'] }).to eq(['sid'])
    expect(listed.first['mtime']).to be > 1_000_000_000_000
  end

  it 'cascades delete to subpath lists and the session index' do
    s = RedisSessionStore.new(client: client, prefix: 't')
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
