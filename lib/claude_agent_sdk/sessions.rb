# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'
require_relative 'session_store'
require_relative 'session_summary'
require_relative 'transcript_mirror_batcher'

module ClaudeAgentSDK
  # Session info returned by list_sessions
  class SDKSessionInfo
    attr_accessor :session_id, :summary, :last_modified, :file_size,
                  :custom_title, :first_prompt, :git_branch, :cwd,
                  :tag, :created_at

    def initialize(session_id:, summary:, last_modified:, file_size: nil,
                   custom_title: nil, first_prompt: nil, git_branch: nil, cwd: nil,
                   tag: nil, created_at: nil)
      @session_id = session_id
      @summary = summary
      @last_modified = last_modified
      @file_size = file_size
      @custom_title = custom_title
      @first_prompt = first_prompt
      @git_branch = git_branch
      @cwd = cwd
      @tag = tag
      @created_at = created_at
    end
  end

  # A single message from a session transcript
  class SessionMessage
    attr_accessor :type, :uuid, :session_id, :message, :parent_tool_use_id

    def initialize(type:, uuid:, session_id:, message:, parent_tool_use_id: nil)
      @type = type
      @uuid = uuid
      @session_id = session_id
      @message = message
      @parent_tool_use_id = parent_tool_use_id
    end

    # Concatenated text across every TextBlock in this message.
    # Returns "" when the message has no text content (nil message,
    # non-Hash message, empty content, or only non-text blocks).
    def text
      raw = @message.is_a?(Hash) ? (@message['content'] || @message[:content]) : nil
      case raw
      when String then raw
      when Array  then content_blocks.grep(TextBlock).map(&:text).join("\n\n")
      else ''
      end
    end

    alias to_s text

    # Typed content blocks for this message. Each entry is one of
    # TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock, or
    # UnknownBlock (for forward-compatibility with newer CLI block types).
    # Returns [] when the message has no array-of-blocks content (nil
    # message, non-Hash message, String content, missing content).
    def content_blocks
      return [] unless @message.is_a?(Hash)

      raw = @message['content'] || @message[:content]
      return [] unless raw.is_a?(Array)

      raw.filter_map do |block|
        MessageParser.parse_content_block(block) if block.is_a?(Hash)
      end
    end
  end

  # Session browsing functions
  module Sessions # rubocop:disable Metrics/ModuleLength
    LITE_READ_BUF_SIZE = 65_536
    MAX_SANITIZED_LENGTH = 200

    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    # Transcript entry types that participate in conversation reads. One shared
    # constant for the disk (parse_jsonl_entries) and store
    # (filter_transcript_entries) paths so the two read paths can't drift when
    # the CLI adds a new entry type (mirrors Python's _TRANSCRIPT_ENTRY_TYPES).
    TRANSCRIPT_ENTRY_TYPES = %w[user assistant progress system attachment].freeze

    SKIP_FIRST_PROMPT_PATTERN = %r{\A(?:<local-command-stdout>|<session-start-hook>|<tick>|<goal>|
      \[Request\ interrupted\ by\ user[^\]]*\]|
      \s*<ide_opened_file>[\s\S]*</ide_opened_file>\s*\z|
      \s*<ide_selection>[\s\S]*</ide_selection>\s*\z)}x

    COMMAND_NAME_RE = %r{<command-name>(.*?)</command-name>}

    SANITIZE_RE = /[^a-zA-Z0-9]/

    module_function

    # Match TypeScript's simpleHash: signed 32-bit integer, base-36 output.
    # JS's charCodeAt returns UTF-16 code units, so supplementary characters
    # (emoji, CJK extensions) emit two surrogate code units — iterate over
    # UTF-16LE shorts instead of Unicode codepoints to preserve parity.
    def simple_hash(str)
      h = 0
      str.encode('UTF-16LE').unpack('v*').each do |char_code|
        h = ((h << 5) - h + char_code) & 0xFFFFFFFF
        h -= 0x100000000 if h >= 0x80000000
      end
      h = h.abs

      return '0' if h.zero?

      digits = '0123456789abcdefghijklmnopqrstuvwxyz'
      out = []
      n = h
      while n.positive?
        out.unshift(digits[n % 36])
        n /= 36
      end
      out.join
    end

    # Sanitize a filesystem path to a project directory name
    def sanitize_path(name)
      sanitized = name.gsub(SANITIZE_RE, '-')
      return sanitized if sanitized.length <= MAX_SANITIZED_LENGTH

      "#{sanitized[0, MAX_SANITIZED_LENGTH]}-#{simple_hash(name)}"
    end

    # Resolve a directory to its canonical form (realpath + NFC), matching the
    # CLI's project-directory naming. Falls back to an absolute NFC path when
    # realpath can't resolve it (e.g. the directory does not exist yet) — Ruby's
    # File.realpath raises on missing paths whereas Python's os.path.realpath is
    # lexical for the missing suffix, so expand_path restores that behavior.
    def canonicalize_path(dir)
      File.realpath(dir).unicode_normalize(:nfc)
    rescue SystemCallError
      File.expand_path(dir).unicode_normalize(:nfc)
    end

    # Derive the SessionStore +project_key+ for a directory (default: cwd).
    #
    # Uses the same realpath + NFC normalization + djb2-hashed sanitization the
    # CLI uses for project directory names, so keys match between local-disk
    # transcripts and store-mirrored transcripts even on filesystems that
    # decompose Unicode (macOS HFS+).
    #
    # @param directory [String, Pathname, nil] Directory to key (nil = cwd)
    # @return [String] The project key
    def project_key_for_directory(directory = nil)
      sanitize_path(canonicalize_path(directory.nil? ? '.' : directory.to_s))
    end

    # Get the Claude config directory
    def config_dir
      ENV.fetch('CLAUDE_CONFIG_DIR', File.expand_path('~/.claude'))
    end

    # Find the project directory for a given path
    def find_project_dir(path)
      projects_dir = File.join(config_dir, 'projects')
      return nil unless File.directory?(projects_dir)

      sanitized = sanitize_path(path)
      exact_path = File.join(projects_dir, sanitized)
      return exact_path if File.directory?(exact_path)

      # For long paths, scan for prefix match
      if sanitized.length > MAX_SANITIZED_LENGTH
        prefix = sanitized[0, MAX_SANITIZED_LENGTH + 1] # includes the trailing '-'
        Dir.children(projects_dir).each do |child|
          candidate = File.join(projects_dir, child)
          return candidate if File.directory?(candidate) && child.start_with?(prefix)
        end
      end

      nil
    end

    # Extract a JSON string field value from raw text without full JSON parse
    def extract_json_string_field(text, key, last: false)
      search_patterns = ["\"#{key}\":\"", "\"#{key}\": \""]
      result = nil

      search_patterns.each do |pattern|
        pos = 0
        loop do
          idx = text.index(pattern, pos)
          break unless idx

          value_start = idx + pattern.length
          value = extract_json_string_value(text, value_start)
          if value
            result = unescape_json_string(value)
            return result unless last
          end
          pos = value_start
        end
      end

      result
    end

    # Extract string value starting at pos (handles escapes)
    def extract_json_string_value(text, start)
      pos = start
      while pos < text.length
        ch = text[pos]
        if ch == '\\'
          pos += 2
        elsif ch == '"'
          return text[start...pos]
        else
          pos += 1
        end
      end
      nil
    end

    # Unescape a JSON string value
    def unescape_json_string(str)
      JSON.parse("\"#{str}\"")
    rescue JSON::ParserError
      str
    end

    # Extract the first meaningful user prompt from the head of a JSONL file
    def extract_first_prompt_from_head(head)
      command_fallback = nil

      head.each_line do |line|
        next unless line.include?('"type":"user"') || line.include?('"type": "user"')
        next if line.include?('"tool_result"')
        next if line.include?('"isMeta":true') || line.include?('"isMeta": true')
        next if line.include?('"isCompactSummary":true') || line.include?('"isCompactSummary": true')

        entry = JSON.parse(line, symbolize_names: false)
        content = entry.dig('message', 'content')
        next unless content

        texts = if content.is_a?(String)
                  [content]
                elsif content.is_a?(Array)
                  content.filter_map { |block| block['text'] if block.is_a?(Hash) && block['type'] == 'text' }
                else
                  next
                end

        texts.each do |text|
          text = text.gsub(/\n+/, ' ').strip
          next if text.empty?

          if (m = text.match(COMMAND_NAME_RE))
            command_fallback ||= m[1]
            next
          end

          next if text.match?(SKIP_FIRST_PROMPT_PATTERN)

          return text.length > 200 ? "#{text[0, 200]}…" : text
        end
      rescue JSON::ParserError
        next
      end

      command_fallback || ''
    end

    # Read a single session file with lite (head/tail) strategy
    def read_session_lite(file_path, project_path)
      stat = File.stat(file_path)
      return nil if stat.size.zero? # rubocop:disable Style/ZeroLengthPredicate

      head, tail = read_head_tail(file_path, stat.size)

      # Check first line for sidechain
      first_line = head.lines.first || ''
      return nil if first_line.include?('"isSidechain":true') || first_line.include?('"isSidechain": true')

      build_session_info(file_path, head, tail, stat, project_path)
    rescue StandardError
      nil
    end

    def read_head_tail(file_path, size)
      head = tail = nil
      File.open(file_path, 'rb') do |f|
        head = (f.read(LITE_READ_BUF_SIZE) || '').force_encoding('UTF-8')
        tail = if size > LITE_READ_BUF_SIZE
                 f.seek([0, size - LITE_READ_BUF_SIZE].max)
                 (f.read(LITE_READ_BUF_SIZE) || '').force_encoding('UTF-8')
               else
                 head
               end
      end
      [head, tail]
    end

    def build_session_info(file_path, head, tail, stat, project_path)
      # User-set title (customTitle) wins over AI-generated title (aiTitle).
      # Head fallback covers short sessions where the title entry may not be in tail.
      custom_title = extract_json_string_field(tail, 'customTitle', last: true) ||
                     extract_json_string_field(head, 'customTitle', last: true) ||
                     extract_json_string_field(tail, 'aiTitle', last: true) ||
                     extract_json_string_field(head, 'aiTitle', last: true)
      first_prompt = extract_first_prompt_from_head(head)
      # lastPrompt tail entry shows what the user was most recently doing.
      summary = custom_title ||
                extract_json_string_field(tail, 'lastPrompt', last: true) ||
                extract_json_string_field(tail, 'summary', last: true) ||
                first_prompt
      return nil if summary.nil? || summary.strip.empty?

      # Scope tag extraction to {"type":"tag"} lines — a bare tail scan for
      # "tag" would match tool_use inputs (git tag, Docker tags, etc.).
      tag_line = tail.lines.reverse.find { |ln| ln.start_with?('{"type":"tag"') }
      tag_value = tag_line ? extract_json_string_field(tag_line, 'tag', last: true) : nil
      tag_value = nil if tag_value && tag_value.empty?

      # created_at from first entry's ISO timestamp (epoch ms). More reliable
      # than stat().birthtime which is unsupported on some filesystems.
      first_line = head.lines.first || ''
      first_timestamp = extract_json_string_field(first_line, 'timestamp', last: false)
      created_at = parse_iso_timestamp_ms(first_timestamp) if first_timestamp

      SDKSessionInfo.new(
        session_id: File.basename(file_path, '.jsonl'),
        summary: summary,
        last_modified: (stat.mtime.to_f * 1000).to_i,
        file_size: stat.size,
        custom_title: custom_title,
        first_prompt: first_prompt,
        git_branch: extract_json_string_field(tail, 'gitBranch', last: true) ||
                    extract_json_string_field(head, 'gitBranch', last: false),
        cwd: extract_json_string_field(head, 'cwd', last: false) || project_path,
        tag: tag_value,
        created_at: created_at
      )
    end

    # Parse an ISO 8601 timestamp string into epoch milliseconds
    def parse_iso_timestamp_ms(timestamp_str)
      # Entries are opaque external blobs: a non-String timestamp (e.g. an epoch
      # integer) makes Time.iso8601 raise TypeError, which the ArgumentError
      # rescue would NOT catch and which would escape callers like
      # mtime_from_entries / get_session_info_from_store. Guard the type first.
      return nil unless timestamp_str.is_a?(String)

      require 'time'
      (Time.iso8601(timestamp_str).to_f * 1000).to_i
    rescue ArgumentError
      nil
    end

    # Read all sessions from a project directory
    def read_sessions_from_dir(project_dir, project_path = nil)
      return [] unless File.directory?(project_dir)

      sessions = []
      Dir.glob(File.join(project_dir, '*.jsonl')).each do |file_path|
        stem = File.basename(file_path, '.jsonl')
        next unless stem.match?(UUID_RE)

        session = read_session_lite(file_path, project_path)
        sessions << session if session
      end
      sessions
    end

    # List sessions for a directory (or all sessions)
    # @param directory [String, nil] Working directory to list sessions for
    # @param limit [Integer, nil] Maximum number of sessions to return
    # @param offset [Integer] Number of sessions to skip (for pagination)
    # @param include_worktrees [Boolean] Whether to include git worktree sessions
    # @return [Array<SDKSessionInfo>] Sessions sorted by last_modified descending
    def list_sessions(directory: nil, limit: nil, offset: 0, include_worktrees: true)
      offset ||= 0
      sessions = if directory
                   list_sessions_for_directory(directory, include_worktrees)
                 else
                   list_all_sessions
                 end

      # Sort by last_modified descending, then apply offset and limit.
      # [limit, 0].max: limit <= 0 yields [] across the whole read-API family
      # (a bare first(-1) would raise ArgumentError here but silently clamp on
      # the store paths).
      sessions.sort_by! { |s| -s.last_modified }
      sessions = sessions[offset..] || [] if offset.positive?
      sessions = sessions.first([limit, 0].max) if limit
      sessions
    end

    # Read metadata for a single session by ID without a full directory scan.
    #
    # @param session_id [String] UUID of the session to look up
    # @param directory [String, nil] Project directory path. When nil, all
    #   project directories are searched.
    # @return [SDKSessionInfo, nil] Session info, or nil if not found / sidechain / no summary
    def get_session_info(session_id:, directory: nil)
      return nil unless session_id.match?(UUID_RE)

      file_name = "#{session_id}.jsonl"
      return get_session_info_for_directory(file_name, directory) if directory

      # No directory — search all project directories.
      projects_dir = File.join(config_dir, 'projects')
      return nil unless File.directory?(projects_dir)

      Dir.children(projects_dir).each do |child|
        entry = File.join(projects_dir, child)
        next unless File.directory?(entry)

        info = read_session_lite(File.join(entry, file_name), nil)
        return info if info
      end
      nil
    end

    # Get messages from a session transcript
    # @param session_id [String] The session UUID
    # @param directory [String, nil] Working directory to search in
    # @param limit [Integer, nil] Maximum number of messages
    # @param offset [Integer] Number of messages to skip
    # @return [Array<SessionMessage>] Ordered messages from the session
    def get_session_messages(session_id:, directory: nil, limit: nil, offset: 0)
      return [] unless session_id.match?(UUID_RE)

      offset ||= 0

      file_path = find_session_file(session_id, directory)
      return [] unless file_path && File.exist?(file_path)

      entries = parse_jsonl_entries(file_path)
      chain = build_conversation_chain(entries)
      messages = filter_visible_messages(chain)

      # Apply offset and limit (limit <= 0 yields [], like every other reader)
      messages = messages[offset..] || []
      messages = messages.first([limit, 0].max) if limit
      messages
    end

    # ---- SessionStore-backed reads (store counterparts to the disk readers) ----

    # List sessions from a SessionStore. Store-backed counterpart to
    # list_sessions. Uses the store's incremental summaries (one batch call +
    # gap-fill) when available, else falls back to list_sessions + one load per
    # session. Sessions are derived through the same fold the disk path uses, so
    # both paths agree for identical transcript content.
    #
    # @param session_store [SessionStore] store implementing list_session_summaries and/or list_sessions
    # @return [Array<SDKSessionInfo>] sorted by last_modified descending
    def list_sessions_from_store(session_store:, directory: nil, limit: nil, offset: 0)
      offset ||= 0
      project_path = canonicalize_path(directory.nil? ? '.' : directory.to_s)
      project_key = sanitize_path(project_path)

      if SessionStore.implements?(session_store, :list_session_summaries)
        via = list_sessions_via_summaries(session_store, project_key, project_path, limit, offset)
        return via unless via.nil?
      end

      unless SessionStore.implements?(session_store, :list_sessions)
        raise ArgumentError,
              'session_store implements neither list_session_summaries nor list_sessions -- cannot list sessions'
      end

      listing = Array(session_store.list_sessions(project_key))
      # Build all-placeholder slots (the shape the summaries fast path uses) and
      # reuse its bounded pagination: sessions are loaded newest-first only
      # until the page fills (~offset + limit + dropped), instead of one full
      # transcript load per listed session before pagination — the sort key
      # (the listing mtime) is known before any load.
      slots = listing.filter_map do |entry|
        sid = entry['session_id']
        next if sid.nil?

        { mtime: entry['mtime'] || 0, session_id: sid, info: nil }
      end
      slots.sort_by! { |slot| -slot[:mtime] }
      paginate_resolving_gaps(session_store, project_key, project_path, slots, limit, offset)
    end

    # Read metadata for a single session from a SessionStore. Store-backed
    # counterpart to get_session_info. Returns nil for an invalid UUID, an
    # unknown session, a sidechain session, or one with no extractable summary.
    def get_session_info_from_store(session_store:, session_id:, directory: nil)
      return nil unless session_id.match?(UUID_RE)

      project_path = canonicalize_path(directory.nil? ? '.' : directory.to_s)
      entries = session_store.load('project_key' => sanitize_path(project_path), 'session_id' => session_id)
      return nil if entries.nil? || entries.empty?

      derive_info_from_entries(session_id, entries, mtime_from_entries(entries), project_path)
    end

    # Read a session's conversation messages from a SessionStore. Store-backed
    # counterpart to get_session_messages.
    def get_session_messages_from_store(session_store:, session_id:, directory: nil, limit: nil, offset: 0)
      return [] unless session_id.match?(UUID_RE)

      offset ||= 0
      entries = session_store.load('project_key' => project_key_for_directory(directory), 'session_id' => session_id)
      return [] if entries.nil? || entries.empty?

      entries_to_messages(filter_transcript_entries(entries), limit, offset)
    end

    # List subagent IDs for a session from a SessionStore. Requires the store to
    # implement list_subkeys.
    def list_subagents_from_store(session_store:, session_id:, directory: nil)
      return [] unless session_id.match?(UUID_RE)

      unless SessionStore.implements?(session_store, :list_subkeys)
        raise ArgumentError,
              'session_store does not implement list_subkeys -- cannot list subagents'
      end

      project_key = project_key_for_directory(directory)
      subkeys = Array(session_store.list_subkeys('project_key' => project_key, 'session_id' => session_id))
      seen = {}
      subkeys.filter_map do |subpath|
        next unless subpath.start_with?('subagents/')

        last = subpath.rpartition('/').last
        next unless last.start_with?('agent-')

        agent_id = last.delete_prefix('agent-')
        next if seen[agent_id]

        seen[agent_id] = true
        agent_id
      end
    end

    # Read a subagent's conversation messages from a SessionStore. Subagents may
    # live at subagents/agent-<id> or nested under
    # subagents/workflows/<runId>/agent-<id>; scans subkeys to resolve the path
    # when the store implements list_subkeys, else tries the direct path.
    def get_subagent_messages_from_store(session_store:, session_id:, agent_id:, directory: nil, limit: nil, offset: 0)
      return [] unless session_id.match?(UUID_RE)
      return [] if agent_id.nil? || agent_id.empty?

      project_key = project_key_for_directory(directory)
      subpath = resolve_subagent_subpath(session_store, project_key, session_id, agent_id)
      return [] if subpath.nil?

      entries = session_store.load('project_key' => project_key, 'session_id' => session_id, 'subpath' => subpath)
      return [] if entries.nil? || entries.empty?

      # Drop synthetic agent_metadata entries (they describe the .meta.json
      # sidecar, not transcript lines).
      transcript = entries.reject { |e| e.is_a?(Hash) && e['type'] == 'agent_metadata' }
      return [] if transcript.empty?

      entries_to_subagent_messages(filter_transcript_entries(transcript), limit, offset)
    end

    # Replay a local on-disk session transcript into a SessionStore (inverse of
    # resume materialization). Streams the JSONL line-by-line and appends in
    # batches. Keys under the on-disk project directory name so the imported
    # session is indistinguishable from a live-mirrored one and resumable via
    # session_store + resume from the original cwd. Adapters should treat
    # entry["uuid"] as an idempotency key so re-import is duplicate-safe.
    #
    # @raise [ArgumentError] if session_id is not a valid UUID
    # @raise [Errno::ENOENT] if the session JSONL cannot be found
    def import_session_to_store(session_id:, session_store:, directory: nil, include_subagents: true,
                                batch_size: TranscriptMirrorBatcher::MAX_PENDING_ENTRIES)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless session_id.match?(UUID_RE)

      resolved = find_session_file(session_id, directory)
      raise Errno::ENOENT, "Session #{session_id} not found" if resolved.nil? || !File.exist?(resolved)

      # Key under the on-disk project directory name — matches
      # file_path_to_session_key / TranscriptMirrorBatcher even when the resolver
      # found the file via worktree fallback or a global scan.
      project_key = File.basename(File.dirname(resolved))
      # &.: an explicit batch_size: nil gets the default too, instead of
      # crashing on nil.positive? (matches the nil-tolerant limit:/offset:
      # convention across this API family).
      batch_size = TranscriptMirrorBatcher::MAX_PENDING_ENTRIES unless batch_size&.positive?

      append_jsonl_file_in_batches(resolved, { 'project_key' => project_key, 'session_id' => session_id },
                                   session_store, batch_size)
      return unless include_subagents

      import_subagent_files(resolved, project_key, session_id, session_store, batch_size)
    end

    # -- Private helpers --

    # Summary fast-path for list_sessions_from_store. Returns the paginated
    # result, or nil if the store's list_session_summaries raises
    # NotImplementedError (caller falls back to the slow path). Sessions missing
    # a sidecar or whose sidecar is stale (summary.mtime < the session's current
    # mtime) are routed through gap-fill so the fold is recomputed from source.
    def list_sessions_via_summaries(store, project_key, project_path, limit, offset)
      begin
        # Array(): a non-conformant store returning nil (e.g. a NULL JSONB read)
        # degrades to gap-fill instead of crashing on nil.each, matching the
        # defensive Array() already applied to list_sessions / list_subkeys.
        summaries = Array(store.list_session_summaries(project_key))
      rescue NotImplementedError
        return nil
      end

      has_list_sessions = SessionStore.implements?(store, :list_sessions)
      listing = has_list_sessions ? Array(store.list_sessions(project_key)) : []
      known_mtimes = listing.to_h { |e| [e['session_id'], e['mtime']] }

      slots = []
      fresh = {}
      summaries.each do |summary|
        sid = summary['session_id']
        # || 0: a non-conformant adapter's missing mtime degrades to gap-fill, not a crash.
        s_mtime = summary['mtime'] || 0
        if has_list_sessions
          known = known_mtimes[sid]
          # known.nil?: no longer listed (drop). s_mtime < known: stale sidecar (re-fold).
          next if known.nil? || s_mtime < known
        end
        fresh[sid] = true
        info = SessionSummary.summary_entry_to_sdk_info(summary, project_path)
        slots << { mtime: s_mtime, info: info } unless info.nil?
      end
      listing.each do |e|
        next if fresh[e['session_id']]

        slots << { mtime: e['mtime'] || 0, session_id: e['session_id'], info: nil }
      end

      slots.sort_by! { |slot| -slot[:mtime] }
      paginate_resolving_gaps(store, project_key, project_path, slots, limit, offset)
    end

    # Walk slots newest-first, resolving gap-fill placeholders (info nil) on
    # demand and skipping any that resolve to sidechain / no-summary, then apply
    # offset/limit to the RESOLVED results. Paginating over surviving sessions
    # (not raw slots) matches the disk reader, so a placeholder that drops never
    # leaves a short page; loads stay bounded to ~offset + limit + (the dropped
    # placeholders encountered before the page fills), preserving the fast
    # path's "don't load every session" intent.
    def paginate_resolving_gaps(store, project_key, project_path, slots, limit, offset)
      offset = 0 unless offset&.positive?
      results = []
      skipped = 0
      slots.each do |slot|
        # Stop once we have `limit` results. Checking before resolving avoids an
        # extra gap-fill load, and treats limit <= 0 as "at most none" so limit:0
        # yields [] — consistent with apply_sort_limit_offset and the disk
        # readers, instead of the old limit&.positive? which ignored a 0 limit.
        break if limit && results.length >= [limit, 0].max

        info = slot[:info] || resolve_gap_slot(store, project_key, project_path, slot)
        next if info.nil?

        if skipped < offset
          skipped += 1
          next
        end
        results << info
      end
      results
    end

    # Load + fold one placeholder slot into an SDKSessionInfo, or nil when the
    # session is absent / sidechain / has no extractable summary.
    def resolve_gap_slot(store, project_key, project_path, slot)
      sid = slot[:session_id]
      return nil if sid.nil?

      begin
        entries = store.load('project_key' => project_key, 'session_id' => sid)
      rescue StandardError => e
        # One failing gap-fill load degrades to an empty-summary row (kept, with
        # its mtime) rather than aborting the whole listing — matches the disk
        # path's per-file rescue and the store path's degrade-the-row contract.
        warn "Claude SDK: [SessionStore] gap-fill load failed for session #{sid}: #{e.message}"
        return SDKSessionInfo.new(session_id: sid, summary: '', last_modified: slot[:mtime])
      end
      return nil if entries.nil? || entries.empty?

      derive_info_from_entries(sid, entries, slot[:mtime], project_path)
    end

    # Fold store entries into an SDKSessionInfo, stamping the given mtime.
    def derive_info_from_entries(session_id, entries, mtime, project_path)
      summary = SessionSummary.fold_session_summary(nil, { 'session_id' => session_id }, entries)
      summary['mtime'] = mtime
      SessionSummary.summary_entry_to_sdk_info(summary, project_path)
    end

    # Last parseable entry timestamp (epoch ms), scanning from the tail; 0 if none.
    def mtime_from_entries(entries)
      entries.reverse_each do |entry|
        next unless entry.is_a?(Hash) && entry['timestamp']

        ms = parse_iso_timestamp_ms(entry['timestamp'])
        return ms if ms
      end
      0
    end

    def apply_sort_limit_offset(results, limit, offset)
      results = results.sort_by { |s| -s.last_modified }
      results = results[offset..] || [] if offset.positive?
      # A non-nil limit caps the result. limit <= 0 yields [] (matching the disk
      # readers' `first(limit) if limit` and entries_to_messages), and the
      # `.max` keeps a negative limit from raising in Array#first.
      results = results.first([limit, 0].max) if limit
      results
    end

    def filter_transcript_entries(entries)
      entries.select { |e| e.is_a?(Hash) && TRANSCRIPT_ENTRY_TYPES.include?(e['type']) && e['uuid'].is_a?(String) }
    end

    def entries_to_messages(entries, limit, offset)
      offset ||= 0
      messages = filter_visible_messages(build_conversation_chain(entries))
      messages = messages[offset..] || []
      messages = messages.first([limit, 0].max) if limit
      messages
    end

    # Subagent counterpart to entries_to_messages. Subagent transcripts are
    # simpler than main sessions — no compaction and no sidechains to exclude;
    # every CLI-written subagent entry CARRIES isSidechain: true, so the main
    # pipeline (build_conversation_chain rejects sidechain leaves and
    # filter_visible_messages drops sidechain entries) would return [] for
    # every real subagent transcript. Mirrors Python's
    # _entries_to_subagent_messages: type-only filter, no flag rejection.
    def entries_to_subagent_messages(entries, limit, offset)
      offset ||= 0
      messages = build_subagent_chain(entries).filter_map do |entry|
        next unless %w[user assistant].include?(entry['type'])

        SessionMessage.new(
          type: entry['type'],
          uuid: entry['uuid'],
          session_id: entry['sessionId'] || entry['session_id'] || '',
          message: entry['message']
        )
      end
      messages = messages[offset..] || []
      messages = messages.first([limit, 0].max) if limit
      messages
    end

    # Find the last user/assistant entry and walk parentUuid links back to the
    # root (subagent transcripts are linear). Mirrors Python's
    # _build_subagent_chain.
    def build_subagent_chain(entries)
      return [] if entries.empty?

      by_uuid = entries.to_h { |e| [e['uuid'], e] }
      leaf = entries.reverse_each.find { |e| %w[user assistant].include?(e['type']) }
      leaf ? walk_to_root(by_uuid, leaf) : []
    end

    # Find the subpath for a subagent, scanning subkeys (subagents may be nested
    # under subagents/workflows/<runId>/agent-<id>) when list_subkeys is
    # available, else falling back to the direct subagents/agent-<id> path.
    def resolve_subagent_subpath(store, project_key, session_id, agent_id)
      return "subagents/agent-#{agent_id}" unless SessionStore.implements?(store, :list_subkeys)

      target = "agent-#{agent_id}"
      matches = Array(store.list_subkeys('project_key' => project_key, 'session_id' => session_id))
                .select { |sk| sk.start_with?('subagents/') && sk.rpartition('/').last == target }
      # Several subpaths can share a trailing agent-<id> (a top-level agent and a
      # nested subagents/workflows/<run>/agent-<id>). Prefer the canonical
      # top-level path, else pick deterministically (shortest, then lexical) so
      # the result never depends on the store's list_subkeys ordering.
      return "subagents/#{target}" if matches.include?("subagents/#{target}")

      matches.min_by { |sk| [sk.length, sk] }
    end

    # Import subagent transcripts (and their .meta.json sidecars) under
    # <projectDir>/<sessionId>/subagents/**. The on-disk .jsonl lacks
    # agent_metadata entries (those are sent only to live mirrors); re-inject
    # the sidecar as an agent_metadata entry so resume can recreate it.
    def import_subagent_files(resolved, project_key, session_id, store, batch_size)
      session_dir = resolved.delete_suffix('.jsonl')
      collect_jsonl_files(File.join(session_dir, 'subagents')).each do |file_path|
        rel = file_path.delete_prefix("#{session_dir}#{File::SEPARATOR}")
        subpath = rel.delete_suffix('.jsonl').split(File::SEPARATOR).join('/')
        sub_key = { 'project_key' => project_key, 'session_id' => session_id, 'subpath' => subpath }
        append_jsonl_file_in_batches(file_path, sub_key, store, batch_size)

        meta_text = begin
          File.read("#{file_path.delete_suffix('.jsonl')}.meta.json", encoding: 'UTF-8')
        rescue Errno::ENOENT
          nil
        end
        next if meta_text.nil?

        meta = JSON.parse(meta_text)
        # Synthetic 'agent_metadata' marker must always win so a future meta key
        # named 'type' can't reclassify the sidecar as a transcript line on resume.
        store.append(sub_key, [meta.merge('type' => 'agent_metadata')]) if meta.is_a?(Hash)
      end
    end

    def append_jsonl_file_in_batches(file_path, key, store, batch_size)
      batch = []
      nbytes = 0
      # encoding: transcripts are UTF-8 regardless of locale; without it a
      # LANG=C process raises Encoding::InvalidByteSequenceError on the first
      # multibyte line, aborting the import mid-way (Python pins utf-8 here).
      File.foreach(file_path, encoding: 'UTF-8') do |line|
        line = line.chomp
        next if line.empty?

        batch << JSON.parse(line)
        nbytes += line.bytesize
        next unless batch.length >= batch_size || nbytes >= TranscriptMirrorBatcher::MAX_PENDING_BYTES

        store.append(key, batch)
        batch = []
        nbytes = 0
      end
      store.append(key, batch) unless batch.empty?
    end

    # Recursively collect *.jsonl paths under base_dir, sorted per directory for
    # deterministic import order. Empty when base_dir is absent or unreadable —
    # SystemCallError (Ruby's Errno umbrella, the analog of Python's OSError
    # guard here) must not abort the import after the main transcript was
    # already appended.
    def collect_jsonl_files(base_dir)
      return [] unless File.directory?(base_dir)

      begin
        children = Dir.children(base_dir).sort
      rescue SystemCallError
        return []
      end

      children.flat_map do |name|
        path = File.join(base_dir, name)
        if File.directory?(path)
          collect_jsonl_files(path)
        elsif File.file?(path) && name.end_with?('.jsonl')
          [path]
        else
          []
        end
      end
    end

    def get_session_info_for_directory(file_name, directory)
      canonical = File.realpath(directory).unicode_normalize(:nfc)
      project_dir = find_project_dir(canonical)
      if project_dir
        info = read_session_lite(File.join(project_dir, file_name), canonical)
        return info if info
      end

      # Worktree fallback — matches get_session_messages semantics.
      worktree_paths = detect_worktrees(canonical) rescue [] # rubocop:disable Style/RescueModifier
      worktree_paths.each do |wt_path|
        next if wt_path == canonical

        wt_project_dir = find_project_dir(wt_path)
        next unless wt_project_dir

        info = read_session_lite(File.join(wt_project_dir, file_name), wt_path)
        return info if info
      end
      nil
    end

    def list_sessions_for_directory(directory, include_worktrees)
      path = File.realpath(directory).unicode_normalize(:nfc)

      worktree_paths = []
      worktree_paths = detect_worktrees(path) if include_worktrees

      if worktree_paths.length <= 1
        project_dir = find_project_dir(path)
        return project_dir ? read_sessions_from_dir(project_dir, path) : []
      end

      # Multiple worktrees: scan all project dirs for matches
      all_sessions = []
      worktree_paths.each do |wt_path|
        project_dir = find_project_dir(wt_path)
        next unless project_dir

        all_sessions.concat(read_sessions_from_dir(project_dir, wt_path))
      end

      deduplicate_sessions(all_sessions)
    end

    def list_all_sessions
      projects_dir = File.join(config_dir, 'projects')
      return [] unless File.directory?(projects_dir)

      all_sessions = []
      Dir.children(projects_dir).each do |child|
        dir = File.join(projects_dir, child)
        next unless File.directory?(dir)

        all_sessions.concat(read_sessions_from_dir(dir))
      end

      deduplicate_sessions(all_sessions)
    end

    def deduplicate_sessions(sessions)
      by_id = {}
      sessions.each do |s|
        existing = by_id[s.session_id]
        by_id[s.session_id] = s if existing.nil? || s.last_modified > existing.last_modified
      end
      by_id.values
    end

    # Probe git for the worktree list with a hard 5-second cap. A stale
    # git lock or hung network mount must not block the listing path
    # forever. Stdlib `Timeout.timeout` raises across threads via
    # `Thread#raise`, which corrupts the Async fiber-scheduler state when
    # the caller is inside a reactor, so we drain stdout/stderr on side
    # threads (so a full pipe buffer can't deadlock git) and SIGKILL the
    # child if the deadline passes. Matches Python's
    # `subprocess.run(..., timeout=5)`.
    def detect_worktrees(path)
      stdin, stdout, stderr, wait_thr = Open3.popen3('git', '-C', path, 'worktree', 'list', '--porcelain')
      stdin.close

      # Drain stdout/stderr concurrently — without this, a repo with enough
      # worktrees to overrun the 64 KB pipe buffer causes git to block on
      # write, wait_thr never finishes, and we hit the 5-second watchdog
      # and silently lose every worktree path.
      stdout_buf = +''
      stdout_reader = Thread.new { stdout_buf << stdout.read.to_s }
      stderr_reader = Thread.new { stderr.read }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
      until wait_thr.join(0.1)
        next if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        begin
          Process.kill('KILL', wait_thr.pid)
        rescue Errno::ESRCH
          # Already exited between the join check and the kill.
        end
        wait_thr.join
        stdout_reader.join(0.5)
        stderr_reader.join(0.5)
        return [path]
      end

      stdout_reader.join
      stderr_reader.join

      return [path] unless wait_thr.value.success?

      paths = stdout_buf.lines.filter_map do |line|
        line.strip.delete_prefix('worktree ') if line.start_with?('worktree ')
      end
      paths.empty? ? [path] : paths
    rescue StandardError
      [path]
    ensure
      stdout_reader&.kill if stdout_reader&.alive?
      stderr_reader&.kill if stderr_reader&.alive?
      [stdout, stderr].each { |io| io&.close rescue nil } # rubocop:disable Style/RescueModifier
    end

    def find_session_file(session_id, directory)
      projects_dir = File.join(config_dir, 'projects')
      return nil unless File.directory?(projects_dir)

      if directory
        path = File.realpath(directory).unicode_normalize(:nfc)
        project_dir = find_project_dir(path)
        if project_dir
          candidate = File.join(project_dir, "#{session_id}.jsonl")
          return candidate if File.exist?(candidate)
        end

        # Try worktrees
        detect_worktrees(path).each do |wt_path|
          pd = find_project_dir(wt_path)
          next unless pd

          candidate = File.join(pd, "#{session_id}.jsonl")
          return candidate if File.exist?(candidate)
        end
      end

      # Scan all project dirs
      Dir.children(projects_dir).each do |child|
        dir = File.join(projects_dir, child)
        next unless File.directory?(dir)

        candidate = File.join(dir, "#{session_id}.jsonl")
        return candidate if File.exist?(candidate)
      end

      nil
    end

    def parse_jsonl_entries(file_path)
      entries = []

      File.foreach(file_path) do |line|
        entry = JSON.parse(line.strip, symbolize_names: false)
        next unless entry.is_a?(Hash)
        next unless TRANSCRIPT_ENTRY_TYPES.include?(entry['type'])
        next unless entry['uuid'].is_a?(String)

        entries << entry
      rescue JSON::ParserError
        next
      end
      entries
    end

    # Build the conversation chain by finding the leaf and walking parentUuid.
    # Returns messages in chronological order (root -> leaf).
    #
    # Note: logicalParentUuid (set on compact_boundary entries) is intentionally
    # NOT followed. This matches VS Code IDE behavior — post-compaction, the
    # isCompactSummary message replaces earlier messages, so following logical
    # parents would duplicate content.
    def build_conversation_chain(entries)
      return [] if entries.empty?

      by_uuid = {}
      by_position = {}
      parent_uuids = Set.new

      entries.each_with_index do |entry, idx|
        by_uuid[entry['uuid']] = entry
        by_position[entry['uuid']] = idx
        parent_uuids << entry['parentUuid'] if entry['parentUuid']
      end

      # Terminals: entries whose uuid is not any other entry's parentUuid
      terminals = Set.new(by_uuid.keys) - parent_uuids

      # Walk back from each terminal to find the nearest user/assistant leaf
      leaf_candidates = terminals.filter_map do |uuid|
        walk_to_leaf(by_uuid, uuid)
      end

      # Keep only main-chain candidates (not sidechain, team, or meta)
      main_leaves = leaf_candidates.reject do |e|
        e['isSidechain'] || e['teamName'] || e['isMeta']
      end
      return [] if main_leaves.empty?

      # Pick the leaf with highest file position, walk to root
      best_leaf = main_leaves.max_by { |e| by_position[e['uuid']] || 0 }
      walk_to_root(by_uuid, best_leaf)
    end

    def walk_to_leaf(by_uuid, uuid)
      visited = Set.new
      current = by_uuid[uuid]
      while current
        return current if %w[user assistant].include?(current['type'])
        return nil unless visited.add?(current['uuid'])

        parent = current['parentUuid']
        current = parent ? by_uuid[parent] : nil
      end
    end

    def walk_to_root(by_uuid, leaf)
      chain = []
      visited = Set.new
      current = leaf
      while current
        break unless visited.add?(current['uuid'])

        chain << current
        parent = current['parentUuid']
        current = parent ? by_uuid[parent] : nil
      end
      chain.reverse
    end

    def filter_visible_messages(chain)
      chain.filter_map do |entry|
        next unless %w[user assistant].include?(entry['type'])
        next if entry['isMeta']
        next if entry['isSidechain']
        next if entry['teamName']

        # NOTE: isCompactSummary messages are intentionally included. They contain
        # the summarized content from compacted conversations and are the only
        # representation of that content post-compaction. This matches VS Code IDE
        # behavior (transcriptToSessionMessage does not filter them).

        SessionMessage.new(
          type: entry['type'],
          uuid: entry['uuid'],
          session_id: entry['sessionId'] || entry['session_id'] || '',
          message: entry['message']
        )
      end
    end

    private_class_method :get_session_info_for_directory,
                         :list_sessions_for_directory, :list_all_sessions,
                         :deduplicate_sessions,
                         :find_session_file, :parse_jsonl_entries,
                         :build_conversation_chain, :walk_to_leaf, :walk_to_root,
                         :filter_visible_messages, :read_head_tail, :build_session_info,
                         :list_sessions_via_summaries, :paginate_resolving_gaps, :resolve_gap_slot,
                         :derive_info_from_entries, :mtime_from_entries, :apply_sort_limit_offset,
                         :filter_transcript_entries, :entries_to_messages,
                         :entries_to_subagent_messages, :build_subagent_chain, :resolve_subagent_subpath,
                         :import_subagent_files, :append_jsonl_file_in_batches, :collect_jsonl_files

    # These remain accessible for SessionMutations:
    # config_dir, sanitize_path, find_project_dir, detect_worktrees
  end
end
