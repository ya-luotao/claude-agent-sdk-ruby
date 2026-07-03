# frozen_string_literal: true

# Redis-backed ClaudeAgentSDK::SessionStore reference adapter.
#
# This is a REFERENCE implementation demonstrating that the SessionStore
# contract generalizes to a non-blob backend. It is not shipped as part of the
# gem; copy it into your project and adapt as needed. It mirrors the Python and
# TypeScript SDK Redis reference adapters.
#
# Requires the `redis` gem (https://rubygems.org/gems/redis):
#
#     gem install redis
#
# Usage:
#
#     require 'redis'
#     require 'claude_agent_sdk'
#     require_relative 'redis_session_store'
#
#     store = RedisSessionStore.new(client: Redis.new(url: 'redis://localhost:6379/0'),
#                                   prefix: 'transcripts')
#
#     ClaudeAgentSDK.query(prompt: 'Hello!',
#                          options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store)) do |msg|
#       # messages are mirrored to Redis as they stream
#     end
#
# Key scheme (`:` separator; project_key/session_id are opaque so collisions
# with the SDK's `/`-based project_key are avoided):
#
#     {prefix}:{project_key}:{session_id}             list  main transcript (one JSON string per entry)
#     {prefix}:{project_key}:{session_id}:{subpath}   list  subagent transcript
#     {prefix}:{project_key}:{session_id}:__subkeys   set   subpaths under this session
#     {prefix}:{project_key}:__sessions               zset  session_id -> mtime(ms)
#
# Index keys (`__subkeys`, `__sessions`) live in reserved positions; the SDK
# never emits a session_id of `__sessions` or a subpath of `__subkeys`.
#
# Retention: this adapter never expires keys on its own. Configure Redis key
# expiration on your prefix or call #delete according to your compliance
# requirements. Local-disk transcripts under CLAUDE_CONFIG_DIR are swept
# independently by the CLI's `cleanupPeriodDays` setting.
require 'json'
require 'claude_agent_sdk'

# Redis-backed SessionStore. Each #append is an RPUSH (plus an index update in
# a single MULTI); #load is LRANGE 0 -1.
class RedisSessionStore < ClaudeAgentSDK::SessionStore
  # Reserved subpath sentinel for the per-session subkey set.
  SUBKEYS = '__subkeys'
  # Reserved session_id sentinel for the per-project session index.
  SESSIONS = '__sessions'

  # @param client [Redis] a pre-configured `redis` client. The caller controls
  #   host, port, auth, TLS, etc. The redis-rb client returns String replies, so
  #   no decode option is needed (the adapter JSON.parses each list element).
  # @param prefix [String] optional key prefix (e.g. "transcripts"). A trailing
  #   ':' is normalized; an empty prefix produces no leading separator.
  def initialize(client:, prefix: '')
    super()
    @client = client
    # Non-empty prefix always ends in exactly one ':'; empty stays empty so keys
    # never start with a stray separator.
    @prefix = prefix.empty? ? '' : "#{prefix.sub(/:+\z/, '')}:"
    # Monotonic mtime state (see #next_mtime); mutex because appends arrive on
    # multiple FiberBoundary worker threads.
    @last_mtime = 0
    @mutex = Mutex.new
  end

  def append(key, entries)
    return if entries.nil? || entries.empty?

    @client.multi do |pipe|
      pipe.rpush(entry_key(key), entries.map { |e| JSON.generate(e) })
      subpath = key['subpath']
      if subpath && !subpath.empty?
        pipe.sadd(subkeys_key(key), subpath)
      else
        # Only main-transcript appends bump the session index — matches
        # InMemorySessionStore.list_sessions's "no subpath" filter.
        pipe.zadd(sessions_key(key['project_key']), next_mtime, key['session_id'])
      end
    end
    nil
  end

  def load(key)
    raw = @client.lrange(entry_key(key), 0, -1)
    return nil if raw.nil? || raw.empty?

    out = raw.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError, TypeError
      nil # skip malformed entries (parity with the S3 adapter)
    end
    out.empty? ? nil : out
  end

  def list_sessions(project_key)
    @client.zrange(sessions_key(project_key), 0, -1, with_scores: true).map do |session_id, score|
      { 'session_id' => session_id, 'mtime' => score.to_i }
    end
  end

  def delete(key)
    subpath = key['subpath']
    # An empty-string subpath is treated as "no subpath" (main), matching
    # entry_key / append, so it cascades like nil rather than taking the
    # targeted branch and orphaning subkeys + leaking the session index.
    if subpath && !subpath.empty?
      # Targeted: remove just this subpath list and its index entry.
      @client.multi do |pipe|
        pipe.del(entry_key(key))
        pipe.srem(subkeys_key(key), subpath)
      end
      return nil
    end

    # Cascade: main list + every subpath list + subkey set + session-index entry.
    # WATCH the subkey set so a concurrent eager-mode append that adds a new
    # subpath between the SMEMBERS read and EXEC aborts the transaction (EXEC
    # returns nil); retry until the snapshot is consistent. Without WATCH the
    # freshly-created subagent list would be orphaned forever — the README
    # recommends noeviction, so orphans never expire. delete runs at
    # end-of-session, so a racing append (and thus a retry) is rare.
    sk_key = subkeys_key(key)
    loop do
      committed = @client.watch(sk_key) do
        subpaths = @client.smembers(sk_key)
        to_delete = [entry_key(key), sk_key]
        to_delete.concat(subpaths.map { |sp| entry_key(key.merge('subpath' => sp)) })
        @client.multi do |pipe|
          pipe.del(*to_delete)
          pipe.zrem(sessions_key(key['project_key']), key['session_id'])
        end
      end
      break unless committed.nil?
    end
    nil
  end

  def list_subkeys(key)
    @client.smembers(subkeys_key(key))
  end

  private

  # Redis key for a transcript list (main or subpath).
  def entry_key(key)
    parts = [key['project_key'], key['session_id']]
    subpath = key['subpath']
    parts << subpath if subpath && !subpath.empty?
    @prefix + parts.join(':')
  end

  # Redis key for the per-session subpath set.
  def subkeys_key(key)
    "#{@prefix}#{key['project_key']}:#{key['session_id']}:#{SUBKEYS}"
  end

  # Redis key for the per-project session index (sorted set, score = mtime).
  def sessions_key(project_key)
    "#{@prefix}#{project_key}:#{SESSIONS}"
  end

  # Monotonically increasing epoch-ms for the session-index score. Mirrors the
  # S3 adapter's guard (and the SDK's own store): a backward wall-clock step
  # must not lower a session's score below an earlier append's, which would
  # reorder #list_sessions and misdirect --continue's "most recent" pick.
  # Mutex-guarded since appends run on multiple FiberBoundary worker threads.
  def next_mtime
    @mutex.synchronize do
      now_ms = (Time.now.to_f * 1000).to_i
      now_ms = @last_mtime + 1 if now_ms <= @last_mtime
      @last_mtime = now_ms
    end
  end
end
