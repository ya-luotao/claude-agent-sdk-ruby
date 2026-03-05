# frozen_string_literal: true

require 'English'
require 'json'
require 'pathname'
require 'shellwords'

module ClaudeAgentSDK
  # Session info returned by list_sessions
  class SDKSessionInfo
    attr_accessor :session_id, :summary, :last_modified, :file_size,
                  :custom_title, :first_prompt, :git_branch, :cwd

    def initialize(session_id:, summary:, last_modified:, file_size:,
                   custom_title: nil, first_prompt: nil, git_branch: nil, cwd: nil)
      @session_id = session_id
      @summary = summary
      @last_modified = last_modified
      @file_size = file_size
      @custom_title = custom_title
      @first_prompt = first_prompt
      @git_branch = git_branch
      @cwd = cwd
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
  end

  # Session browsing functions
  module Sessions # rubocop:disable Metrics/ModuleLength
    LITE_READ_BUF_SIZE = 65_536
    MAX_SANITIZED_LENGTH = 200

    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    SKIP_FIRST_PROMPT_PATTERN = %r{\A(?:<local-command-stdout>|<session-start-hook>|<tick>|<goal>|
      \[Request\ interrupted\ by\ user[^\]]*\]|
      \s*<ide_opened_file>[\s\S]*</ide_opened_file>\s*\z|
      \s*<ide_selection>[\s\S]*</ide_selection>\s*\z)}x

    COMMAND_NAME_RE = %r{<command-name>(.*?)</command-name>}

    SANITIZE_RE = /[^a-zA-Z0-9]/

    module_function

    # Match TypeScript's simpleHash: signed 32-bit integer, base-36 output
    def simple_hash(str)
      h = 0
      str.each_char do |ch|
        char_code = ch.ord
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
      custom_title = extract_json_string_field(tail, 'customTitle', last: true)
      first_prompt = extract_first_prompt_from_head(head)
      summary = custom_title || extract_json_string_field(tail, 'summary', last: true) || first_prompt
      return nil if summary.nil? || summary.strip.empty?

      SDKSessionInfo.new(
        session_id: File.basename(file_path, '.jsonl'),
        summary: summary,
        last_modified: (stat.mtime.to_f * 1000).to_i,
        file_size: stat.size,
        custom_title: custom_title,
        first_prompt: first_prompt,
        git_branch: extract_json_string_field(tail, 'gitBranch', last: true) ||
                    extract_json_string_field(head, 'gitBranch', last: false),
        cwd: extract_json_string_field(head, 'cwd', last: false) || project_path
      )
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
    # @param include_worktrees [Boolean] Whether to include git worktree sessions
    # @return [Array<SDKSessionInfo>] Sessions sorted by last_modified descending
    def list_sessions(directory: nil, limit: nil, include_worktrees: true)
      sessions = if directory
                   list_sessions_for_directory(directory, include_worktrees)
                 else
                   list_all_sessions
                 end

      # Sort by last_modified descending
      sessions.sort_by! { |s| -s.last_modified }
      sessions = sessions.first(limit) if limit
      sessions
    end

    # Get messages from a session transcript
    # @param session_id [String] The session UUID
    # @param directory [String, nil] Working directory to search in
    # @param limit [Integer, nil] Maximum number of messages
    # @param offset [Integer] Number of messages to skip
    # @return [Array<SessionMessage>] Ordered messages from the session
    def get_session_messages(session_id:, directory: nil, limit: nil, offset: 0)
      return [] unless session_id.match?(UUID_RE)

      file_path = find_session_file(session_id, directory)
      return [] unless file_path && File.exist?(file_path)

      entries = parse_jsonl_entries(file_path)
      chain = build_conversation_chain(entries)
      messages = filter_visible_messages(chain)

      # Apply offset and limit
      messages = messages[offset..] || []
      messages = messages.first(limit) if limit
      messages
    end

    # -- Private helpers --

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

    def detect_worktrees(path)
      output = `git -C #{Shellwords.escape(path)} worktree list --porcelain 2>/dev/null`
      return [path] unless $CHILD_STATUS.success?

      paths = output.lines.filter_map do |line|
        line.strip.delete_prefix('worktree ') if line.start_with?('worktree ')
      end
      paths.empty? ? [path] : paths
    rescue StandardError
      [path]
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
      valid_types = %w[user assistant progress system attachment].freeze

      File.foreach(file_path) do |line|
        entry = JSON.parse(line.strip, symbolize_names: false)
        next unless entry.is_a?(Hash)
        next unless valid_types.include?(entry['type'])
        next unless entry['uuid'].is_a?(String)

        entries << entry
      rescue JSON::ParserError
        next
      end
      entries
    end

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

        SessionMessage.new(
          type: entry['type'],
          uuid: entry['uuid'],
          session_id: entry['sessionId'] || entry['session_id'] || '',
          message: entry['message']
        )
      end
    end

    private_class_method :list_sessions_for_directory, :list_all_sessions,
                         :deduplicate_sessions, :detect_worktrees,
                         :find_session_file, :parse_jsonl_entries,
                         :build_conversation_chain, :walk_to_leaf, :walk_to_root,
                         :filter_visible_messages, :read_head_tail, :build_session_info
  end
end
