# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'sessions'

module ClaudeAgentSDK
  # Session mutation functions: rename, tag, delete, and fork sessions.
  #
  # Ported from Python SDK's _internal/session_mutations.py.
  # Appends typed metadata entries to the session's JSONL file,
  # matching the CLI pattern. Safe to call from any SDK host process.
  module SessionMutations # rubocop:disable Metrics/ModuleLength
    module_function

    # Rename a session by appending a custom-title entry.
    #
    # list_sessions reads the LAST custom-title from the file tail, so
    # repeated calls are safe — the most recent wins.
    #
    # @param session_id [String] UUID of the session to rename
    # @param title [String] New session title (whitespace stripped)
    # @param directory [String, nil] Project directory path
    # @raise [ArgumentError] if session_id is invalid or title is empty
    # @raise [Errno::ENOENT] if the session file cannot be found
    def rename_session(session_id:, title:, directory: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless session_id.match?(Sessions::UUID_RE)

      stripped = title.strip
      raise ArgumentError, 'title must be non-empty' if stripped.empty?

      data = "#{JSON.generate({ type: 'custom-title', customTitle: stripped, sessionId: session_id },
                              space_size: 0)}\n"

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
    # @raise [ArgumentError] if session_id is invalid or tag is empty after sanitization
    # @raise [Errno::ENOENT] if the session file cannot be found
    def tag_session(session_id:, tag:, directory: nil)
      raise ArgumentError, "Invalid session_id: #{session_id}" unless session_id.match?(Sessions::UUID_RE)

      if tag
        sanitized = sanitize_unicode(tag).strip
        raise ArgumentError, 'tag must be non-empty (use nil to clear)' if sanitized.empty?

        tag = sanitized
      end

      data = "#{JSON.generate({ type: 'tag', tag: tag || '', sessionId: session_id },
                              space_size: 0)}\n"

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
      raise ArgumentError, "Invalid session_id: #{session_id}" unless session_id.match?(Sessions::UUID_RE)

      result = find_session_file_with_dir(session_id, directory)
      raise Errno::ENOENT, "Session #{session_id} not found#{" in project directory for #{directory}" if directory}" unless result

      path = result[0]

      begin
        File.delete(path)
      rescue Errno::ENOENT
        raise Errno::ENOENT, "Session #{session_id} not found"
      end
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
    def fork_session(session_id:, directory: nil, up_to_message_id: nil, title: nil) # rubocop:disable Metrics/MethodLength
      raise ArgumentError, "Invalid session_id: #{session_id}" unless session_id.match?(Sessions::UUID_RE)

      raise ArgumentError, "Invalid up_to_message_id: #{up_to_message_id}" if up_to_message_id && !up_to_message_id.match?(Sessions::UUID_RE)

      result = find_session_file_with_dir(session_id, directory)
      raise Errno::ENOENT, "Session #{session_id} not found#{" in project directory for #{directory}" if directory}" unless result

      file_path, project_dir = result
      file_size = File.size(file_path)
      raise ArgumentError, "Session #{session_id} has no messages to fork" if file_size.zero?

      transcript, content_replacements = parse_fork_transcript(file_path)
      transcript.reject! { |e| e['isSidechain'] }
      raise ArgumentError, "Session #{session_id} has no messages to fork" if transcript.empty?

      if up_to_message_id
        cutoff = transcript.index { |e| e['uuid'] == up_to_message_id }
        raise ArgumentError, "Message #{up_to_message_id} not found in session #{session_id}" unless cutoff

        transcript = transcript[0..cutoff]
      end

      # Build UUID mapping (including progress entries for parentUuid chain walk)
      uuid_mapping = {}
      transcript.each { |e| uuid_mapping[e['uuid']] = SecureRandom.uuid }

      by_uuid = transcript.to_h { |e| [e['uuid'], e] }

      # Filter out progress messages from written output
      writable = transcript.reject { |e| e['type'] == 'progress' }
      raise ArgumentError, "Session #{session_id} has no messages to fork" if writable.empty?

      forked_session_id = SecureRandom.uuid
      now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%3NZ')

      lines = writable.each_with_index.map do |original, i|
        build_forked_entry(original, i, writable.size, uuid_mapping, by_uuid,
                           forked_session_id, session_id, now)
      end

      # Append content-replacement entry if any
      if content_replacements && !content_replacements.empty?
        lines << JSON.generate({
                                 'type' => 'content-replacement',
                                 'sessionId' => forked_session_id,
                                 'replacements' => content_replacements
                               })
      end

      # Derive title — only read head/tail chunks when we need to generate one
      fork_title = title&.strip
      fork_title = "#{derive_fork_title(file_path, file_size)} (fork)" if fork_title.nil? || fork_title.empty?

      lines << JSON.generate({
                               'type' => 'custom-title',
                               'sessionId' => forked_session_id,
                               'customTitle' => fork_title
                             })

      fork_path = File.join(project_dir, "#{forked_session_id}.jsonl")
      io = nil
      fd = IO.sysopen(fork_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      begin
        io = IO.new(fd)
        io.write("#{lines.join("\n")}\n")
      ensure
        if io
          io.close
        else
          IO.for_fd(fd).close rescue nil # rubocop:disable Style/RescueModifier
        end
      end

      ForkSessionResult.new(session_id: forked_session_id)
    end

    # -- Private helpers --

    # Locate the JSONL file for a session and return [file_path, project_dir].
    def find_session_file_with_dir(session_id, directory)
      file_name = "#{session_id}.jsonl"
      return find_in_directory(file_name, directory) if directory

      find_in_all_projects(file_name)
    end

    def find_in_directory(file_name, directory)
      path = File.realpath(directory).unicode_normalize(:nfc)
      result = try_project_dir(file_name, Sessions.find_project_dir(path))
      return result if result

      worktree_paths = begin
        Sessions.detect_worktrees(path)
      rescue Errno::ENOENT, Errno::EACCES
        []
      end
      worktree_paths.each do |wt_path|
        next if wt_path == path

        result = try_project_dir(file_name, Sessions.find_project_dir(wt_path))
        return result if result
      end
      nil
    end

    def try_project_dir(file_name, project_dir)
      return nil unless project_dir

      candidate = File.join(project_dir, file_name)
      File.exist?(candidate) ? [candidate, project_dir] : nil
    end

    def find_in_all_projects(file_name)
      projects_dir = File.join(Sessions.config_dir, 'projects')
      return nil unless File.directory?(projects_dir)

      Dir.children(projects_dir).each do |child|
        pd = File.join(projects_dir, child)
        next unless File.directory?(pd)

        candidate = File.join(pd, file_name)
        return [candidate, pd] if File.exist?(candidate)
      end
      nil
    end

    # Parse a fork transcript by streaming the JSONL file line-by-line.
    # Opens in binary mode and scrubs invalid UTF-8 so stray non-UTF-8
    # bytes in tool results do not raise Encoding::InvalidByteSequenceError.
    def parse_fork_transcript(file_path)
      transcript = []
      content_replacements = nil

      File.foreach(file_path, mode: 'rb') do |line|
        line = line.force_encoding('UTF-8').scrub
        begin
          entry = JSON.parse(line.strip)
        rescue JSON::ParserError
          next
        end
        next unless entry.is_a?(Hash) && entry['uuid']

        if entry['type'] == 'content-replacement'
          content_replacements = entry['replacements']
          next
        end
        transcript << entry
      end

      [transcript, content_replacements]
    end

    # Derive a fork title from the source file's head/tail chunks without
    # slurping the entire file. Matches the lookup order used for
    # SDKSessionInfo.custom_title / ai_title / first_prompt.
    def derive_fork_title(file_path, file_size)
      buf_size = [Sessions::LITE_READ_BUF_SIZE, file_size].min
      File.open(file_path, 'rb') do |f|
        head = (f.read(buf_size) || '').force_encoding('UTF-8').scrub
        tail = if file_size > Sessions::LITE_READ_BUF_SIZE
                 f.seek(-buf_size, IO::SEEK_END)
                 (f.read(buf_size) || '').force_encoding('UTF-8').scrub
               else
                 head
               end
        Sessions.extract_json_string_field(tail, 'customTitle', last: true) ||
          Sessions.extract_json_string_field(head, 'customTitle', last: true) ||
          Sessions.extract_json_string_field(tail, 'aiTitle', last: true) ||
          Sessions.extract_json_string_field(head, 'aiTitle', last: true) ||
          Sessions.extract_first_prompt_from_head(head) ||
          'Forked session'
      end
    end

    # Build a single forked entry with remapped UUIDs.
    def build_forked_entry(original, index, total, uuid_mapping, by_uuid,
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

    # Walk up parentUuid chain skipping progress entries.
    def resolve_parent_uuid(parent_id, by_uuid, uuid_mapping)
      while parent_id
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
      path = File.realpath(directory).unicode_normalize(:nfc)

      # Try the exact/prefix-matched project directory first.
      project_dir = Sessions.find_project_dir(path)
      return if project_dir && try_append(File.join(project_dir, file_name), data)

      # Worktree fallback
      begin
        worktree_paths = Sessions.detect_worktrees(path)
      rescue StandardError
        worktree_paths = []
      end

      found = worktree_paths.any? do |wt_path|
        next false if wt_path == path

        wt_project_dir = Sessions.find_project_dir(wt_path)
        wt_project_dir && try_append(File.join(wt_project_dir, file_name), data)
      end
      return if found

      raise Errno::ENOENT, "Session #{session_id} not found in project directory for #{directory}"
    end

    def append_to_session_global(session_id, data, file_name)
      projects_dir = File.join(Sessions.config_dir, 'projects')
      raise Errno::ENOENT, "Session #{session_id} not found (no projects directory)" unless File.directory?(projects_dir)

      found = Dir.children(projects_dir).any? do |child|
        candidate = File.join(projects_dir, child, file_name)
        try_append(candidate, data)
      end
      return if found

      raise Errno::ENOENT, "Session #{session_id} not found in any project directory"
    end

    # Try appending to a path.
    #
    # Opens with WRONLY | APPEND (no CREAT) so the open fails with
    # ENOENT if the file does not exist. Returns false for missing
    # files or zero-byte files; true on successful write.
    def try_append(path, data)
      File.open(path, File::WRONLY | File::APPEND) do |file|
        return false if file.stat.size.zero? # rubocop:disable Style/ZeroLengthPredicate

        file.write(data)
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

    private_class_method :find_session_file_with_dir,
                         :find_in_directory, :try_project_dir, :find_in_all_projects,
                         :parse_fork_transcript, :derive_fork_title, :build_forked_entry, :resolve_parent_uuid,
                         :append_to_session, :append_to_session_in_directory,
                         :append_to_session_global, :try_append, :sanitize_unicode, :unicode_category
  end
end
