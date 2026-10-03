# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'fileutils'
require 'tempfile'
require_relative 'sessions'
require_relative 'session_store'

module ClaudeAgentSDK
  # Session mutation functions: rename, tag, delete, and fork sessions.
  #
  # Ported from Python SDK's _internal/session_mutations.py.
  # Appends typed metadata entries to the session's JSONL file,
  # matching the CLI pattern. Safe to call from any SDK host process.
  #
  # @api private
  module SessionMutations # rubocop:disable Metrics/ModuleLength -- rename/tag/delete/fork share transcript helpers
    module_function

    # Transcript entry types kept in fork output. Mirrors Python's
    # `_TRANSCRIPT_TYPES`. Other types (custom-title, tag, aiTitle,
    # permission-mode, etc.) carry session metadata and must not bleed
    # into the fork's transcript body — they are reconstructed for the
    # fork's own sessionId after the body is written.
    TRANSCRIPT_TYPES = %w[user assistant attachment system progress].freeze

    # Rename a session by appending a custom-title entry.
    #
    # Repeated calls are safe: the disk listing takes the LAST custom-title
    # in the final 64 KiB of the file (then in the first 64 KiB), the store
    # fold the last one overall. On disk the entry is only seen while it
    # stays inside one of those windows: rename a session that is still
    # running, let 64 KiB of transcript follow, and list_sessions /
    # get_session_info report the previous title again until the CLI resumes
    # the session and re-appends its metadata at the end (the same holds for
    # tag_session). Not fixed here: finding it again means reading the whole
    # file on every listing.
    #
    # @param session_id [String] UUID of the session to rename
    # @param title [String] New session title (whitespace stripped)
    # @param directory [String, nil] Project directory path
    # @raise [ArgumentError] if session_id is invalid, or title is blank or not a String
    # @raise [Errno::ENOENT] if the session file cannot be found
    def rename_session(session_id:, title:, directory: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless Sessions.valid_session_id?(session_id)

      stripped = stripped_title(title)

      data = "#{JSON.generate({ type: 'custom-title', customTitle: stripped, sessionId: session_id })}\n"

      append_to_session(session_id, data, directory)
    end

    # Tag a session. Pass nil to clear the tag.
    #
    # Appends a {type:'tag',tag:<tag>,sessionId:<id>} JSONL entry.
    # Tags are Unicode-sanitized before storing.
    #
    # @param session_id [String] UUID of the session to tag
    # @param tag [String, nil] Tag string, or nil to clear
    # @param directory [String, nil] Project directory path
    # @raise [ArgumentError] if session_id is invalid, or tag is not a String or is empty after sanitization
    # @raise [Errno::ENOENT] if the session file cannot be found
    def tag_session(session_id:, tag:, directory: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless Sessions.valid_session_id?(session_id)

      data = "#{JSON.generate({ type: 'tag', tag: sanitized_tag(tag), sessionId: session_id })}\n"

      append_to_session(session_id, data, directory)
    end

    # Delete a session by removing its JSONL file.
    #
    # This is a hard delete — the file is removed permanently. For soft-delete
    # semantics, use tag_session(id, '__hidden') and filter on listing instead.
    #
    # @param session_id [String] UUID of the session to delete
    # @param directory [String, nil] Project directory path
    # @raise [ArgumentError] if session_id is invalid
    # @raise [Errno::ENOENT] if the session file cannot be found
    def delete_session(session_id:, directory: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless Sessions.valid_session_id?(session_id)

      result = find_session_file_with_dir(session_id, directory)
      unless result
        raise Errno::ENOENT, "Session #{session_id} not found#{" in project directory for #{directory}" if directory}"
      end

      path = result[0]

      begin
        File.delete(path)
      rescue Errno::ENOENT
        raise Errno::ENOENT, "Session #{session_id} not found"
      end

      # Subagent transcripts live in a sibling directory named after the
      # session ID. Without removing it, the CLI would later pick up
      # orphaned subagent state if the same session ID happened to be
      # reused. Matches Python's `shutil.rmtree(path.parent / session_id)`.
      subagent_dir = File.join(File.dirname(path), session_id)
      FileUtils.rm_rf(subagent_dir) if File.directory?(subagent_dir)
    end

    # Fork a session into a new branch with fresh UUIDs.
    #
    # Creates a copy of the session transcript (or a prefix up to up_to_message_id)
    # with remapped UUIDs and a new session ID. Sidechains are filtered out,
    # progress entries are excluded from the written output but used for
    # parentUuid chain walking.
    #
    # @param session_id [String] UUID of the session to fork
    # @param directory [String, nil] Project directory path
    # @param up_to_message_id [String, nil] Truncate the fork at this message UUID
    # @param title [String, nil] Custom title for the fork (auto-generated if omitted)
    # @return [ForkSessionResult] Result containing the new session ID
    # @raise [ArgumentError] if session_id or up_to_message_id is invalid
    # @raise [Errno::ENOENT] if the session file cannot be found
    def fork_session(session_id:, directory: nil, up_to_message_id: nil, title: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless Sessions.valid_session_id?(session_id)

      if up_to_message_id && !Sessions.valid_session_id?(up_to_message_id)
        raise ArgumentError, "Invalid up_to_message_id: #{up_to_message_id}"
      end

      result = find_session_file_with_dir(session_id, directory)
      unless result
        raise Errno::ENOENT, "Session #{session_id} not found#{" in project directory for #{directory}" if directory}"
      end

      file_path, project_dir = result
      file_size = File.size(file_path)
      raise ArgumentError, "Session #{session_id} has no messages to fork" if file_size.zero?

      transcript, content_replacements = parse_fork_transcript(file_path, session_id)
      # The fork transform is shared with fork_session_via_store; the disk path
      # derives the fallback title from the file's head/tail bytes (only when no
      # explicit title is given).
      forked_session_id, lines = build_fork_lines(
        transcript, content_replacements, session_id, up_to_message_id, title,
        -> { derive_fork_title(file_path, file_size) }
      )

      fork_path = File.join(project_dir, "#{forked_session_id}.jsonl")
      # Stage beside the destination, outside the *.jsonl browsing glob. A hard
      # link publishes the closed, complete file atomically without overwriting
      # an existing UUID (rename would replace it). Tempfile owns only the
      # staging name, so failure cleanup never removes somebody else's session.
      Tempfile.create(['.claude-fork-', '.tmp'], project_dir) do |io|
        io.write("#{lines.join("\n")}\n")
        io.close
        File.link(io.path, fork_path)
      end

      ForkSessionResult.new(session_id: forked_session_id)
    end

    # ---- SessionStore-backed mutations (store counterparts to the disk ops) ----

    # Rename a session by appending a custom-title entry to a SessionStore.
    # Store-backed counterpart to rename_session. Unlike the disk variant, the
    # appended entry carries a fresh uuid + ISO timestamp so adapters that dedupe
    # by entry["uuid"] (per the SessionStore#append contract) treat it correctly.
    #
    # @raise [ArgumentError] if session_id is invalid, or title is blank or not a String
    # @raise [Errno::ENOENT] if the session is not found in the store
    def rename_session_via_store(session_store:, session_id:, title:, directory: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless Sessions.valid_session_id?(session_id)

      stripped = stripped_title(title)

      key = { 'project_key' => Sessions.project_key_for_directory(directory), 'session_id' => session_id }
      ensure_store_session_exists(session_store, key)
      session_store.append(key, [{
                             'type' => 'custom-title',
                             'customTitle' => stripped,
                             'sessionId' => session_id,
                             'uuid' => SecureRandom.uuid,
                             'timestamp' => iso_now
                           }])
      nil
    end

    # Tag a session by appending a tag entry to a SessionStore. Store-backed
    # counterpart to tag_session. Pass nil to clear the tag. Tags are
    # Unicode-sanitized before storing.
    #
    # @raise [ArgumentError] if session_id is invalid, or tag is not a String or is empty after sanitization
    # @raise [Errno::ENOENT] if the session is not found in the store
    def tag_session_via_store(session_store:, session_id:, tag:, directory: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless Sessions.valid_session_id?(session_id)

      tag = sanitized_tag(tag)
      key = { 'project_key' => Sessions.project_key_for_directory(directory), 'session_id' => session_id }
      ensure_store_session_exists(session_store, key)
      session_store.append(key, [{
                             'type' => 'tag',
                             'tag' => tag,
                             'sessionId' => session_id,
                             'uuid' => SecureRandom.uuid,
                             'timestamp' => iso_now
                           }])
      nil
    end

    # Delete a session from a SessionStore. Store-backed counterpart to
    # delete_session. If the store does not implement #delete, deletion is a
    # no-op (appropriate for WORM/append-only backends, per the SessionStore
    # contract). Whether subagent subkeys are also removed depends on the
    # store's delete({session_id}) cascade semantics (InMemorySessionStore
    # cascades; custom stores may not).
    #
    # @raise [ArgumentError] if session_id is invalid
    def delete_session_via_store(session_store:, session_id:, directory: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless Sessions.valid_session_id?(session_id)

      key = { 'project_key' => Sessions.project_key_for_directory(directory), 'session_id' => session_id }
      SessionStores.optional_call(session_store, :delete) { session_store.delete(key) }
      nil
    end

    # Fork a session into a new branch with fresh UUIDs via a SessionStore.
    # Store-backed counterpart to fork_session. Runs the fork transform directly
    # over the objects returned by store.load — no JSONL round-trip on disk. A
    # storage-layer copy is NOT sufficient: the transform remaps every UUID,
    # rewrites sessionId, and stamps forkedFrom, so the data must pass through
    # this process once.
    #
    # @raise [ArgumentError] if session_id/up_to_message_id is invalid or the session has no messages
    # @raise [Errno::ENOENT] if the source session is not found in the store
    def fork_session_via_store(session_store:, session_id:, directory: nil, up_to_message_id: nil, title: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless Sessions.valid_session_id?(session_id)
      if up_to_message_id && !Sessions.valid_session_id?(up_to_message_id)
        raise ArgumentError, "Invalid up_to_message_id: #{up_to_message_id}"
      end

      project_key = Sessions.project_key_for_directory(directory)
      raw = session_store.load('project_key' => project_key, 'session_id' => session_id)
      raise Errno::ENOENT, "Session #{session_id} not found" if raw.nil? || raw.empty?

      transcript, content_replacements = partition_fork_entries(raw, session_id)
      forked_session_id, lines = build_fork_lines(
        transcript, content_replacements, session_id, up_to_message_id, title,
        -> { derive_title_from_entries(raw) }
      )

      dst_key = { 'project_key' => project_key, 'session_id' => forked_session_id }
      # build_fork_lines emits compact JSON strings; re-parse to objects so the
      # store receives the same shape it would from the mirror path.
      session_store.append(dst_key, lines.map { |line| JSON.parse(line) })
      ForkSessionResult.new(session_id: forked_session_id)
    end

    # -- Private helpers --

    # The title to store: stripped and non-empty. A value that is not a usable
    # String (nil, another type, bytes invalid in their encoding) gets the
    # ArgumentError an empty title gets — the boundary check the session ids
    # have — where calling #strip on it raised NoMethodError or an encoding
    # error from inside.
    def stripped_title(title)
      text = utf8_text(title)
      stripped = text ? text.strip : ''
      raise ArgumentError, 'title must be non-empty' if stripped.empty?

      stripped
    end

    # +value+ as UTF-8 text, or nil when it is not usable text: not a String,
    # or bytes that are not valid text. A binary String (ASCII-8BIT, what
    # File.binread returns) always reports valid_encoding?, so it is read as
    # the UTF-8 it usually holds and checked as such; a String in another
    # encoding is transcoded. Without this, binary bytes that are not UTF-8
    # got past the check and failed later as JSON::GeneratorError or
    # Encoding::CompatibilityError instead of the documented ArgumentError.
    def utf8_text(value)
      return nil unless value.is_a?(String)

      text = value.encoding == Encoding::BINARY ? value.dup.force_encoding(Encoding::UTF_8) : value.encode(Encoding::UTF_8)
      text.valid_encoding? ? text : nil
    rescue EncodingError
      nil
    end

    # The tag to store: Unicode-sanitized and stripped, or '' (which clears
    # the tag) for nil — only nil: false is not a tag either, and clearing on
    # it would turn a Boolean from untyped input into a destructive write.
    # Same boundary check as stripped_title.
    def sanitized_tag(tag)
      return '' if tag.nil?

      text = utf8_text(tag)
      sanitized = text ? sanitize_unicode(text).strip : ''
      raise ArgumentError, 'tag must be non-empty (use nil to clear)' if sanitized.empty?

      sanitized
    end

    # Raise Errno::ENOENT (as the disk counterparts and fork_session_via_store
    # do) unless the store holds entries for +key+. Without this probe, a
    # rename/tag of a typo'd or stale id APPENDED metadata to a never-written
    # key, creating a phantom session — permanent on WORM/append-only stores.
    #
    # #load is the probe because it is the only exact per-session existence
    # check the contract offers: it is required, and returns nil for a key
    # that was never written. The optional methods don't fit: list_subkeys
    # returns [] for "no subagents" and "no session" alike,
    # list_session_summaries is an advisory sidecar that may be stale, and
    # list_sessions scans the whole project (no cheaper than one load in the
    # reference adapters).
    #
    # Check-then-act: a concurrent delete between this probe and the append
    # can still recreate the key. That window is inherent to the store API
    # (there is no conditional append), so no locking is attempted.
    def ensure_store_session_exists(session_store, key)
      entries = session_store.load(key)
      raise Errno::ENOENT, "Session #{key['session_id']} not found" if entries.nil? || entries.empty?
    end

    # Locate the JSONL file for a session and return [file_path, project_dir].
    def find_session_file_with_dir(session_id, directory)
      file_name = "#{session_id}.jsonl"
      return find_in_directory(file_name, directory) if directory

      find_in_all_projects(file_name)
    end

    def find_in_directory(file_name, directory)
      # canonicalize_path, not File.realpath: the transcripts outlive the
      # directory (a removed worktree), and realpath raised Errno::ENOENT for
      # it before the session was even looked for — while the readers, which
      # canonicalize, still found the session through the same directory.
      path = Sessions.canonicalize_path(directory)
      result = try_project_dir(file_name, Sessions.find_project_dir(path), path)
      return result if result

      worktree_paths = begin
        Sessions.detect_worktrees(path)
      rescue Errno::ENOENT, Errno::EACCES
        []
      end
      worktree_paths.each do |wt_path|
        next if wt_path == path

        result = try_project_dir(file_name, Sessions.find_project_dir(wt_path), wt_path)
        return result if result
      end
      nil
    end

    # A candidate counts only when it exists AND is non-empty — a 0-byte stub
    # in one project dir must not stop the search when the real transcript
    # lives under another (worktree) project dir. Mirrors the read path
    # (Sessions.stat_candidate) and the append path (try_append).
    # With +path+ (a directory-scoped lookup), the candidate must also be one
    # of that path's own transcripts (Sessions.own_transcript?: a directory
    # the long-path fallback found can hold other paths' sessions).
    def try_project_dir(file_name, project_dir, path = nil)
      return nil unless project_dir

      candidate = File.join(project_dir, file_name)
      return nil unless File.size(candidate).positive?
      return nil if path && !Sessions.own_transcript?(project_dir, candidate, path)

      [candidate, project_dir]
    rescue SystemCallError
      nil
    end

    def find_in_all_projects(file_name)
      projects_dir = File.join(Sessions.config_dir, 'projects')
      return nil unless File.directory?(projects_dir)

      Dir.children(projects_dir).each do |child|
        pd = File.join(projects_dir, child)
        next unless File.directory?(pd)

        result = try_project_dir(file_name, pd)
        return result if result
      end
      nil
    end

    # Parse a fork transcript by streaming the JSONL file line-by-line.
    # Opens in binary mode and scrubs invalid UTF-8 so stray non-UTF-8
    # bytes in tool results do not raise Encoding::InvalidByteSequenceError.
    #
    # Only `TRANSCRIPT_TYPES` entries with a string uuid are kept in the
    # transcript body — `custom-title`, `tag`, `aiTitle`, `permission-mode`
    # and other metadata entries are reconstructed for the new sessionId
    # by the caller. `content-replacement` entries are collected across the
    # entire file (one per compaction round) — concatenated rather than
    # overwritten — and only kept if their `sessionId` matches the source.
    # Matches Python's `_parse_fork_transcript` exactly.
    def parse_fork_transcript(file_path, source_session_id = nil)
      transcript = []
      content_replacements = []

      File.foreach(file_path, mode: 'rb') do |line|
        line = line.force_encoding('UTF-8').scrub
        begin
          entry = JSON.parse(line.strip)
        rescue JSON::ParserError
          next
        end
        next unless entry.is_a?(Hash)

        entry_type = entry['type']
        if TRANSCRIPT_TYPES.include?(entry_type) && entry['uuid'].is_a?(String)
          transcript << entry
        elsif entry_type == 'content-replacement' &&
              (source_session_id.nil? || entry['sessionId'] == source_session_id) &&
              entry['replacements'].is_a?(Array)
          content_replacements.concat(entry['replacements'])
        end
      end

      [transcript, content_replacements]
    end

    # Current UTC time as a millisecond-precision ISO-8601 'Z' string, matching
    # the timestamp shape the CLI writes into transcripts.
    def iso_now
      Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%3NZ')
    end

    # Core fork transform shared by the disk and SessionStore paths. Filters
    # sidechains, applies the optional up_to_message_id slice (inclusive),
    # remaps every UUID (keeping progress entries in the chain walk but out of
    # the written output), rewrites sessionId/forkedFrom, and appends the
    # content-replacement and custom-title trailers (each with a fresh uuid +
    # timestamp). Returns [forked_session_id, lines] where each line is a
    # compact JSON string with no trailing newline.
    #
    # +derive_title+ is a callable invoked ONLY when no explicit +title+ is
    # given, so the disk path's head/tail byte scan and the store path's
    # entry-object scan each run only when needed.
    def build_fork_lines(transcript, content_replacements, session_id, up_to_message_id, title, derive_title) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity -- single fork rewrite pass: UUID remap, truncation, title
      transcript = transcript.reject { |e| e['isSidechain'] }
      raise ArgumentError, "Session #{session_id} has no messages to fork" if transcript.empty?

      if up_to_message_id
        cutoff = transcript.index { |e| e['uuid'] == up_to_message_id }
        raise ArgumentError, "Message #{up_to_message_id} not found in session #{session_id}" unless cutoff

        transcript = transcript[0..cutoff]
      end

      # Build UUID mapping (including progress entries for the parentUuid chain walk).
      uuid_mapping = {}
      transcript.each { |e| uuid_mapping[e['uuid']] = SecureRandom.uuid }
      by_uuid = transcript.to_h { |e| [e['uuid'], e] }

      # Filter progress messages out of the written output (UI-only chain links).
      writable = transcript.reject { |e| e['type'] == 'progress' }
      raise ArgumentError, "Session #{session_id} has no messages to fork" if writable.empty?

      forked_session_id = SecureRandom.uuid
      now = iso_now

      lines = writable.each_with_index.map do |original, i|
        build_forked_entry(original, i, writable.size, uuid_mapping, by_uuid,
                           forked_session_id, session_id, now)
      end

      # Append content-replacement entry if any. The entry needs `uuid` and
      # `timestamp` so a *second* fork of this forked session can re-ingest it,
      # and so adapters that dedupe by uuid handle it correctly.
      if content_replacements && !content_replacements.empty?
        lines << JSON.generate({
                                 'type' => 'content-replacement',
                                 'sessionId' => forked_session_id,
                                 'replacements' => content_replacements,
                                 'uuid' => SecureRandom.uuid,
                                 'timestamp' => now
                               })
      end

      # Derive title: explicit > the source's listed title (custom, else AI) >
      # its first prompt, suffixed with " (fork)" when derived. listSessions
      # reads the LAST custom-title from the tail, so this trailer is what
      # surfaces.
      fork_title = title&.strip
      fork_title = "#{derive_title.call || 'Forked session'} (fork)" if fork_title.nil? || fork_title.empty?

      lines << JSON.generate({
                               'type' => 'custom-title',
                               'sessionId' => forked_session_id,
                               'customTitle' => fork_title,
                               'uuid' => SecureRandom.uuid,
                               'timestamp' => now
                             })

      [forked_session_id, lines]
    end

    # Partition already-parsed store entries into [transcript, content_replacements],
    # mirroring parse_fork_transcript for the store path (which has no JSONL file
    # to stream). Only TRANSCRIPT_TYPES entries with a string uuid form the body;
    # content-replacement records whose sessionId matches the source are collected
    # (concatenated across compaction rounds).
    def partition_fork_entries(raw, source_session_id)
      transcript = []
      content_replacements = []
      raw.each do |entry|
        next unless entry.is_a?(Hash)

        entry_type = entry['type']
        if TRANSCRIPT_TYPES.include?(entry_type) && entry['uuid'].is_a?(String)
          transcript << entry
        elsif entry_type == 'content-replacement' && entry['sessionId'] == source_session_id &&
              entry['replacements'].is_a?(Array)
          content_replacements.concat(entry['replacements'])
        end
      end
      [transcript, content_replacements]
    end

    # Derive a fork title from already-parsed store entries: the title the
    # store listing shows for the session (custom title, else AI title — the
    # latest occurrence of each, a blank one counting as absent), else its
    # first prompt. Folds the RAW entries (the partitioned transcript has
    # dropped the customTitle/aiTitle metadata — the store half of #837's
    # P0-1 fix) with the fold the listing uses, and takes the title from the
    # folded fields rather than from summary_entry_to_sdk_info: that returns
    # nil for a sidechain or summary-less session, which can still be forked.
    # nil when the session has none of the three (the caller supplies the
    # "Forked session" default).
    def derive_title_from_entries(raw)
      data = SessionSummary.fold_session_summary(nil, {}, raw)['data']
      first_prompt = data['first_prompt_locked'] ? data['first_prompt'] : data['command_fallback']
      Sessions.display_title(data['custom_title'], data['ai_title']) || Sessions.presence(first_prompt)
    end

    # Derive a fork title from the source file without slurping it: the title
    # and first prompt the disk listing reports for the session, taken from
    # the same head/tail windows by the same rule. nil when it has neither
    # (build_fork_lines supplies the "Forked session" default).
    def derive_fork_title(file_path, file_size)
      head, tail = Sessions.read_head_tail(file_path, file_size)
      title, first_prompt = Sessions.title_and_first_prompt(file_path, head, tail, file_size)
      title || first_prompt
    end

    # Build a single forked entry with remapped UUIDs.
    def build_forked_entry(original, index, total, uuid_mapping, by_uuid, # rubocop:disable Metrics/ParameterLists -- per-entry step of build_fork_lines; its state is threaded explicitly
                           forked_session_id, source_session_id, now)
      new_uuid = uuid_mapping[original['uuid']]

      # Resolve parentUuid, skipping progress ancestors
      new_parent_uuid = resolve_parent_uuid(original['parentUuid'], by_uuid, uuid_mapping)

      # Only update timestamp on the last message
      timestamp = index == total - 1 ? now : (original['timestamp'] || now)

      # Remap logicalParentUuid — unlike parentUuid (which walks the chain and nils on miss),
      # logicalParentUuid preserves the original UUID when unmapped because it may reference
      # a message outside the forked range (e.g., a prior conversation branch).
      logical_parent = original['logicalParentUuid']
      new_logical_parent = logical_parent ? (uuid_mapping[logical_parent] || logical_parent) : logical_parent

      forked = original.merge(
        'uuid' => new_uuid,
        'parentUuid' => new_parent_uuid,
        'logicalParentUuid' => new_logical_parent,
        'sessionId' => forked_session_id,
        'timestamp' => timestamp,
        'isSidechain' => false,
        'forkedFrom' => { 'sessionId' => source_session_id, 'messageUuid' => original['uuid'] }
      )
      %w[teamName agentName slug sourceToolAssistantUUID].each { |k| forked.delete(k) }

      JSON.generate(forked)
    end

    # Walk up parentUuid chain skipping progress entries. The visited set
    # guards against parentUuid cycles among progress entries (corrupt
    # transcripts) like every other chain walker — an unguarded walk spun
    # forever and hung both fork paths.
    def resolve_parent_uuid(parent_id, by_uuid, uuid_mapping)
      visited = Set.new
      while parent_id && visited.add?(parent_id)
        parent = by_uuid[parent_id]
        break unless parent
        return uuid_mapping[parent_id] if parent['type'] != 'progress'

        parent_id = parent['parentUuid']
      end
      nil
    end

    def append_to_session(session_id, data, directory)
      file_name = "#{session_id}.jsonl"

      if directory
        append_to_session_in_directory(session_id, data, file_name, directory)
      else
        append_to_session_global(session_id, data, file_name)
      end
    end

    def append_to_session_in_directory(session_id, data, file_name, directory)
      path = Sessions.canonicalize_path(directory) # see find_in_directory

      # Try the exact/prefix-matched project directory first.
      project_dir = Sessions.find_project_dir(path)
      return if project_dir && own_append(project_dir, file_name, path, data)

      # Worktree fallback
      begin
        worktree_paths = Sessions.detect_worktrees(path)
      rescue StandardError
        worktree_paths = []
      end

      found = worktree_paths.any? do |wt_path|
        next false if wt_path == path

        wt_project_dir = Sessions.find_project_dir(wt_path)
        wt_project_dir && own_append(wt_project_dir, file_name, wt_path, data)
      end
      return if found

      raise Errno::ENOENT, "Session #{session_id} not found in project directory for #{directory}"
    end

    def append_to_session_global(session_id, data, file_name)
      projects_dir = File.join(Sessions.config_dir, 'projects')
      unless File.directory?(projects_dir)
        raise Errno::ENOENT, "Session #{session_id} not found (no projects directory)"
      end

      found = Dir.children(projects_dir).any? do |child|
        candidate = File.join(projects_dir, child, file_name)
        try_append(candidate, data)
      end
      return if found

      raise Errno::ENOENT, "Session #{session_id} not found in any project directory"
    end

    # try_append, for a transcript of +path+'s own (Sessions.own_transcript?).
    def own_append(project_dir, file_name, path, data)
      candidate = File.join(project_dir, file_name)
      Sessions.own_transcript?(project_dir, candidate, path) && try_append(candidate, data)
    end

    # Try appending to a path.
    #
    # Opens with WRONLY | APPEND (no CREAT) so the open fails with
    # ENOENT if the file does not exist. Returns false for missing
    # files or zero-byte files; true on successful write.
    def try_append(path, data)
      File.open(path, File::WRONLY | File::APPEND) do |file|
        return false if file.stat.size.zero? # rubocop:disable Style/ZeroLengthPredicate

        # The final JSONL record need not have a newline (or may be truncated).
        # Append the boundary and metadata together, without a racy read/check
        # or requiring read access. Readers already ignore empty lines.
        file.write("\n#{data}")
        true
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end

    # Unicode sanitization — ported from Python SDK / TS sanitization.ts
    #
    # Iteratively applies NFKC normalization and strips format/private-use/
    # unassigned characters until stable (max 10 iterations).
    UNICODE_STRIP_RE = /[\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff\ue000-\uf8ff]/
    FORMAT_CATEGORIES = %w[Cf Co Cn].freeze

    def sanitize_unicode(value)
      current = value
      10.times do
        previous = current
        current = current.unicode_normalize(:nfkc)
        current = current.each_char.reject { |c| FORMAT_CATEGORIES.include?(unicode_category(c)) }.join
        current = current.gsub(UNICODE_STRIP_RE, '')
        break if current == previous
      end
      current
    end

    # Returns the Unicode general category for a character (e.g., 'Cf', 'Lu', 'Ll').
    def unicode_category(char)
      # Ruby doesn't have a built-in unicodedata.category(), but we can
      # check the specific categories we care about using regex properties.
      return 'Cf' if char.match?(/\p{Cf}/)
      return 'Co' if char.match?(/\p{Co}/)
      return 'Cn' if char.match?(/\p{Cn}/)

      'Other'
    end

    private_class_method :stripped_title, :sanitized_tag, :find_session_file_with_dir,
                         :find_in_directory, :try_project_dir, :find_in_all_projects,
                         :parse_fork_transcript, :derive_fork_title, :build_forked_entry, :resolve_parent_uuid,
                         :append_to_session, :append_to_session_in_directory,
                         :append_to_session_global, :own_append, :try_append, :sanitize_unicode, :unicode_category,
                         :iso_now, :build_fork_lines, :partition_fork_entries, :derive_title_from_entries,
                         :ensure_store_session_exists
  end
end
