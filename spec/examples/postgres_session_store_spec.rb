# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'claude_agent_sdk/testing/session_store_conformance'

# Gated live spec: runs only when the `pg` gem is installed (optional :examples
# Bundler group) AND SESSION_STORE_POSTGRES_URL is set and reachable. There is
# no in-process Postgres fake, so this is live-only (parity with the Python
# SDK). Each example creates random-suffixed tables and DROPs them on teardown.
#
#   docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:16-alpine
#   SESSION_STORE_POSTGRES_URL=postgresql://postgres:postgres@localhost:5432/postgres \
#     bundle config set --local with examples && bundle exec rspec spec/examples/
POSTGRES_AVAILABLE = begin
  require 'pg'
  require_relative '../../examples/session_stores/postgres_session_store'
  url = ENV.fetch('SESSION_STORE_POSTGRES_URL', nil)
  if url
    probe = PG.connect(url)
    probe.exec('SELECT 1')
    probe.close
    true
  else
    false
  end
rescue LoadError, StandardError
  false
end

RSpec.describe 'PostgresSessionStore', if: POSTGRES_AVAILABLE do
  let(:conn) { PG.connect(ENV.fetch('SESSION_STORE_POSTGRES_URL')) }
  let(:tables) { [] }

  after do
    tables.each { |t| conn.exec("DROP TABLE IF EXISTS #{t}") }
    conn.close
  end

  # Fresh, isolated table per make_store call so conformance contracts don't
  # leak state into one another.
  def fresh_store
    table = "cst_test_#{SecureRandom.hex(6)}"
    tables << table
    store = PostgresSessionStore.new(conn: conn, table: table)
    store.create_schema
    store
  end

  it 'passes the full SessionStore conformance suite' do
    expect do
      ClaudeAgentSDK::Testing.run_session_store_conformance(-> { fresh_store })
    end.not_to raise_error
  end

  it 'round-trips append/load preserving entry order via seq' do
    s = fresh_store
    key = { 'project_key' => 'pk', 'session_id' => 'sid' }
    s.append(key, [{ 'type' => 'user', 'uuid' => 'a' }])
    s.append(key, [{ 'type' => 'assistant', 'uuid' => 'b' }, { 'type' => 'user', 'uuid' => 'c' }])
    expect(s.load(key).map { |e| e['uuid'] }).to eq(%w[a b c])
  end

  it 'rejects a non-identifier table name (SQL-injection guard)' do
    expect { PostgresSessionStore.new(conn: conn, table: 'x; DROP TABLE y') }.to raise_error(ArgumentError)
  end

  it 'cascades delete to subpath rows' do
    s = fresh_store
    main = { 'project_key' => 'pk', 'session_id' => 'sid' }
    sub  = { 'project_key' => 'pk', 'session_id' => 'sid', 'subpath' => 'subagents/agent-1' }
    s.append(main, [{ 'type' => 'user', 'uuid' => 'm' }])
    s.append(sub,  [{ 'type' => 'user', 'uuid' => 's' }])
    s.delete(main)
    expect(s.load(main)).to be_nil
    expect(s.load(sub)).to be_nil
    expect(s.list_subkeys(main)).to be_empty
  end
end
