# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'fiber_boundary'
require_relative 'sessions'
require_relative 'session_store'
require_relative 'transcript_mirror_batcher'

module ClaudeAgentSDK
  # Result of SessionResume.materialize_resume_session.
  #
  # +config_dir+ is a temp directory laid out like ~/.claude/ — point the
  # subprocess at it via CLAUDE_CONFIG_DIR. +resume_session_id+ is passed as
  # --resume. Call #cleanup after the subprocess exits to remove the temp dir.
  class MaterializedResume
    attr_reader :config_dir, :resume_session_id

    def initialize(config_dir:, resume_session_id:)
      @config_dir = config_dir
      @resume_session_id = resume_session_id
    end

    # Best-effort removal of the temp config dir (never raises).
    def cleanup
      SessionResume.rmtree_with_retry(@config_dir)
    end

    # Teardown when the transcript mirror dropped batches: the CLI's
    # authoritative transcript lives in this temp dir, and the store copy is
    # missing the dropped turns — deleting the dir would permanently lose
    # them. Keep the transcripts (projects/), remove the redacted credential
    # copies, and tell the user where the data is so they can import it into
    # the store manually. Never raises.
    def preserve_transcripts
      ['.credentials.json', '.claude.json'].each do |name|
        FileUtils.rm_f(File.join(@config_dir, name))
      end
      warn "Claude SDK: transcript mirror dropped batches; the session store copy is incomplete. " \
           "Preserving the session transcript under #{File.join(@config_dir, 'projects')} instead of " \
           'deleting it — import it into your session store, then remove the directory.'
    rescue StandardError => e
      warn "Claude SDK: failed to scrub preserved transcript dir #{@config_dir}: #{e.message}"
    end
  end

  # Materialize a SessionStore-backed resume into a temp CLAUDE_CONFIG_DIR.
  #
  # When `resume` (or `continue_conversation`) is paired with a `session_store`,
  # the session JSONL usually doesn't exist on local disk — it lives in the
  # store. The CLI only resumes from a local file. This module loads the session
  # from the store, writes it to a temp dir laid out like ~/.claude/, and returns
  # the path so the caller can point the subprocess at it via CLAUDE_CONFIG_DIR.
  module SessionResume # rubocop:disable Metrics/ModuleLength
    KEYCHAIN_SERVICE_NAME = 'Claude Code-credentials'
    KEYCHAIN_TIMEOUT_SECONDS = 5

    # SystemCallError classes that indicate a transiently-held handle (Windows
    # AV/indexer scanning a freshly-written file) or a recoverable resource
    # shortage (file-table exhaustion) rather than a permanent failure. EMFILE/
    # ENFILE are treated as transient so the backoff loop can succeed once
    # descriptors free up, matching the Python SDK's retryable errno set.
    RETRYABLE_RMTREE_ERRORS = [
      Errno::EBUSY, Errno::ENOTEMPTY, Errno::EPERM, Errno::EACCES, Errno::EMFILE, Errno::ENFILE
    ].freeze

    module_function

    # Return a copy of +options+ repointed at a materialized temp config dir:
    # CLAUDE_CONFIG_DIR in env, resume set to the materialized session id, and
    # continue_conversation cleared (already resolved to a concrete session id).
    def apply_materialized_options(options, materialized)
      options.dup_with(
        env: options.env.merge('CLAUDE_CONFIG_DIR' => materialized.config_dir.to_s),
        resume: materialized.resume_session_id,
        continue_conversation: false
      )
    end

    # Build a TranscriptMirrorBatcher for a configured session_store. Shared by
    # both entry points (Client#install_transcript_mirror and the one-shot
    # query()) so projects_dir resolution and the eager/batched threshold choice
    # live in one place. +env+ supplies the CLAUDE_CONFIG_DIR override used to
    # locate the projects dir (already repointed at the temp dir when resuming
    # from a store). Eager flush mode zeroes the buffer thresholds so every
    # transcript_mirror frame triggers a background flush.
    def build_mirror_batcher(store:, env:, on_error:, eager: false)
      TranscriptMirrorBatcher.new(
        store: store,
        projects_dir: SessionStores.projects_dir(env),
        on_error: on_error,
        max_pending_entries: eager ? 0 : TranscriptMirrorBatcher::MAX_PENDING_ENTRIES,
        max_pending_bytes: eager ? 0 : TranscriptMirrorBatcher::MAX_PENDING_BYTES
      )
    end

    # Load a session from options.session_store and write it to a temp dir.
    # Returns a MaterializedResume, or nil when no materialization is needed
    # (no store, no resume/continue, store has no entries, or the resolved
    # session id is not a valid UUID) — the caller then falls through to the
    # normal spawn path. Raises RuntimeError if a store call fails or times out.
    def materialize_resume_session(options)
      store = options.session_store
      return nil if store.nil?
      return nil if options.resume.nil? && !options.continue_conversation

      timeout_s = options.load_timeout_ms / 1000.0
      project_key = Sessions.project_key_for_directory(options.cwd)

      resolved =
        if options.resume
          # session_id is used as a path component below; reject non-UUIDs to
          # prevent traversal and match every other resume path.
          return nil unless options.resume.match?(Sessions::UUID_RE)

          load_candidate(store, project_key, options.resume, timeout_s)
        else
          resolve_continue_candidate(store, project_key, timeout_s)
        end
      return nil if resolved.nil?

      session_id, entries = resolved
      tmp_base = Dir.mktmpdir('claude-resume-')
      begin
        project_dir = File.join(tmp_base, 'projects', project_key)
        FileUtils.mkdir_p(project_dir)
        write_jsonl(File.join(project_dir, "#{session_id}.jsonl"), entries)

        # The subprocess runs with CLAUDE_CONFIG_DIR=tmp_base; copy auth config
        # so it can authenticate. Missing files are fine (API-key auth, etc.).
        copy_auth_files(tmp_base, options.env)

        materialize_subkeys(store, project_dir, project_key, session_id, timeout_s) if SessionStore.implements?(store, :list_subkeys)
      rescue Exception # rubocop:disable Lint/RescueException
        # Any failure after mkdtemp leaves tmp_base (which may already hold a
        # .credentials.json copy) on disk with no path for the caller to clean
        # up. Remove it before re-raising. Rescue Exception (not StandardError)
        # so reactor stop/cancel also triggers cleanup.
        rmtree_with_retry(tmp_base)
        raise
      end

      MaterializedResume.new(config_dir: tmp_base, resume_session_id: session_id)
    end

    # -- Helpers --

    # Load entries for session_id; return [session_id, entries] or nil if empty.
    def load_candidate(store, project_key, session_id, timeout_s)
      entries = with_timeout(timeout_s, "SessionStore#load for session #{session_id}") do
        store.load('project_key' => project_key, 'session_id' => session_id)
      end
      return nil if entries.nil? || entries.empty?

      [session_id, entries]
    end

    # Pick the most-recently-modified non-sidechain session. Sidechain
    # transcripts are mirrored as ordinary top-level keys and often have the
    # highest mtime, so walk newest->oldest and skip them so --continue resumes
    # the user's conversation, not a subagent's.
    def resolve_continue_candidate(store, project_key, timeout_s)
      sessions = with_timeout(timeout_s, 'SessionStore#list_sessions') do
        store.list_sessions(project_key)
      end
      return nil if sessions.nil? || sessions.empty?

      sessions.sort_by { |s| -sortable_mtime(s['mtime']) }.each do |cand|
        sid = cand['session_id']
        next unless sid.is_a?(String) && sid.match?(Sessions::UUID_RE)

        loaded = load_candidate(store, project_key, sid, timeout_s)
        next if loaded.nil?

        first = loaded[1][0]
        next if first.is_a?(Hash) && first['isSidechain'] == true

        return loaded
      end
      nil
    end

    # Adapters contractually report mtime as an epoch-ms Numeric (the
    # conformance suite asserts it), but SQL timestamps naturally arrive as
    # ISO-8601 Strings through JSON. Unary minus on a String is String#-@
    # (frozen-string dedup), so String mtimes sorted lexicographically
    # ASCENDING — --continue silently resumed the OLDEST session — and mixed
    # Integer/String lists raised a bare ArgumentError. Coerce defensively:
    # numeric strings and ISO-8601 both order correctly; anything else sorts
    # last rather than crashing resume.
    def sortable_mtime(value)
      case value
      when Numeric then value
      when String then Float(value, exception: false) || Sessions.parse_iso_timestamp_ms(value) || 0
      else 0
      end
    end

    # Run a store call (user code) on a plain thread bounded by timeout_s,
    # re-raising failures/timeouts as RuntimeError with context. The thread hop
    # (FiberBoundary with a timeout always hops) both keeps the async scheduler
    # out of the user's store code AND enforces load_timeout_ms unconditionally
    # — including when materialization runs outside an Async reactor, where a
    # direct call would let a hung adapter block connect forever. A timed-out
    # worker is left running (not killed) since it may still complete.
    def with_timeout(timeout_s, what, &block)
      FiberBoundary.invoke(timeout: timeout_s, &block)
    rescue FiberBoundary::JoinTimeout
      raise "#{what} timed out after #{(timeout_s * 1000).to_i}ms during resume materialization"
    rescue RuntimeError
      raise
    rescue StandardError => e
      raise "#{what} failed during resume materialization: #{e}"
    end

    # Stream-write entries as one compact JSON line each (mode 0600).
    def write_jsonl(path, entries)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, 'w') do |f|
        entries.each do |entry|
          f.write(JSON.generate(entry))
          f.write("\n")
        end
      end
      chmod_owner_only(path)
    end

    # Copy .credentials.json (refreshToken redacted) and .claude.json from the
    # caller's effective config locations so the resumed subprocess can auth.
    def copy_auth_files(tmp_base, opt_env)
      caller_config_dir = env_value(opt_env, 'CLAUDE_CONFIG_DIR')
      source_config_dir = caller_config_dir || File.join(Dir.home, '.claude')

      creds_json = read_file_if_present(File.join(source_config_dir, '.credentials.json'))

      # macOS default keeps OAuth tokens in the Keychain, not a file. Redirecting
      # CLAUDE_CONFIG_DIR changes the Keychain service suffix so the subprocess's
      # lookup misses; populate the plaintext file from the parent's Keychain.
      # Skipped when env-based auth or a custom config dir is already in play.
      if caller_config_dir.nil? && env_value(opt_env, 'ANTHROPIC_API_KEY').nil? &&
         env_value(opt_env, 'CLAUDE_CODE_OAUTH_TOKEN').nil?
        keychain = read_keychain_credentials
        creds_json = keychain unless keychain.nil?
      end

      write_redacted_credentials(creds_json, File.join(tmp_base, '.credentials.json'))

      claude_json_src = caller_config_dir ? File.join(caller_config_dir, '.claude.json') : File.join(Dir.home, '.claude.json')
      copy_if_present(claude_json_src, File.join(tmp_base, '.claude.json'))
    end

    # Write creds_json with claudeAiOauth.refreshToken removed. The resumed
    # subprocess runs under a redirected CLAUDE_CONFIG_DIR; if it refreshed, the
    # single-use refresh token would be consumed and the new tokens written
    # somewhere the parent never reads — revoking the parent's creds. Stripping
    # refreshToken short-circuits the subprocess's refresh check.
    def write_redacted_credentials(creds_json, dst)
      return if creds_json.nil?

      out = creds_json
      begin
        data = JSON.parse(creds_json)
        oauth = data.is_a?(Hash) ? data['claudeAiOauth'] : nil
        if oauth.is_a?(Hash) && oauth.key?('refreshToken')
          oauth.delete('refreshToken')
          out = JSON.generate(data)
        end
      rescue JSON::ParserError
        # Unparseable — write through; the subprocess will fail to parse it too.
      end
      File.write(dst, out)
      chmod_owner_only(dst)
    end

    # Read OAuth credentials JSON from the macOS Keychain (default service name).
    # Best-effort — returns nil on any error or non-macOS platforms.
    def read_keychain_credentials
      return nil unless RbConfig::CONFIG['host_os'].match?(/darwin/)

      user = (ENV['USER'] && !ENV['USER'].empty? ? ENV['USER'] : nil) || begin
        require 'etc'
        Etc.getlogin
      rescue StandardError
        'claude-code-user'
      end

      stdout, status = capture_with_timeout(
        ['security', 'find-generic-password', '-a', user, '-w', '-s', KEYCHAIN_SERVICE_NAME],
        KEYCHAIN_TIMEOUT_SECONDS
      )
      return nil if status.nil? || !status.success?

      out = stdout.to_s.strip
      out.empty? ? nil : out
    rescue StandardError
      nil
    end

    # Run a command with a hard timeout, draining stdout on a side thread and
    # SIGKILL-ing on deadline (Timeout.timeout is unsafe under the fiber
    # scheduler). Returns [stdout, status] or [nil, nil] on timeout/error.
    def capture_with_timeout(argv, timeout_s)
      stdin, stdout, stderr, wait_thr = Open3.popen3(*argv)
      stdin.close
      out_buf = +''
      out_reader = Thread.new { out_buf << stdout.read.to_s }
      err_reader = Thread.new { stderr.read }
      # Closing the pipes in `ensure` while a reader is mid-read raises IOError
      # in that thread; silence it (this is a best-effort credential bridge).
      out_reader.report_on_exception = false
      err_reader.report_on_exception = false

      if wait_thr.join(timeout_s)
        # The child has exited, so stdout has hit EOF: join with no short timeout
        # to fully drain out_buf before returning it, avoiding a truncated /
        # concurrently-mutated buffer (which would yield unparseable credentials).
        out_reader.join
        [out_buf, wait_thr.value]
      else
        begin
          Process.kill('KILL', wait_thr.pid)
        rescue Errno::ESRCH
          nil
        end
        wait_thr.join
        [nil, nil]
      end
    rescue StandardError
      [nil, nil]
    ensure
      out_reader&.kill if out_reader&.alive?
      err_reader&.kill if err_reader&.alive?
      [stdout, stderr].each { |io| io&.close rescue nil } # rubocop:disable Style/RescueModifier
    end

    # Load and write all subagent transcripts/metadata under session_id.
    def materialize_subkeys(store, project_dir, project_key, session_id, timeout_s)
      session_dir = File.join(project_dir, session_id)
      subkeys = with_timeout(timeout_s, "SessionStore#list_subkeys for session #{session_id}") do
        store.list_subkeys('project_key' => project_key, 'session_id' => session_id)
      end

      Array(subkeys).each do |subpath|
        # Subpaths come from an external store and become filesystem path
        # components — reject anything that would escape the session directory.
        unless safe_subpath?(subpath, session_dir)
          warn "Claude SDK: [SessionStore] skipping unsafe subpath from list_subkeys: #{subpath.inspect}"
          next
        end

        sub_entries = with_timeout(timeout_s, "SessionStore#load for session #{session_id} subpath #{subpath}") do
          store.load('project_key' => project_key, 'session_id' => session_id, 'subpath' => subpath)
        end
        next if sub_entries.nil? || sub_entries.empty?

        write_subagent_files(session_dir, subpath, sub_entries)
      end
    end

    # Partition entries into transcript vs agent_metadata and write the
    # <subpath>.jsonl transcript and, if present, the <subpath>.meta.json sidecar.
    def write_subagent_files(session_dir, subpath, entries)
      metadata, transcript = entries.partition { |e| e.is_a?(Hash) && e['type'] == 'agent_metadata' }
      sub_file = File.join(session_dir, "#{subpath}.jsonl")

      write_jsonl(sub_file, transcript) unless transcript.empty?

      return if metadata.empty?

      # Last metadata entry wins; strip the synthetic type field.
      meta_content = metadata.last.except('type')
      meta_file = "#{sub_file.delete_suffix('.jsonl')}.meta.json"
      FileUtils.mkdir_p(File.dirname(meta_file))
      File.write(meta_file, JSON.generate(meta_content))
      chmod_owner_only(meta_file)
    end

    # Reject subpaths that are empty, absolute, drive/UNC-prefixed, contain "."
    # or ".." components or a NUL byte, or escape session_dir after resolution.
    def safe_subpath?(subpath, session_dir)
      return false if subpath.nil? || subpath.empty?
      return false if subpath.start_with?('/', '\\')
      return false if subpath.match?(/\A[a-zA-Z]:/) # drive-prefixed (C:foo) / UNC
      return false if subpath.split(%r{[\\/]}).any? { |part| ['.', '..'].include?(part) }
      return false if subpath.include?("\u0000")

      base = resolve_dir(session_dir)
      # Join BEFORE expanding: expand_path on a relative first argument performs
      # tilde expansion, so a store-supplied "~nosuchuser/x" would raise
      # ArgumentError (and "~root/x" would resolve outside base even though the
      # literal path the writer uses is contained). The joined path is absolute,
      # so expand_path only normalizes it.
      target = File.expand_path(File.join(base, "#{subpath}.jsonl"))
      target == base || target.start_with?("#{base}#{File::SEPARATOR}")
    rescue ArgumentError
      false
    end

    def resolve_dir(dir)
      File.realpath(dir)
    rescue SystemCallError
      File.expand_path(dir)
    end

    # Best-effort recursive removal with retries on transient lock errors
    # (Windows AV/indexer). Never raises. The temp dir holds an access token, so
    # the final sweep matters for not leaking secrets.
    def rmtree_with_retry(path, retries: 4, delay: 0.1)
      return unless path && File.exist?(path)

      retries.times do
        begin
          FileUtils.remove_entry(path)
          return
        rescue Errno::ENOENT
          return
        rescue SystemCallError => e
          break unless RETRYABLE_RMTREE_ERRORS.any? { |klass| e.is_a?(klass) }
        end
        sleep(delay)
      end
      FileUtils.rm_rf(path)
    end

    def read_file_if_present(path)
      File.read(path)
    rescue SystemCallError
      nil
    end

    # Best-effort lock of a freshly-written materialized file to owner-only
    # (0600); silently ignores filesystems that reject chmod. These files can
    # hold a redacted .credentials.json / MCP-header secrets, so default to
    # owner-only rather than inheriting the umask.
    def chmod_owner_only(path)
      File.chmod(0o600, path)
    rescue SystemCallError
      nil
    end

    # Copy src to dst (locked to 0600) when src exists; no-op otherwise. The
    # only caller copies .claude.json, which can hold MCP-header secrets and
    # customApiKeyResponses, so it gets the same owner-only mode as the other
    # materialized files rather than inheriting the source's (often 0644) mode.
    def copy_if_present(src, dst)
      FileUtils.copy_file(src, dst)
      chmod_owner_only(dst)
    rescue SystemCallError
      nil
    end

    # Resolve the value the CHILD process will see for env var +name+. Presence
    # in options.env is detected by KEY: an explicit nil (or empty) value means
    # the transport unsets the var for the child, so resolve to nil rather than
    # falling back to the parent's environment (which the child won't inherit
    # for that key). Only an absent key consults the parent ENV.
    def env_value(opt_env, name)
      if opt_env.respond_to?(:key?) && (opt_env.key?(name) || opt_env.key?(name.to_sym))
        value = opt_env[name] || opt_env[name.to_sym]
        return nil if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        return value
      end

      value = ENV.fetch(name, nil)
      value && (!value.respond_to?(:empty?) || !value.empty?) ? value : nil
    end

    private_class_method :load_candidate, :resolve_continue_candidate, :sortable_mtime, :with_timeout, :write_jsonl,
                         :copy_auth_files, :write_redacted_credentials, :read_keychain_credentials,
                         :capture_with_timeout, :materialize_subkeys, :write_subagent_files,
                         :resolve_dir, :read_file_if_present, :chmod_owner_only, :copy_if_present, :env_value
  end
end
