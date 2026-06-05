# frozen_string_literal: true

require 'pathname'
require_relative 'sessions'
require_relative 'session_summary'

module ClaudeAgentSDK
  # Controls when transcript-mirror entries are flushed to a SessionStore.
  #
  # - "batched" (default): buffer entries and flush once per turn (on the
  #   `result` message) or when the pending buffer exceeds 500 entries / 1 MiB.
  # - "eager": trigger a background flush after every transcript_mirror frame
  #   so SessionStore#append sees entries in near real time.
  SESSION_STORE_FLUSH_MODES = %w[batched eager].freeze

  # Adapter for mirroring session transcripts to external storage.
  #
  # The subprocess still writes to local disk; the adapter receives a secondary
  # copy via SessionStore#append, and `resume` can materialize from the store
  # via SessionStore#load when the local file is absent.
  #
  # Only #append and #load are required. The remaining methods are optional:
  # implementers may omit them, and the SDK probes for their presence via
  # SessionStore.implements? before invoking (it never uses `is_a?` for this —
  # a duck-typed adapter need not subclass SessionStore). The default
  # implementations here raise NotImplementedError so subclasses inherit them as
  # "absent" markers.
  #
  # All keys/entries cross the adapter boundary as Hashes with STRING keys:
  #   - SessionKey: { 'project_key' => String, 'session_id' => String,
  #                   'subpath' => String (optional; omit for the main transcript) }
  #   - entries: raw JSONL transcript objects (opaque pass-through blobs)
  #   - list_sessions result: [{ 'session_id' => String, 'mtime' => Integer }]
  #   - summary entries: { 'session_id', 'mtime', 'data' } (see SessionSummary)
  class SessionStore
    # True if +store+ overrides +method+ rather than inheriting the base
    # implementation that raises NotImplementedError. Works for both subclasses
    # and duck-typed adapters (whose method owner is their own class).
    def self.implements?(store, method)
      return false unless store.respond_to?(method)

      store.method(method).owner != SessionStore
    rescue NameError
      false
    end

    # Mirror a batch of transcript entries. Called AFTER the subprocess's local
    # write succeeds. Required.
    #
    # Appends for a given key are normally serialized by the batcher, but if an
    # #append exceeds the send timeout the batcher abandons that (still-running)
    # call and proceeds, so a later #append for the SAME key can overlap it.
    # Implementations must therefore be thread-safe per key (a per-call
    # connection — Postgres/Redis/etc. — satisfies this) and should dedupe by
    # entry["uuid"] when present, since a retried/overlapping batch may repeat
    # a prior write.
    def append(_key, _entries)
      raise NotImplementedError, "#{self.class} must implement #append"
    end

    # Load a full session for resume, or nil for a key that was never written.
    # Required.
    def load(_key)
      raise NotImplementedError, "#{self.class} must implement #load"
    end

    # List sessions for a project_key as [{ 'session_id', 'mtime' }]. Optional —
    # if unimplemented, list_sessions_from_store raises.
    def list_sessions(_project_key)
      raise NotImplementedError
    end

    # Return incrementally-maintained summaries for all sessions in one call.
    # Optional — if unimplemented, list_sessions_from_store falls back to
    # list_sessions + per-session load.
    def list_session_summaries(_project_key)
      raise NotImplementedError
    end

    # Delete a session. Deleting a main-transcript key (no subpath) must cascade
    # to all subkeys. Optional — if unimplemented, deletion is a no-op.
    def delete(_key)
      raise NotImplementedError
    end

    # List all subpath keys under a session (e.g. subagent transcripts).
    # Optional — if unimplemented, resume only materializes the main transcript.
    def list_subkeys(_key)
      raise NotImplementedError
    end
  end

  # In-memory SessionStore for testing and development. Data is lost when the
  # process exits — not suitable for production.
  class InMemorySessionStore < SessionStore
    def initialize
      super
      @store = {}
      @mtimes = {}
      @summaries = {}
      @last_mtime = 0
      # The SessionStore#append contract requires per-key thread-safety, and two
      # concurrent sessions can share one store (each with its own batcher and
      # semaphore, so nothing serializes appends across them). Guard all access.
      @mutex = Mutex.new
    end

    def append(key, entries)
      @mutex.synchronize do
        k = key_to_string(key)
        (@store[k] ||= []).concat(entries)
        now_ms = next_mtime
        # Maintain the per-session summary sidecar incrementally so
        # #list_session_summaries never re-reads. Subagent subpaths don't
        # contribute to the main session's summary.
        if main_transcript_key?(key)
          sk = [key['project_key'], key['session_id']]
          folded = SessionSummary.fold_session_summary(@summaries[sk], key, entries)
          # Stamp with this adapter's storage write time — the SAME clock
          # #list_sessions exposes, so the fast-path staleness check works.
          folded['mtime'] = now_ms
          @summaries[sk] = folded
        end
        @mtimes[k] = now_ms
      end
      nil
    end

    def load(key)
      @mutex.synchronize do
        entries = @store[key_to_string(key)]
        entries&.dup
      end
    end

    def list_sessions(project_key)
      prefix = "#{project_key}/"
      results = []
      @mutex.synchronize do
        @store.each_key do |k|
          next unless k.start_with?(prefix)

          rest = k[prefix.length..]
          # Only main transcripts (no subpath, so no second '/').
          results << { 'session_id' => rest, 'mtime' => @mtimes[k] || 0 } unless rest.include?('/')
        end
      end
      results
    end

    def list_session_summaries(project_key)
      @mutex.synchronize do
        # Return COPIES, not the internal summary objects: #load dups, so this
        # must too, or a caller mutating a returned summary's data would corrupt
        # the sidecar that the next fold builds on.
        @summaries.filter_map do |(pk, _sid), summary|
          next unless pk == project_key

          { 'session_id' => summary['session_id'], 'mtime' => summary['mtime'], 'data' => summary['data'].dup }
        end
      end
    end

    def delete(key)
      @mutex.synchronize do
        k = key_to_string(key)
        @store.delete(k)
        @mtimes.delete(k)
        # Deleting the main transcript cascades to its subkeys so they aren't
        # orphaned. A targeted delete with an explicit subpath removes only that
        # one entry. An empty-string subpath is treated as "no subpath" (main),
        # consistent with key_to_string / append, so it cascades like nil.
        next unless main_transcript_key?(key)

        @summaries.delete([key['project_key'], key['session_id']])
        prefix = "#{key['project_key']}/#{key['session_id']}/"
        @store.keys.select { |sk| sk.start_with?(prefix) }.each do |sk|
          @store.delete(sk)
          @mtimes.delete(sk)
        end
      end
      nil
    end

    def list_subkeys(key)
      prefix = "#{key['project_key']}/#{key['session_id']}/"
      @mutex.synchronize do
        @store.keys.select { |k| k.start_with?(prefix) }.map { |k| k[prefix.length..] }
      end
    end

    # -- Test helpers --

    # All entries for a key (empty array if absent).
    def get_entries(key)
      @mutex.synchronize { (@store[key_to_string(key)] || []).dup }
    end

    # Number of stored sessions (main transcripts only).
    def size
      @mutex.synchronize do
        @store.keys.count do |k|
          first_slash = k.index('/')
          first_slash && !k[(first_slash + 1)..].include?('/')
        end
      end
    end

    def clear
      @mutex.synchronize do
        @store.clear
        @mtimes.clear
        @summaries.clear
        @last_mtime = 0
      end
    end

    private

    # True for a main-transcript key: no subpath, or an empty-string subpath
    # (which key_to_string already folds into the main key).
    def main_transcript_key?(key)
      sub = key['subpath']
      sub.nil? || sub.empty?
    end

    def key_to_string(key)
      parts = [key['project_key'], key['session_id']]
      subpath = key['subpath']
      parts << subpath if subpath && !subpath.empty?
      parts.join('/')
    end

    # Storage write time in Unix epoch ms, strictly monotonically increasing so
    # back-to-back appends always produce distinct mtimes (real backends get
    # this from commit ordering).
    def next_mtime
      now_ms = (Time.now.to_f * 1000).to_i
      now_ms = @last_mtime + 1 if now_ms <= @last_mtime
      @last_mtime = now_ms
      now_ms
    end
  end

  # Internal SessionStore support functions (path mapping, option validation).
  module SessionStores
    module_function

    # Derive a SessionKey from an absolute transcript file path.
    #
    #   Main:     <projects_dir>/<project_key>/<session_id>.jsonl
    #   Subagent: <projects_dir>/<project_key>/<session_id>/subagents/agent-<id>.jsonl
    #
    # Returns nil if +file_path+ is not under +projects_dir+ or has an
    # unrecognized shape.
    def file_path_to_session_key(file_path, projects_dir)
      # A frame with a missing/non-String filePath would make Pathname.new raise
      # TypeError (not the ArgumentError handled below), which propagates out of
      # do_flush and drops the entire coalesced drain batch. Treat it as
      # "not under projects_dir" so only the bad frame is skipped.
      return nil unless file_path.is_a?(String) && !file_path.empty?

      begin
        rel = Pathname.new(file_path).relative_path_from(Pathname.new(projects_dir)).to_s
      rescue ArgumentError
        # Different drives on Windows — treat as "not under projects_dir".
        return nil
      end

      parts = rel.split('/')
      # Reject paths that escape projects_dir: a leading ".." *segment* (exact
      # match, so a legitimate dir like "..foo" still maps), the "." self-ref,
      # or an absolute path. Comparing parts[0] rather than rel.start_with?("..")
      # avoids the "..foo" false positive that would silently drop valid frames.
      return nil if parts.empty? || parts[0] == '..' || rel == '.' || Pathname.new(rel).absolute?
      return nil if parts.length < 2

      project_key = parts[0]
      second = parts[1]

      # Main transcript: <project_key>/<session_id>.jsonl
      return { 'project_key' => project_key, 'session_id' => second.delete_suffix('.jsonl') } if parts.length == 2 && second.end_with?('.jsonl')

      # Subagent transcript: <project_key>/<session_id>/subagents/.../agent-<id>.jsonl
      if parts.length >= 4
        subpath_parts = parts[2..]
        subpath_parts[-1] = subpath_parts[-1].delete_suffix('.jsonl')
        # Subpaths are always /-joined so keys are portable across platforms.
        return { 'project_key' => project_key, 'session_id' => second, 'subpath' => subpath_parts.join('/') }
      end

      nil
    end

    # Raise ArgumentError for invalid session_store option combinations. Called
    # before subprocess spawn so misconfiguration fails fast.
    def validate_session_store_options(options)
      store = options.session_store
      return if store.nil?

      flush = options.session_store_flush.to_s
      unless SESSION_STORE_FLUSH_MODES.include?(flush)
        raise ArgumentError,
              "invalid session_store_flush: #{options.session_store_flush.inspect} " \
              "(expected one of #{SESSION_STORE_FLUSH_MODES.join(', ')})"
      end

      # When resume is explicitly set, list_sessions is provably never called
      # (resume wins over continue), so a minimal store is fine.
      if options.continue_conversation && options.resume.nil? && !SessionStore.implements?(store, :list_sessions)
        raise ArgumentError,
              'continue_conversation with session_store requires the store to implement #list_sessions'
      end

      return unless options.enable_file_checkpointing

      raise ArgumentError,
            'session_store cannot be combined with enable_file_checkpointing ' \
            '(checkpoints are local-disk only and would diverge from the mirrored transcript)'
    end

    # Path to the rel-from base where session transcripts live, honoring a
    # CLAUDE_CONFIG_DIR override passed to the subprocess via options.env.
    # Mirrors Sessions#config_dir but consults an explicit env override first.
    def projects_dir(env_override = nil)
      override = env_override && (env_override['CLAUDE_CONFIG_DIR'] || env_override[:CLAUDE_CONFIG_DIR])
      base = override || Sessions.config_dir
      File.join(base, 'projects')
    end
  end
end
