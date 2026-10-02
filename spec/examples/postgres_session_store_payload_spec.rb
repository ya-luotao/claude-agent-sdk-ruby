# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

# Gated live spec, like postgres_session_store_spec.rb: runs only when the `pg`
# gem is installed (optional :examples Bundler group) AND
# SESSION_STORE_POSTGRES_URL points at a reachable server. Each example uses a
# random-suffixed table and DROPs it on teardown.
postgres_url = ENV.fetch('SESSION_STORE_POSTGRES_URL', nil)
postgres_reachable = begin
  require 'pg'
  require_relative '../../examples/session_stores/postgres_session_store'
  if postgres_url
    probe = PG.connect(postgres_url)
    probe.exec('SELECT 1')
    probe.close
    true
  else
    false
  end
rescue LoadError, StandardError
  false
end

# Transcripts carry NUL characters (binary tool output). JSON.generate writes
# one as the six-character escape for U+0000, which PostgreSQL's `jsonb` input
# rejects and `json` stores as given. One such entry used to fail the whole
# multi-row INSERT, so the mirror dropped every entry of that batch.
RSpec.describe 'PostgresSessionStore with a NUL character in a transcript entry', if: postgres_reachable do
  let(:conn) { PG.connect(postgres_url) }
  let(:table) { "cst_test_#{SecureRandom.hex(6)}" }
  let(:store) { PostgresSessionStore.new(conn: conn, table: table) }
  let(:key) { { 'project_key' => '-Users-dev-app', 'session_id' => SecureRandom.uuid } }
  let(:binary_output) do
    { 'type' => 'user', 'uuid' => 'u-nul',
      'message' => { 'role' => 'user',
                     'content' => [{ 'type' => 'tool_result', 'tool_use_id' => 'toolu_01',
                                     'content' => "ELF#{0.chr}#{1.chr}binary" }] } }
  end

  after do
    conn.exec("DROP TABLE IF EXISTS #{table}")
    conn.close
  end

  def turn(uuid)
    { 'type' => 'user', 'uuid' => uuid, 'message' => { 'role' => 'user', 'content' => "turn #{uuid}" } }
  end

  it 'stores the entry, and the clean entries appended with it' do
    store.create_schema
    batch = [turn('u-1'), binary_output, turn('u-2')]

    store.append(key, batch)

    expect(store.load(key)).to eq(batch)
  end

  # #create_schema is CREATE TABLE IF NOT EXISTS: a table created by an earlier
  # copy of the adapter keeps its jsonb column until it is migrated. This is
  # the migration the README gives.
  it 'still rejects it on a table with the old jsonb column, until that column is migrated' do
    conn.exec(<<~SQL)
      CREATE TABLE #{table} (
        project_key text   NOT NULL,
        session_id  text   NOT NULL,
        subpath     text   NOT NULL DEFAULT '',
        seq         bigserial,
        entry       jsonb  NOT NULL,
        mtime       bigint NOT NULL,
        PRIMARY KEY (project_key, session_id, subpath, seq)
      )
    SQL
    store.create_schema # leaves the existing table as it is
    store.append(key, [turn('u-1')])
    expect { store.append(key, [binary_output]) }.to raise_error(PG::UntranslatableCharacter)

    conn.exec("ALTER TABLE #{table} ALTER COLUMN entry TYPE json USING entry::json")

    store.append(key, [binary_output])
    expect(store.load(key)).to eq([turn('u-1'), binary_output])
  end
end
