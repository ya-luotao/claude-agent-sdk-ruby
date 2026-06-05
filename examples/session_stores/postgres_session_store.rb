# frozen_string_literal: true

# Postgres-backed ClaudeAgentSDK::SessionStore reference adapter.
#
# This is a REFERENCE implementation demonstrating that the SessionStore
# contract generalizes to a relational backend. It is not shipped as part of the
# gem; copy it into your project and adapt as needed (add migrations,
# partitioning, retention sweeps, etc.). It mirrors the Python SDK's Postgres
# reference adapter.
#
# Requires the `pg` gem (https://rubygems.org/gems/pg):
#
#     gem install pg
#
# Usage:
#
#     require 'pg'
#     require 'claude_agent_sdk'
#     require_relative 'postgres_session_store'
#
#     conn  = PG.connect('postgresql://localhost/mydb')
#     store = PostgresSessionStore.new(conn: conn)
#     store.create_schema  # one-time, idempotent
#
#     ClaudeAgentSDK.query(prompt: 'Hello!',
#                          options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store)) do |msg|
#       # messages are mirrored to Postgres as they stream
#     end
#
# Schema (one row per transcript entry; `seq` orders entries within a key):
#
#     CREATE TABLE IF NOT EXISTS claude_session_store (
#       project_key text   NOT NULL,
#       session_id  text   NOT NULL,
#       subpath     text   NOT NULL DEFAULT '',
#       seq         bigserial,
#       entry       jsonb  NOT NULL,
#       mtime       bigint NOT NULL,
#       PRIMARY KEY (project_key, session_id, subpath, seq)
#     );
#
# The empty string is the `subpath` sentinel for the main transcript so the
# composite primary key is total (Postgres treats NULL as distinct in PKs).
#
# Concurrency: the +conn+ must be safe for the SDK's access pattern. The
# transcript-mirror batcher serializes its flushes and the store-read helpers
# run sequentially, so a single PG::Connection suffices for typical use. For
# heavy concurrent use, pass a small wrapper backed by a connection pool
# (e.g. the `connection_pool` gem) that responds to #exec_params / #exec.
#
# JSONB key ordering: entries are stored as `jsonb`, which REORDERS object keys
# on read-back. This is explicitly allowed by the SessionStore contract — #load
# requires deep-equal, not byte-equal, returns. The Ruby SDK reads entry fields
# by key from the parsed Hash (never a byte/prefix scan), so reordering is
# transparent. Use a `json` or `text` column if you need byte-stable storage.
#
# Retention: this adapter never deletes rows on its own. Add a scheduled
# DELETE ... WHERE mtime < $cutoff (or partition by mtime).
require 'json'
require 'claude_agent_sdk'

# Postgres-backed SessionStore. One row per transcript entry. #append is a
# single multi-row INSERT; #load is SELECT entry ... ORDER BY seq.
class PostgresSessionStore < ClaudeAgentSDK::SessionStore
  # Conservative identifier guard for the table name. The name is interpolated
  # into DDL/DML (placeholders cannot parameterize identifiers), so reject
  # anything that isn't a plain [A-Za-z_][A-Za-z0-9_]* to rule out injection.
  IDENT_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  # @param conn [PG::Connection] a connection (or pool wrapper) responding to
  #   #exec_params(sql, params) and #exec(sql).
  # @param table [String] table name; must match [A-Za-z_][A-Za-z0-9_]*.
  def initialize(conn:, table: 'claude_session_store')
    super()
    raise ArgumentError, "PostgresSessionStore requires 'conn'" if conn.nil?
    raise ArgumentError, "table #{table.inspect} must match [A-Za-z_][A-Za-z0-9_]* (it is interpolated into SQL)" unless table.match?(IDENT_RE)

    @conn = conn
    @table = table
  end

  # Create the table and listing index if absent. Idempotent. Call once at
  # startup (or run the equivalent migration out-of-band). The partial index on
  # subpath = '' keeps #list_sessions cheap without indexing every subagent row.
  def create_schema
    # Interpolating @table is safe: validated against IDENT_RE in #initialize.
    @conn.exec(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{@table} (
        project_key text   NOT NULL,
        session_id  text   NOT NULL,
        subpath     text   NOT NULL DEFAULT '',
        seq         bigserial,
        entry       jsonb  NOT NULL,
        mtime       bigint NOT NULL,
        PRIMARY KEY (project_key, session_id, subpath, seq)
      );
      CREATE INDEX IF NOT EXISTS #{@table}_list_idx
        ON #{@table} (project_key, session_id) WHERE subpath = '';
    SQL
    nil
  end

  def append(key, entries)
    return if entries.nil? || entries.empty?

    subpath = key['subpath'] || ''
    mtime = (Time.now.to_f * 1000).to_i
    # Single round-trip multi-row INSERT. Rows are assigned the bigserial `seq`
    # in VALUES order, so #load's ORDER BY seq replays entries in append order.
    rows = []
    params = []
    entries.each_with_index do |e, i|
      base = i * 5
      rows << "($#{base + 1}, $#{base + 2}, $#{base + 3}, $#{base + 4}::jsonb, $#{base + 5})"
      params.push(key['project_key'], key['session_id'], subpath, JSON.generate(e), mtime)
    end
    @conn.exec_params(
      "INSERT INTO #{@table} (project_key, session_id, subpath, entry, mtime) VALUES #{rows.join(', ')}",
      params
    )
    nil
  end

  def load(key)
    result = @conn.exec_params(
      "SELECT entry FROM #{@table} WHERE project_key = $1 AND session_id = $2 AND subpath = $3 ORDER BY seq",
      [key['project_key'], key['session_id'], key['subpath'] || '']
    )
    return nil if result.ntuples.zero?

    # The pg gem returns jsonb as its JSON text; parse each row. (If a type map
    # decodes jsonb to a Hash already, pass it through.)
    out = result.map do |row|
      v = row['entry']
      v.is_a?(String) ? JSON.parse(v) : v
    end
    out.empty? ? nil : out
  end

  def list_sessions(project_key)
    result = @conn.exec_params(
      "SELECT session_id, MAX(mtime) AS mtime FROM #{@table} WHERE project_key = $1 AND subpath = '' GROUP BY session_id",
      [project_key]
    )
    result.map { |row| { 'session_id' => row['session_id'], 'mtime' => row['mtime'].to_i } }
  end

  def delete(key)
    subpath = key['subpath']
    if subpath && !subpath.empty?
      # Targeted: remove just this subpath's rows.
      @conn.exec_params(
        "DELETE FROM #{@table} WHERE project_key = $1 AND session_id = $2 AND subpath = $3",
        [key['project_key'], key['session_id'], subpath]
      )
      return nil
    end

    # Cascade: main + every subpath under this (project_key, session_id).
    @conn.exec_params(
      "DELETE FROM #{@table} WHERE project_key = $1 AND session_id = $2",
      [key['project_key'], key['session_id']]
    )
    nil
  end

  def list_subkeys(key)
    result = @conn.exec_params(
      "SELECT DISTINCT subpath FROM #{@table} WHERE project_key = $1 AND session_id = $2 AND subpath <> ''",
      [key['project_key'], key['session_id']]
    )
    result.map { |row| row['subpath'] }
  end
end
