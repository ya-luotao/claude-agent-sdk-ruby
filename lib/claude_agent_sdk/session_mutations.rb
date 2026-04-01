# frozen_string_literal: true

require 'json'
require_relative 'sessions'

module ClaudeAgentSDK
  # Session mutation functions: rename and tag sessions.
  #
  # Ported from Python SDK's _internal/session_mutations.py.
  # Appends typed metadata entries to the session's JSONL file,
  # matching the CLI pattern. Safe to call from any SDK host process.
  module SessionMutations
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

    # -- Private helpers --

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

    private_class_method :append_to_session, :append_to_session_in_directory,
                         :append_to_session_global, :try_append, :sanitize_unicode, :unicode_category
  end
end
