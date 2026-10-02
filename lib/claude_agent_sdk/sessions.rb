# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'
require_relative 'errors'
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

  # A single message from a session transcript.
  #
  # +parent_tool_use_id+ / +parent_agent_id+ are only populated for messages
  # returned by get_subagent_messages / get_subagent_messages_from_store:
  # respectively the id of the Agent tool_use block in the parent session that
  # spawned the subagent, and (for nested subagents) the agent id of the
  # subagent that spawned it. Both are nil when the subagent's metadata is
  # unavailable, and always nil for top-level session messages.
  class SessionMessage
    attr_accessor :type, :uuid, :session_id, :message, :parent_tool_use_id, :parent_agent_id

    def initialize(type:, uuid:, session_id:, message:, parent_tool_use_id: nil, parent_agent_id: nil)
      @type = type
      @uuid = uuid
      @session_id = session_id
      @message = message
      @parent_tool_use_id = parent_tool_use_id
      @parent_agent_id = parent_agent_id
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
  #
  # @api private
  module Sessions # rubocop:disable Metrics/ModuleLength -- session listing/reading functions share private helpers
    LITE_READ_BUF_SIZE = 65_536
    MAX_SANITIZED_LENGTH = 200

    # How far into a transcript the disk listing looks for the first prompt,
    # and for the first timestamp, when the head window holds none (see
    # first_prompt_from_file, created_at_from_file).
    FIRST_PROMPT_SCAN_LIMIT = 1_048_576

    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    # Subagent ids as the CLI writes them (agent-<id>.jsonl): hex ids and
    # prefixed forms like `aprompt_suggestion-1a2b3c`. The store readers
    # synthesize `subagents/agent-<agent_id>` subpaths from caller input, so
    # anything that could re-route a path-, prefix-, or URL-shaped adapter key
    # ('/', '\', '..', '%', NUL, whitespace) is rejected at the boundary.
    AGENT_ID_RE = /\A[A-Za-z0-9._-]+\z/

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

    # Sanitize a filesystem path to a project directory name.
    #
    # The CLI does this with JavaScript's replace(/[^a-zA-Z0-9]/g, "-"),
    # without the `u` flag: the replacement runs per UTF-16 code unit, so a
    # character outside the BMP (an emoji, a CJK Extension B ideograph) is a
    # surrogate pair and becomes TWO hyphens. One hyphen per code point named
    # a directory the CLI never created — every directory-scoped session API
    # came back empty for such a path, and the store key computed here did
    # not match the one the transcript mirror derives from the CLI's own
    # path. (The hash below already works on code units, see simple_hash.)
    def sanitize_path(name)
      sanitized = name.gsub(SANITIZE_RE) { |char| char.ord > 0xFFFF ? '--' : '-' }
      return sanitized if sanitized.length <= MAX_SANITIZED_LENGTH

      "#{sanitized[0, MAX_SANITIZED_LENGTH]}-#{simple_hash(name)}"
    end

    # Resolve a directory to its canonical form (realpath + NFC), matching the
    # CLI's project-directory naming.
    #
    # A path that cannot be resolved as a whole (the directory was removed, or
    # does not exist yet) is resolved as far as it exists: symlinks in the
    # nearest existing ancestor are followed and the missing rest is appended
    # as written — what Python's os.path.realpath does, where Ruby's
    # File.realpath raises. The CLI keyed the project by the real path while
    # the directory existed, so a removed /tmp/proj on macOS must still
    # canonicalize to /private/tmp/proj for its sessions to be found; a plain
    # expand_path (the earlier fallback) resolved no symlink at all.
    def canonicalize_path(dir)
      File.realpath(dir).unicode_normalize(:nfc)
    rescue SystemCallError
      existing = File.expand_path(dir)
      missing = []
      until File.exist?(existing) || existing == File.dirname(existing)
        missing.unshift(File.basename(existing))
        existing = File.dirname(existing)
      end
      resolved = begin
        File.realpath(existing)
      rescue SystemCallError
        existing
      end
      File.join(resolved, *missing).unicode_normalize(:nfc)
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

    # Get the Claude config directory (respects CLAUDE_CONFIG_DIR; an empty
    # value is treated as unset, matching the Node CLI and the Python SDK).
    # NFC-normalized on both branches like Python's _get_claude_config_home_dir.
    #
    # @raise [ConfigDirError] when CLAUDE_CONFIG_DIR is unset and there is no
    #   usable home directory (see .home_dir) for the default ~/.claude.
    #   Python raises too (Path.home() -> RuntimeError); `~` expansion here
    #   raised a bare ArgumentError from deep inside every disk session API.
    def config_dir
      dir = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
      return dir.unicode_normalize(:nfc) if dir && !dir.empty?

      home = home_dir
      unless home
        raise ConfigDirError,
              'Cannot locate the Claude config directory: CLAUDE_CONFIG_DIR is unset and the home directory ' \
              'could not be resolved (HOME is unset, empty or relative, and the user has no passwd entry). ' \
              'Set CLAUDE_CONFIG_DIR to the directory holding your Claude Code data (normally ~/.claude).'
      end

      File.join(home, '.claude').unicode_normalize(:nfc)
    end

    # A usable home directory, or nil when there is none. The ONE definition
    # of "home" for the SDK (CLI discovery, disk session APIs, the transcript
    # mirror, store-backed resume seeding).
    #
    # Without +env+, the parent process's home: Dir.home raises ArgumentError
    # when HOME is unset and the uid has no passwd entry (docker --user in a
    # minimal image), and returns an empty or relative HOME verbatim — a path
    # under "" or a cwd-relative dir is not where the user's data lives (and
    # a relative CLI hit would be spawned from options.cwd, i.e. a different
    # file), so both read as "no home".
    #
    # With +env+ (a ClaudeAgentOptions#env Hash), the home the CLI CHILD will
    # see: a HOME key there wins, by key presence like the CLAUDE_CONFIG_DIR
    # override, and must be absolute. An explicit nil (the transport unsets
    # HOME for the child, which then falls back to its passwd entry) is also
    # treated as no home rather than guessing that entry.
    #
    # @api private
    def home_dir(env = nil)
      home = if env.respond_to?(:key?) && (env.key?('HOME') || env.key?(:HOME))
               env['HOME'] || env[:HOME]
             else
               Dir.home
             end
      home if home.is_a?(String) && File.absolute_path?(home)
    rescue ArgumentError
      nil
    end

    # Find the project directory for a given path
    def find_project_dir(path)
      projects_dir = File.join(config_dir, 'projects')
      return nil unless File.directory?(projects_dir)

      sanitized = sanitize_path(path)
      exact_path = File.join(projects_dir, sanitized)
      return exact_path if File.directory?(exact_path)
      return nil unless sanitized.length > MAX_SANITIZED_LENGTH

      # A long path is stored under its first 200 characters plus a hash of
      # the whole path. Older CLIs hashed with Bun.hash, so a directory with
      # the same prefix and another suffix may be this path's — or that of
      # ANY path sharing the prefix (a sibling in a deep per-tenant tree).
      # The name cannot tell them apart; a transcript inside can: accept a
      # candidate only if one records the path as its cwd (recorded_cwd), and
      # only when exactly one candidate does. Taking the first prefix match
      # listed, read and renamed another project's sessions for a directory
      # that had none of its own. A directory whose transcripts record no cwd
      # is not used: no guess from the name alone. The directory returned may
      # still hold sessions of other paths sharing the prefix: callers keep
      # only the path's own transcripts (own_transcript?).
      prefix = sanitized[0, MAX_SANITIZED_LENGTH + 1] # includes the trailing '-'
      verified = Dir.children(projects_dir).select do |child|
        candidate = File.join(projects_dir, child)
        child.start_with?(prefix) && File.directory?(candidate) && project_dir_records_cwd?(candidate, path)
      end
      verified.length == 1 ? File.join(projects_dir, verified.first) : nil
    end

    # Whether a session transcript in +project_dir+ was recorded for +path+.
    def project_dir_records_cwd?(project_dir, path)
      Dir.children(project_dir).any? do |name|
        name.end_with?('.jsonl') && valid_session_id?(name.delete_suffix('.jsonl')) &&
          recorded_cwd(File.join(project_dir, name)) == path
      end
    rescue SystemCallError
      false
    end

    # Whether +file_path+, a transcript in +project_dir+ — the directory
    # find_project_dir returned for +path+ — is one of +path+'s sessions. Every
    # transcript of the directory named after the path is. In a directory the
    # long-path prefix fallback found, only one whose own recorded cwd is the
    # path: that directory can hold the sessions of every path sharing the
    # prefix, and a transcript whose cwd cannot be verified is not counted.
    def own_transcript?(project_dir, file_path, path)
      File.basename(project_dir) == sanitize_path(path) || recorded_cwd(file_path) == path
    end

    # The directory a session transcript was recorded in: the first non-blank
    # top-level cwd of a COMPLETE line in its first LITE_READ_BUF_SIZE bytes,
    # NFC-normalized; nil when there is none (or the file cannot be read). A
    # line the window cuts establishes nothing: its top-level shape cannot be
    # checked, and a raw "cwd" match on it may sit inside a tool input.
    def recorded_cwd(file_path)
      File.open(file_path, 'rb') do |file|
        head = file.read(LITE_READ_BUF_SIZE) || ''
        each_parsed_entry(head, file.eof?) do |entry|
          cwd = entry['cwd']
          return cwd.unicode_normalize(:nfc) if cwd.is_a?(String) && presence(cwd)
        end
      end
      nil
    rescue SystemCallError
      nil
    end

    # Yield each Hash entry parsed from a COMPLETE line of +text+, a window
    # read from the start of a transcript: every line that ends in a newline,
    # and the last one too when +to_eof+ (the window reaches the end of the
    # file). A line that does not parse is skipped.
    def each_parsed_entry(text, to_eof)
      complete = to_eof ? text.bytesize : (text.byterindex("\n") || -1) + 1
      text.byteslice(0, complete).each_line do |line|
        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        yield entry if entry.is_a?(Hash)
      end
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

    # Byte-scan for `"key":"` like extract_json_string_field, but verify each
    # match by JSON-parsing its containing line and reading the key at the TOP
    # LEVEL of the entry. The raw scan also matches keys nested inside
    # tool_use inputs (real transcripts carry unescaped `"summary":"..."` in
    # subagent/teammate tool arguments), which made the disk path report
    # tool-argument text as the session summary/title while the store fold —
    # which reads only top-level keys — disagreed. A line that doesn't parse
    # (truncated at the head/tail window edge) keeps the raw-scan value: its
    # top-level shape can't be checked, and dropping it would regress the
    # common case of a true entry cut by the 64KB window. Unverified blanks
    # cannot clear a previously verified value: they may be nested tool inputs.
    #
    # +skip_blank+ passes over verified blank values too, for set-once fields
    # the store fold only takes when non-blank (cwd): there a blank entry is
    # absent, not a clearing entry.
    def extract_top_level_string_field(text, key, last: false, skip_blank: false)
      positions = field_match_positions(text, key)
      positions.reverse! if last
      parsed_lines = {}
      positions.each do |idx, value_start|
        line_start = (text.rindex("\n", idx) || -1) + 1
        entry = parsed_lines.fetch(line_start) do
          parsed_lines[line_start] = parse_containing_line(text, line_start, idx)
        end
        if entry
          value = entry[key]
          return value if value.is_a?(String) && (!skip_blank || presence(value))

          next # parseable line without a usable top-level string value: nested/false match
        end
        value = extract_json_string_value(text, value_start)
        value = presence(unescape_json_string(value)) if value
        return value if value
      end
      nil
    end

    # Match positions of both compact and spaced `"key":` patterns, sorted by
    # position so first/last selection is by document order (the pattern-major
    # order of extract_json_string_field is wrong when spacings mix).
    def field_match_positions(text, key)
      positions = []
      ["\"#{key}\":\"", "\"#{key}\": \""].each do |pattern|
        pos = 0
        while (idx = text.index(pattern, pos))
          value_start = idx + pattern.length
          positions << [idx, value_start]
          pos = value_start
        end
      end
      positions.sort_by!(&:first)
      positions
    end

    # Parse the JSONL line containing byte offset +idx+. Returns the entry
    # Hash, {} for parseable non-Hash lines (a match inside one is nested by
    # definition), or nil when the line doesn't parse (window truncation).
    def parse_containing_line(text, line_start, idx)
      line_end = text.index("\n", idx) || text.length
      entry = JSON.parse(text[line_start...line_end])
      entry.is_a?(Hash) ? entry : {}
    rescue StandardError
      nil
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

    # Unescape a JSON string value. A slice that does not parse as a JSON
    # string (a raw control character in it) is returned as it is — tagged
    # UTF-8: the windows it is cut from are binary (read_head_tail).
    def unescape_json_string(str)
      JSON.parse("\"#{str}\"")
    rescue JSON::ParserError
      str.encoding == Encoding::UTF_8 ? str : str.dup.force_encoding(Encoding::UTF_8)
    end

    # Python's `x or None` for the summary/title fallback chains: Ruby's ||
    # treats "" as truthy, so a CLI title-clearing entry ({"customTitle":""})
    # would win over a real first prompt and then fail the summary presence
    # check — silently dropping the whole session from disk listings.
    # Whitespace-only counts as blank because the final gate strips. The ONE
    # definition for both summary paths (SessionSummary calls it too): a
    # second copy that only rejected "" let the store path list an invisible
    # whitespace summary the disk path hid.
    def presence(val)
      return nil if val.nil?
      # An invalidly encoded String (JSON.parse accepts raw invalid UTF-8
      # inside strings) is unusable metadata, and String#strip would raise.
      return nil if val.is_a?(String) && (!val.valid_encoding? || val.strip.empty?)

      val
    end

    # Boundary checks for caller-supplied ids. A non-String id gets exactly
    # the malformed-id answer (nil / [] / ArgumentError, per API) instead of
    # a NoMethodError from deep inside (`123.match?`, `123.empty?`) — and so
    # does an invalidly encoded String, on which the regexp match itself
    # raises ArgumentError ("invalid byte sequence").
    #
    # @api private
    def valid_session_id?(session_id)
      session_id.is_a?(String) && session_id.valid_encoding? && session_id.match?(UUID_RE)
    end

    def valid_agent_id?(agent_id)
      agent_id.is_a?(String) && agent_id.valid_encoding? && agent_id.match?(AGENT_ID_RE) &&
        !%w[. ..].include?(agent_id)
    end

    # Adapters contractually report mtime as an epoch-ms Numeric (the
    # conformance suite asserts it), but SQL timestamps naturally arrive as
    # ISO-8601 Strings through JSON. Unary minus on a String is String#-@
    # (frozen-string dedup), so String mtimes sorted lexicographically
    # ASCENDING — oldest first, so `limit` cut off the newest sessions and
    # --continue resumed the oldest — and mixed Integer/String lists raised a
    # bare ArgumentError. Coerce defensively wherever an adapter mtime is
    # ordered or compared: numeric strings and ISO-8601 both order
    # correctly; anything else sorts last rather than crashing.
    #
    # A Time (e.g. an ActiveRecord updated_at) counts as its instant in epoch
    # ms. Non-finite values (Infinity, "1e400") also read as 0: they cannot be
    # ordered against real clocks nor reported as epoch ms.
    def sortable_mtime(value)
      ms = case value
           when Numeric then value
           when Time then value.to_r * 1000
           when String then Float(value, exception: false) || parse_iso_timestamp_ms(value)
           end
      ms.is_a?(Numeric) && ms.real? && ms.finite? ? ms : 0
    end

    # An adapter mtime as SDKSessionInfo#last_modified promises it: Integer
    # epoch milliseconds. Same coercion as sortable_mtime (so a row reports
    # the value it is ordered by), truncated to whole milliseconds.
    #
    # @api private
    def epoch_ms_mtime(value)
      sortable_mtime(value).to_i
    end

    # Sort key shared by every session listing, disk and store: newest first,
    # ties broken by session_id ascending. sort_by is not stable, so without
    # the secondary key equal mtimes (coarse adapter clocks, bulk imports)
    # ordered arbitrarily between calls and offset/limit paging could skip or
    # repeat sessions; one key also keeps the two paths in the same order.
    #
    # @api private
    def listing_sort_key(mtime, session_id)
      [-sortable_mtime(mtime), session_id.to_s]
    end

    # Extract the first meaningful user prompt from the head of a JSONL file
    def extract_first_prompt_from_head(head)
      prompt, command_fallback = first_prompt_in(head)
      prompt || command_fallback || ''
    end

    # The first real user prompt among the lines of +text+, and the name of
    # the first slash command seen on the way (what a session without a real
    # prompt reports): [prompt or nil, command name or nil]. +command_fallback+
    # carries a name found in an earlier part of the same transcript.
    def first_prompt_in(text, command_fallback = nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- first-prompt skip rules, matched by the store fold
      text.each_line do |line|
        next unless line.include?('"type":"user"') || line.include?('"type": "user"')
        next if line.include?('"tool_result"')
        next if line.include?('"isMeta":true') || line.include?('"isMeta": true')
        next if line.include?('"isCompactSummary":true') || line.include?('"isCompactSummary": true')

        # +text+ may be a binary window or chunk: the line becomes UTF-8 here,
        # scrubbed, so the text handling below never meets a stray byte.
        entry = JSON.parse(utf8_transcript_text(line), symbolize_names: false)
        texts = user_entry_texts(entry)
        next unless texts

        texts.each do |text|
          text = text.gsub(/\n+/, ' ').strip
          next if text.empty?

          if (m = text.match(COMMAND_NAME_RE))
            command_fallback ||= m[1]
            next
          end

          next if text.match?(SKIP_FIRST_PROMPT_PATTERN)

          return [text.length > 200 ? "#{text[0, 200]}…" : text, command_fallback]
        end
      rescue JSON::ParserError
        next
      end

      [nil, command_fallback]
    end

    # first_prompt for the disk listing: from the head window, and when that
    # holds no real prompt while the file goes on, from a bounded scan past
    # it. CLI 2.1.x transcripts often carry a large attachment (a
    # SessionStart hook's output) before the first prompt, and an SDK prompt
    # that inlines a document is one line longer than the window; the head
    # alone reported nil or a slash-command name for those, and a session
    # with no other summary source was not listed at all — while the store
    # fold, which sees every entry, reported the prompt.
    def first_prompt_from_file(file_path, head, size)
      prompt, command_fallback = first_prompt_in(head)
      if prompt.nil? && size > head.bytesize
        limit = [size, FIRST_PROMPT_SCAN_LIMIT].min
        prompt, command_fallback = first_prompt_past_head(file_path, head, limit, command_fallback)
      end
      prompt || command_fallback || ''
    end

    # Continue the first-prompt scan past +head+ (see each_line_past_head). An
    # IO failure there leaves the answer the head gave.
    def first_prompt_past_head(file_path, head, limit, command_fallback)
      each_line_past_head(file_path, head, limit) do |line|
        prompt, command_fallback = first_prompt_in(line, command_fallback)
        return [prompt, command_fallback] if prompt
      end
      [nil, command_fallback]
    end

    # Yield the lines of a transcript that follow the last complete line of
    # +head+, up to byte +limit+ of the file. Read in fixed-size chunks,
    # never line by line: one transcript line can be gigabytes, and the
    # limit has to hold before the bytes are in memory. What is yielded last
    # is the final line of a file without a closing newline — or a line cut
    # by the limit, which does not parse and is skipped by its consumer like
    # any other bad line. An IO failure ends the read quietly: this read is
    # an extra, and must not hide a session.
    def each_line_past_head(file_path, head, limit, &)
      offset = (head.byterindex("\n") || -1) + 1
      open_line = String.new(encoding: Encoding::BINARY)
      File.open(file_path, 'rb') do |file|
        file.seek(offset)
        while offset < limit && (chunk = file.read([LITE_READ_BUF_SIZE, limit - offset].min))
          offset += chunk.bytesize
          open_line << chunk
          newline = open_line.rindex("\n")
          open_line.slice!(0, newline + 1).each_line(&) if newline
        end
        yield open_line unless open_line.empty?
      end
    rescue SystemCallError
      nil
    end

    # Text blocks of a genuine user entry, or nil when the line should be
    # skipped. Shape guards ported from Python: the byte pre-filter can match
    # `"type":"user"` nested inside a tool_use input on an assistant line, so
    # the parsed type is rechecked; and a malformed head line (non-Hash entry,
    # string `message`, non-string `text`) must skip just that line rather
    # than blow up into read_session_lite's blanket rescue and silently drop
    # the whole session from disk listings.
    def user_entry_texts(entry)
      return nil unless entry.is_a?(Hash) && entry['type'] == 'user'

      message = entry['message']
      return nil unless message.is_a?(Hash)

      content = message['content']
      if content.is_a?(String)
        [content]
      elsif content.is_a?(Array)
        content.filter_map do |block|
          block['text'] if block.is_a?(Hash) && block['type'] == 'text' && block['text'].is_a?(String)
        end
      end
    end

    # Read a single session file with lite (head/tail) strategy
    def read_session_lite(file_path, project_path)
      stat = File.stat(file_path)
      return nil if stat.size.zero? # rubocop:disable Style/ZeroLengthPredicate

      head, tail = read_head_tail(file_path, stat.size)

      return nil if sidechain_head?(head, stat.size > LITE_READ_BUF_SIZE)

      build_session_info(file_path, head, tail, stat, project_path)
    rescue StandardError
      nil
    end

    # Sidechain classification reads the top-level key of the FIRST PARSEABLE
    # entry — the entry the store fold classifies from (it sets is_sidechain
    # once, from the first Hash entry; a store never holds an unparseable line
    # since import skips them). The old raw substring scan also matched
    # "isSidechain":true nested inside a structured field, and classifying
    # strictly from line one let a corrupt/blank/non-object first line make
    # the two paths disagree about whether the session exists. So blank,
    # unparseable, and non-object lines are skipped — except a final line cut
    # by the head window: it isn't corrupt, just unseen, so it can't be
    # shape-checked and keeps the substring heuristic.
    def sidechain_head?(head, window_truncated)
      lines = head.lines
      lines.each_with_index do |line, idx|
        # (An invalidly encoded line isn't blank — and strip would raise on it.)
        next if line.valid_encoding? && line.strip.empty?

        begin
          entry = JSON.parse(line)
        rescue StandardError
          next unless window_truncated && idx == lines.length - 1 && !line.end_with?("\n")

          return line.include?('"isSidechain":true') || line.include?('"isSidechain": true')
        end
        return entry['isSidechain'] == true if entry.is_a?(Hash)
      end
      false
    end

    # The first and the last LITE_READ_BUF_SIZE bytes of a transcript, as
    # BINARY Strings — on purpose. The field scanners step through a window
    # by offset (String#index with a position, text[pos], #length), and Ruby
    # keeps no character index for a UTF-8 String that is not ASCII-only:
    # there every one of those steps walks the bytes from the start, so a
    # scan with many matches is quadratic in the window, and one multibyte
    # character anywhere in it is enough (nearly every real transcript has
    # one). On bytes each step is O(1). The patterns are ASCII, JSON.parse
    # reads a binary source as UTF-8, and the two places that return a raw
    # slice of the window tag it UTF-8 (unescape_json_string), so every value
    # that leaves the scanners is a UTF-8 String as before.
    def read_head_tail(file_path, size)
      head = tail = nil
      File.open(file_path, 'rb') do |f|
        head = f.read(LITE_READ_BUF_SIZE) || String.new(encoding: Encoding::BINARY)
        tail = if size > LITE_READ_BUF_SIZE
                 f.seek([0, size - LITE_READ_BUF_SIZE].max)
                 f.read(LITE_READ_BUF_SIZE) || String.new(encoding: Encoding::BINARY)
               else
                 head
               end
      end
      [head, tail]
    end

    # [title, first prompt] of a transcript on disk, each nil when absent: the
    # two values a disk listing reports as custom_title and first_prompt, and
    # the ones fork_session names a fork after (SessionMutations).
    #
    # Title: the user-set title (customTitle) wins over the AI-generated one
    # (aiTitle). The head is consulted only when the tail has no occurrence
    # of the field, and blanks are normalized AFTER the latest occurrence was
    # chosen (display_title): an explicit clearing entry must not resurrect an
    # older title from the head. The top-level-verified scan is used: a raw
    # byte scan also matches these keys nested inside tool_use inputs,
    # reporting tool arguments as the session title (and diverging from the
    # store fold, which reads top-level keys only).
    def title_and_first_prompt(file_path, head, tail, size)
      custom, generated = %w[customTitle aiTitle].map do |key|
        extract_top_level_string_field(tail, key, last: true) || extract_top_level_string_field(head, key, last: true)
      end
      # nil, not '', when there is no prompt — the store path's answer, and
      # Python's (`_extract_first_prompt_from_head(head) or None`).
      [display_title(custom, generated), presence(first_prompt_from_file(file_path, head, size))]
    end

    # The ONE rule for a session's title, given the latest custom title and the
    # latest AI title of its transcript: blank counts as absent, custom first.
    # Shared by the disk listing, and by fork_session on the disk and the
    # store path (the store listing applies it in SessionSummary).
    def display_title(custom_title, ai_title)
      presence(custom_title) || presence(ai_title)
    end

    # created_at (epoch ms) for the disk listing: the first top-level
    # timestamp that parses — what the store fold takes. More reliable than
    # stat().birthtime, which is unsupported on some filesystems. Every line
    # is looked at, not only the first: the first record may be a
    # metadata-only entry (e.g. permission-mode) with no timestamp field, and
    # the first user/assistant record that follows carries one (Python #907).
    #
    # Parsed top-level fields of COMPLETE lines only, never a raw match: a
    # file-history-snapshot entry, common near the start of an interactive
    # session, has no timestamp of its own but nests one
    # (snapshot.timestamp), and on a line the head window cuts a raw match
    # cannot be told from such a nested one. When the complete head lines
    # hold no timestamp and the file goes on, the lines past them are read
    # to their end instead (bounded like the first-prompt scan): the cut line
    # is usually the one that carries it — an SDK prompt of more than 64 KiB
    # makes the very first line that long.
    def created_at_from_file(file_path, head, size)
      to_eof = size <= head.bytesize
      each_parsed_entry(head, to_eof) do |entry|
        created_at = parse_iso_timestamp_ms(entry['timestamp'])
        return created_at if created_at
      end
      return nil if to_eof

      each_line_past_head(file_path, head, [size, FIRST_PROMPT_SCAN_LIMIT].min) do |line|
        each_parsed_entry(line, true) do |entry|
          created_at = parse_iso_timestamp_ms(entry['timestamp'])
          return created_at if created_at
        end
      end
      nil
    end

    def build_session_info(file_path, head, tail, stat, project_path) # rubocop:disable Metrics/AbcSize -- one optional field per SDKSessionInfo attribute
      custom_title, first_prompt = title_and_first_prompt(file_path, head, tail, stat.size)
      # lastPrompt tail entry shows what the user was most recently doing.
      summary = custom_title ||
                presence(extract_top_level_string_field(tail, 'lastPrompt', last: true)) ||
                presence(extract_top_level_string_field(tail, 'summary', last: true)) ||
                first_prompt
      return nil if summary.nil? || summary.strip.empty?

      # Scope tag extraction to {"type":"tag"} lines — a bare tail scan for
      # "tag" would match tool_use inputs (git tag, Docker tags, etc.).
      tag_line = tail.lines.reverse.find { |ln| ln.start_with?('{"type":"tag"') }
      tag_value = presence(tag_line ? extract_json_string_field(tag_line, 'tag', last: true) : nil)

      created_at = created_at_from_file(file_path, head, stat.size)

      SDKSessionInfo.new(
        session_id: File.basename(file_path, '.jsonl'),
        summary: summary,
        last_modified: (stat.mtime.to_f * 1000).to_i,
        file_size: stat.size,
        custom_title: custom_title,
        first_prompt: first_prompt,
        # presence: blank metadata reads as absent, exactly as the store path
        # (SessionSummary.summary_entry_to_sdk_info) reports it.
        git_branch: presence(extract_json_string_field(tail, 'gitBranch', last: true) ||
                             extract_json_string_field(head, 'gitBranch', last: false)),
        # The first non-blank TOP-LEVEL cwd, exactly what the store fold keeps
        # (set-once, blank skipped): taking the first match even when blank
        # fell back to the project path where the store read a later entry's
        # cwd, and the raw scan also matched cwd keys nested in tool inputs.
        cwd: extract_top_level_string_field(head, 'cwd', skip_blank: true) || project_path,
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
      # Integer arithmetic: through a Float (to_f * 1000, truncated) about one
      # millisecond value in eight came out 1 ms low — ...30.933Z as ...932.
      time = Time.iso8601(timestamp_str)
      (time.to_i * 1000) + (time.nsec / 1_000_000)
    rescue ArgumentError
      nil
    end

    # Read all sessions from a project directory
    def read_sessions_from_dir(project_dir, project_path = nil)
      return [] unless File.directory?(project_dir)

      sessions = []
      # Listing a directory found by the long-path prefix fallback: only the
      # transcripts recorded for +project_path+ (own_transcript?).
      verify = project_path && File.basename(project_dir) != sanitize_path(project_path)
      # base:, not a pattern built from the directory: a config dir path with
      # glob characters in it (`/Volumes/Data [SSD]/…`, `/srv/{tenant}/…`)
      # is a path, and as part of the pattern it matched nothing.
      Dir.glob('*.jsonl', base: project_dir).each do |name|
        stem = File.basename(name, '.jsonl')
        next unless stem.match?(UUID_RE)

        file_path = File.join(project_dir, name)
        next if verify && recorded_cwd(file_path) != project_path

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

      # Sort by last_modified descending (ties by session_id, identically to
      # the store path), then apply offset and limit.
      # [limit, 0].max: limit <= 0 yields [] across the whole read-API family
      # (a bare first(-1) would raise ArgumentError here but silently clamp on
      # the store paths).
      sessions.sort_by! { |s| listing_sort_key(s.last_modified, s.session_id) }
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
      return nil unless valid_session_id?(session_id)

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
      return [] unless valid_session_id?(session_id)

      offset ||= 0

      file_path = find_session_file(session_id, directory)
      return [] unless file_path && File.exist?(file_path)

      begin
        entries = parse_jsonl_entries(file_path)
      rescue SystemCallError
        # TOCTOU between resolution and read (file deleted by another
        # process) — return [] like Python's except OSError, and like the
        # sibling get_subagent_messages.
        return []
      end
      chain = build_conversation_chain(entries)
      messages = filter_visible_messages(chain)

      # Apply offset and limit (limit <= 0 yields [], like every other reader)
      messages = messages[offset..] || []
      messages = messages.first([limit, 0].max) if limit
      messages
    end

    # List subagent IDs recorded for a session on local disk (counterpart to
    # list_subagents_from_store). Scans
    # <projectDir>/<sessionId>/subagents/**/agent-<id>.jsonl, including nested
    # workflows/<runId>/ paths, in sorted walk order (the Python SDK's
    # list_subagents, #825). Each id once, at its first position in the walk
    # — the transcript the message and metadata readers take for it. Python
    # does not dedupe here; an id whose transcript exists both directly and
    # under workflows/<runId>/ came back twice, where the store variant
    # returns it once.
    # @param session_id [String] The session UUID
    # @param directory [String, nil] Working directory to search in (strictly
    #   scopes to that project + its worktrees; nil searches all projects)
    # @return [Array<String>] Subagent IDs
    def list_subagents(session_id:, directory: nil)
      return [] unless valid_session_id?(session_id)

      subagents_dir = resolve_subagents_dir(session_id, directory)
      return [] if subagents_dir.nil?

      collect_agent_files(subagents_dir).map(&:first).uniq
    end

    # Read the optional subagent metadata sidecar without reading its transcript.
    # Uses the same project scoping and sorted first-match rule as the message
    # reader. This is historical metadata, not a live status query.
    # @return [Hash{String => Object}, nil] Original CLI fields, or nil if unavailable
    def get_subagent_metadata(session_id:, agent_id:, directory: nil)
      return nil unless valid_session_id?(session_id) && valid_agent_id?(agent_id)

      subagents_dir = resolve_subagents_dir(session_id, directory)
      return nil if subagents_dir.nil?

      _id, path = collect_agent_files(subagents_dir).find { |id, _path| id == agent_id }
      return nil if path.nil?

      read_agent_metadata_sidecar(path)
    rescue SystemCallError
      nil
    end

    # Read a subagent's conversation messages from local disk (counterpart to
    # get_subagent_messages_from_store). First match in sorted walk order wins
    # when the same agent id exists at multiple depths (mirrors Python).
    # @param session_id [String] The session UUID
    # @param agent_id [String] The subagent ID (without the agent- prefix)
    # @param directory [String, nil] Working directory to search in
    # @param limit [Integer, nil] Maximum number of messages
    # @param offset [Integer] Number of messages to skip
    # @return [Array<SessionMessage>] Ordered messages from the subagent
    def get_subagent_messages(session_id:, agent_id:, directory: nil, limit: nil, offset: 0)
      return [] unless valid_session_id?(session_id) && valid_agent_id?(agent_id)

      subagents_dir = resolve_subagents_dir(session_id, directory)
      return [] if subagents_dir.nil?

      _id, path = collect_agent_files(subagents_dir).find { |id, _path| id == agent_id }
      return [] if path.nil?

      begin
        entries = parse_jsonl_entries(path)
      rescue SystemCallError
        # TOCTOU between the walk and the read (mirrors Python's
        # `except OSError: return []`).
        return []
      end

      # The .meta.json sidecar next to the transcript records which Agent
      # tool_use spawned this subagent (and, for nested subagents, the parent
      # agent id). Like the transcript read above this is best-effort: any
      # failure to read it degrades to "no metadata" rather than raising.
      meta = begin
        read_agent_metadata_sidecar(path)
      rescue SystemCallError
        nil
      end
      parent_tool_use_id, parent_agent_id = parent_ids_from_agent_metadata(meta)

      entries_to_subagent_messages(entries, limit, offset, parent_tool_use_id, parent_agent_id)
    end

    # agent-<id>.jsonl -> agent-<id>.meta.json in the same directory. The single
    # definition of the sidecar naming convention, shared by the disk read path,
    # session import, and resume materialization.
    # @param transcript_path [String] Path to the subagent .jsonl transcript
    # @return [String] Path to the sidecar
    def agent_metadata_sidecar_path(transcript_path)
      "#{transcript_path.delete_suffix('.jsonl')}.meta.json"
    end

    # Separate the synthetic agent_metadata entry from transcript lines.
    #
    # A subagent's SessionStore stream carries its .meta.json sidecar as
    # { 'type' => 'agent_metadata', ... } entries alongside the transcript.
    # Returns [metadata, transcript] where metadata is the LAST such entry (it
    # is rewritten on resume, so last wins) or nil.
    # @param entries [Array] Raw store/transcript entries
    # @return [Array(Hash, Array)] [metadata_or_nil, transcript_entries]
    def split_agent_metadata(entries)
      metadata = nil
      transcript = []
      entries.each do |e|
        if e.is_a?(Hash) && e['type'] == 'agent_metadata'
          metadata = e
        else
          transcript << e
        end
      end
      [metadata, transcript]
    end

    # ---- SessionStore-backed reads (store counterparts to the disk readers) ----

    # List sessions from a SessionStore. Store-backed counterpart to
    # list_sessions. Uses the store's incremental summaries (one batch call +
    # gap-fill) when available, else falls back to list_sessions + one load per
    # session. Sessions are derived by folding EVERY entry
    # (SessionSummary.fold_session_summary), field by field under the rules
    # of the disk reader — which only reads the head and tail windows of a
    # transcript (plus the bounded first-prompt scan). The two paths agree
    # for identical transcript content unless the entry deciding a field
    # lies outside those windows; docs/sessions.md ("Listing Sessions") lists
    # the cases.
    #
    # @param session_store [SessionStore] store implementing list_session_summaries and/or list_sessions
    # @return [Array<SDKSessionInfo>] sorted by last_modified descending
    def list_sessions_from_store(session_store:, directory: nil, limit: nil, offset: 0)
      offset ||= 0
      project_path = canonicalize_path(directory.nil? ? '.' : directory.to_s)
      project_key = sanitize_path(project_path)

      via = list_sessions_via_summaries(session_store, project_key, project_path, limit, offset)
      return via unless via.nil?

      listed, listing = SessionStores.optional_call(session_store, :list_sessions) do
        session_store.list_sessions(project_key)
      end
      unless listed
        raise ArgumentError,
              'session_store implements neither list_session_summaries nor list_sessions -- cannot list sessions'
      end

      listing = Array(listing)
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
      slots.sort_by! { |slot| listing_sort_key(slot[:mtime], slot[:session_id]) }
      paginate_resolving_gaps(session_store, project_key, project_path, slots, limit, offset)
    end

    # Read metadata for a single session from a SessionStore. Store-backed
    # counterpart to get_session_info. Returns nil for an invalid UUID, an
    # unknown session, a sidechain session, or one with no extractable summary.
    def get_session_info_from_store(session_store:, session_id:, directory: nil)
      return nil unless valid_session_id?(session_id)

      project_path = canonicalize_path(directory.nil? ? '.' : directory.to_s)
      project_key = sanitize_path(project_path)
      entries = session_store.load('project_key' => project_key, 'session_id' => session_id)
      return nil if entries.nil? || entries.empty?

      mtime = store_session_mtime(session_store, project_key, session_id) || mtime_from_entries(entries)
      derive_info_from_entries(session_id, entries, mtime, project_path)
    end

    # Read a session's conversation messages from a SessionStore. Store-backed
    # counterpart to get_session_messages.
    def get_session_messages_from_store(session_store:, session_id:, directory: nil, limit: nil, offset: 0)
      return [] unless valid_session_id?(session_id)

      offset ||= 0
      entries = session_store.load('project_key' => project_key_for_directory(directory), 'session_id' => session_id)
      return [] if entries.nil? || entries.empty?

      entries_to_messages(filter_transcript_entries(entries), limit, offset)
    end

    # List subagent IDs for a session from a SessionStore. Requires the store to
    # implement list_subkeys.
    def list_subagents_from_store(session_store:, session_id:, directory: nil)
      return [] unless valid_session_id?(session_id)

      project_key = project_key_for_directory(directory)
      implemented, subkeys = SessionStores.optional_call(session_store, :list_subkeys) do
        session_store.list_subkeys('project_key' => project_key, 'session_id' => session_id)
      end
      unless implemented
        raise ArgumentError,
              'session_store does not implement list_subkeys -- cannot list subagents'
      end

      seen = {}
      Array(subkeys).filter_map do |subpath|
        # A non-String subkey (Symbol, nil, Integer) is an adapter contract
        # violation; skip it like resume does instead of calling String
        # methods on it.
        next unless subpath.is_a?(String) && subpath.start_with?('subagents/')

        last = subpath.rpartition('/').last
        next unless last.start_with?('agent-')

        agent_id = last.delete_prefix('agent-')
        next if seen[agent_id]

        seen[agent_id] = true
        agent_id
      end
    end

    # Store counterpart to get_subagent_metadata. The last agent_metadata entry
    # wins, including when no conversation messages have been mirrored yet.
    # The synthetic `type` marker is omitted; all other string-keyed fields
    # remain unchanged. Adapter failures propagate, like other store readers.
    # @return [Hash{String => Object}, nil]
    def get_subagent_metadata_from_store(session_store:, session_id:, agent_id:, directory: nil)
      return nil unless valid_session_id?(session_id) && valid_agent_id?(agent_id)

      project_key = project_key_for_directory(directory)
      subpath = resolve_subagent_subpath(session_store, project_key, session_id, agent_id)
      return nil if subpath.nil?

      entries = session_store.load('project_key' => project_key, 'session_id' => session_id, 'subpath' => subpath)
      metadata, = split_agent_metadata(entries || [])
      metadata&.except('type')
    end

    # Read a subagent's conversation messages from a SessionStore. Subagents may
    # live at subagents/agent-<id> or nested under
    # subagents/workflows/<runId>/agent-<id>; scans subkeys to resolve the path
    # when the store implements list_subkeys, else tries the direct path.
    def get_subagent_messages_from_store(session_store:, session_id:, agent_id:, directory: nil, limit: nil, offset: 0)
      return [] unless valid_session_id?(session_id) && valid_agent_id?(agent_id)

      project_key = project_key_for_directory(directory)
      subpath = resolve_subagent_subpath(session_store, project_key, session_id, agent_id)
      return [] if subpath.nil?

      entries = session_store.load('project_key' => project_key, 'session_id' => session_id, 'subpath' => subpath)
      return [] if entries.nil? || entries.empty?

      # The synthetic agent_metadata entry (the store's copy of the .meta.json
      # sidecar) records which Agent tool_use spawned this subagent. Recover the
      # parent ids from it, then drop it: it is not a transcript line.
      meta_entry, transcript = split_agent_metadata(entries)
      return [] if transcript.empty?

      parent_tool_use_id, parent_agent_id = parent_ids_from_agent_metadata(meta_entry)
      entries_to_subagent_messages(filter_transcript_entries(transcript), limit, offset,
                                   parent_tool_use_id, parent_agent_id)
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
      raise ArgumentError, "Invalid session_id: #{session_id}" unless valid_session_id?(session_id)

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
    # result, or nil if the store does not implement list_session_summaries
    # (see SessionStores.optional_call; the caller falls back to the slow
    # path). Sessions missing
    # a sidecar or whose sidecar is stale (summary.mtime < the session's current
    # mtime) are routed through gap-fill so the fold is recomputed from source.
    def list_sessions_via_summaries(store, project_key, project_path, limit, offset) # rubocop:disable Metrics/AbcSize -- fast path plus stale/missing-sidecar gap-fill
      implemented, summaries = SessionStores.optional_call(store, :list_session_summaries) do
        store.list_session_summaries(project_key)
      end
      return nil unless implemented

      # Array(): a non-conformant store returning nil (e.g. a NULL JSONB read)
      # degrades to gap-fill instead of crashing on nil.each, matching the
      # defensive Array() already applied to list_sessions / list_subkeys.
      summaries = Array(summaries)
      has_list_sessions, listing = SessionStores.optional_call(store, :list_sessions) do
        store.list_sessions(project_key)
      end
      listing = Array(listing)
      known_mtimes = listing.to_h { |e| [e['session_id'], e['mtime']] }

      slots = []
      fresh = {}
      summaries.each do |summary|
        sid = summary['session_id']
        # || 0: a non-conformant adapter's missing mtime degrades to gap-fill, not a crash.
        s_mtime = summary['mtime'] || 0
        if has_list_sessions
          known = known_mtimes[sid]
          # known.nil?: no longer listed (drop). s_mtime < known: stale sidecar
          # (re-fold). Coerced: the sidecar and the listing may report the
          # same clock in different shapes (epoch Integer vs ISO String).
          next if known.nil? || sortable_mtime(s_mtime) < sortable_mtime(known)
        end
        fresh[sid] = true
        info = SessionSummary.summary_entry_to_sdk_info(summary, project_path)
        slots << { mtime: s_mtime, session_id: sid, info: info } unless info.nil?
      end
      listing.each do |e|
        next if fresh[e['session_id']]

        slots << { mtime: e['mtime'] || 0, session_id: e['session_id'], info: nil }
      end

      slots.sort_by! { |slot| listing_sort_key(slot[:mtime], slot[:session_id]) }
      paginate_resolving_gaps(store, project_key, project_path, slots, limit, offset)
    end

    # Walk slots newest-first, resolving gap-fill placeholders (info nil) on
    # demand and skipping any that resolve to sidechain / no-summary, then apply
    # offset/limit to the RESOLVED results. Paginating over surviving sessions
    # (not raw slots) matches the disk reader, so a placeholder that drops never
    # leaves a short page; loads stay bounded to ~offset + limit + (the dropped
    # placeholders encountered before the page fills), preserving the fast
    # path's "don't load every session" intent.
    def paginate_resolving_gaps(store, project_key, project_path, slots, limit, offset) # rubocop:disable Metrics/ParameterLists -- pagination state threaded explicitly
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
        return SDKSessionInfo.new(session_id: sid, summary: '', last_modified: epoch_ms_mtime(slot[:mtime]))
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

    # The adapter's own mtime for one session, as its listing reports it, or
    # nil when the store cannot be asked (it implements neither listing
    # method) or does not list the session.
    #
    # get_session_info(session_store:) stamps this as last_modified: it is the
    # clock list_sessions(session_store:) reports and orders by, and what the
    # docs promise on the store paths. The entries' own timestamps are another
    # clock — and absent from metadata entries, which gave last_modified 0 for
    # a session the listing showed with a real mtime. They remain the fallback
    # (mtime_from_entries) for a store with nothing but #append and #load.
    def store_session_mtime(store, project_key, session_id)
      listed, rows = SessionStores.optional_call(store, :list_sessions) { store.list_sessions(project_key) }
      unless listed
        _, rows = SessionStores.optional_call(store, :list_session_summaries) do
          store.list_session_summaries(project_key)
        end
      end
      row = Array(rows).find { |candidate| candidate.is_a?(Hash) && candidate['session_id'] == session_id }
      row && row['mtime']
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
      results = results.sort_by { |s| listing_sort_key(s.last_modified, s.session_id) }
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
    # Every message in one subagent transcript shares the same parent ids.
    def entries_to_subagent_messages(entries, limit, offset, parent_tool_use_id = nil, parent_agent_id = nil)
      offset ||= 0
      messages = build_subagent_chain(entries).filter_map do |entry|
        next unless %w[user assistant].include?(entry['type'])

        SessionMessage.new(
          type: entry['type'],
          uuid: entry['uuid'],
          session_id: entry['sessionId'] || entry['session_id'] || '',
          message: entry['message'],
          parent_tool_use_id: parent_tool_use_id,
          parent_agent_id: parent_agent_id
        )
      end
      messages = messages[offset..] || []
      messages = messages.first([limit, 0].max) if limit
      messages
    end

    # Find the last user/assistant entry and walk parentUuid links back to the
    # root, as Python's _build_subagent_chain does. Subagent transcripts are
    # not linear either (Python's comment says they are): parallel tool calls
    # fan out exactly as in a main transcript, so the results the walk passes
    # by are put back. No flag rejection there — every subagent entry is a
    # sidechain entry.
    def build_subagent_chain(entries)
      return [] if entries.empty?

      by_uuid = entries.to_h { |e| [e['uuid'], e] }
      leaf = entries.reverse_each.find { |e| %w[user assistant].include?(e['type']) }
      return [] unless leaf

      reattach_parallel_tool_results(walk_to_root(by_uuid, leaf), entries, skip_flagged: false)
    end

    # Find the subpath for a subagent, scanning subkeys (subagents may be nested
    # under subagents/workflows/<runId>/agent-<id>) when list_subkeys is
    # available, else falling back to the direct subagents/agent-<id> path.
    def resolve_subagent_subpath(store, project_key, session_id, agent_id)
      implemented, subkeys = SessionStores.optional_call(store, :list_subkeys) do
        store.list_subkeys('project_key' => project_key, 'session_id' => session_id)
      end
      return "subagents/agent-#{agent_id}" unless implemented

      target = "agent-#{agent_id}"
      matches = Array(subkeys)
                .select { |sk| sk.is_a?(String) && sk.start_with?('subagents/') && sk.rpartition('/').last == target }
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

        # A missing, corrupt, or non-object sidecar is treated as absent (the
        # transcript is still imported); other IO errors propagate.
        meta = read_agent_metadata_sidecar(file_path)
        next if meta.nil?

        # Synthetic 'agent_metadata' marker must always win so a future meta key
        # named 'type' can't reclassify the sidecar as a transcript line on resume.
        store.append(sub_key, [meta.merge('type' => 'agent_metadata')])
      end
    end

    # Read the .meta.json sidecar beside a subagent transcript. Returns nil when
    # the sidecar is missing, is not a regular file, is not valid UTF-8, is not
    # valid JSON, or is not a JSON object — an unusable optional sidecar
    # degrades to an absent one. Other IO errors (EACCES, ...) propagate;
    # callers that need a best-effort read rescue them.
    def read_agent_metadata_sidecar(transcript_path)
      path = agent_metadata_sidecar_path(transcript_path)
      # Check the type on the stat, before any open: opening a FIFO with no
      # writer blocks forever, and this optional read would hang the caller
      # with no exception for its best-effort rescue to catch.
      return nil unless File.stat(path).ftype == 'file'

      text = File.read(path, encoding: 'UTF-8')
      # JSON.parse is lenient about illegal bytes inside an otherwise
      # well-formed UTF-8-tagged document: it returns a Hash holding
      # invalidly-encoded values that only blow up later, at JSON.generate
      # time. Session import would persist such a Hash as an agent_metadata
      # entry, and every subsequent resume through that store would then die
      # re-serializing the sidecar. Treat unusable bytes as an absent sidecar.
      return nil unless text.valid_encoding?

      meta = JSON.parse(text)
      meta.is_a?(Hash) ? meta : nil
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    # Extract [toolUseId, parentAgentId] from an agent metadata hash, narrowing
    # both to String. Works for the on-disk .meta.json sidecar and for the
    # synthetic agent_metadata entry a SessionStore receives in its place.
    def parent_ids_from_agent_metadata(meta)
      return [nil, nil] unless meta.is_a?(Hash)

      tool_use_id = meta['toolUseId']
      parent_agent_id = meta['parentAgentId']
      [tool_use_id.is_a?(String) ? tool_use_id : nil,
       parent_agent_id.is_a?(String) ? parent_agent_id : nil]
    end

    def append_jsonl_file_in_batches(file_path, key, store, batch_size)
      batch = []
      nbytes = 0
      # Read as UTF-8 bytes regardless of locale (a LANG=C process raised
      # Encoding::InvalidByteSequenceError on the first multibyte line,
      # aborting the import mid-way; Python pins utf-8 here), and scrub a
      # line that is not valid UTF-8: Ruby's JSON parser accepts a raw
      # invalid byte inside a string, and the entry it yields makes every
      # adapter that serializes what it is given raise JSON::GeneratorError
      # from #append — after the batches before it were already stored.
      File.foreach(file_path, mode: 'rb').with_index(1) do |line, lineno|
        line = utf8_transcript_text(line).chomp
        next if line.empty?

        begin
          entry = JSON.parse(line)
        rescue JSON::ParserError
          # A truncated trailing line is an ordinary interrupted-CLI artifact;
          # every read path tolerates it (parse_jsonl_entries skips bad
          # lines), and raising here aborted mid-import, leaving a partial
          # store import behind. Skip the line, but say so — import is an
          # explicit user operation.
          warn "Claude SDK: import_session_to_store skipped unparseable line #{lineno} of #{file_path}"
          next
        end

        batch << entry
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
      # canonicalize_path (not raw realpath): a nonexistent directory must
      # canonicalize lexically and yield nil from find_project_dir — Python's
      # os.path.realpath never raises here.
      canonical = canonicalize_path(directory)
      project_dir = find_project_dir(canonical)
      if project_dir && own_transcript?(project_dir, File.join(project_dir, file_name), canonical)
        info = read_session_lite(File.join(project_dir, file_name), canonical)
        return info if info
      end

      # Worktree fallback — matches get_session_messages semantics.
      worktree_paths = detect_worktrees(canonical) rescue [] # rubocop:disable Style/RescueModifier
      worktree_paths.each do |wt_path|
        next if wt_path == canonical

        wt_project_dir = find_project_dir(wt_path)
        next unless wt_project_dir && own_transcript?(wt_project_dir, File.join(wt_project_dir, file_name), wt_path)

        info = read_session_lite(File.join(wt_project_dir, file_name), wt_path)
        return info if info
      end
      nil
    end

    def list_sessions_for_directory(directory, include_worktrees)
      path = canonicalize_path(directory)

      worktree_paths = []
      worktree_paths = detect_worktrees(path) if include_worktrees

      if worktree_paths.length <= 1
        project_dir = find_project_dir(path)
        return project_dir ? read_sessions_from_dir(project_dir, path) : []
      end

      # Several worktrees: the caller's own directory first, unconditionally.
      # `git worktree list` reports worktree ROOTS, so a subdirectory (a
      # monorepo package) is none of them, and reading only the listed paths
      # left out exactly the sessions that were asked for (Python:
      # "Always include the user's actual directory"). Then every worktree;
      # a project dir is read once.
      all_sessions = []
      seen = {}
      [path, *worktree_paths].each do |dir|
        project_dir = find_project_dir(dir)
        next if project_dir.nil? || seen[project_dir]

        seen[project_dir] = true
        all_sessions.concat(read_sessions_from_dir(project_dir, dir))
      end

      deduplicate_sessions(all_sessions)
    end

    def list_all_sessions
      projects_dir = File.join(config_dir, 'projects')
      return [] unless File.directory?(projects_dir)

      all_sessions = []
      # Sorted: the scan order is deduplicate_sessions' last tiebreak, and
      # Dir.children returns filesystem order.
      Dir.children(projects_dir).sort.each do |child|
        dir = File.join(projects_dir, child)
        next unless File.directory?(dir)

        all_sessions.concat(read_sessions_from_dir(dir))
      end

      deduplicate_sessions(all_sessions)
    end

    # One entry per session_id when the same session sits in several project
    # dirs (copied config dirs, worktrees). The newest last_modified wins; on
    # equal mtimes the larger file (the more complete copy), and then the
    # copy scanned first — project dirs in name order for the global listing;
    # for a directory listing the directory itself, then its worktrees in
    # `git worktree list` order (main worktree first). Python keeps the first
    # copy seen in iterdir() order (sessions.py _deduplicate_by_session_id),
    # which is arbitrary on a tie.
    def deduplicate_sessions(sessions)
      by_id = {}
      sessions.each do |s|
        existing = by_id[s.session_id]
        by_id[s.session_id] = s if existing.nil? || (dedup_rank(s) <=> dedup_rank(existing)).positive?
      end
      by_id.values
    end

    def dedup_rank(session)
      [session.last_modified, session.file_size.to_i]
    end

    # Probe git for the worktree list with a hard 5-second cap. A stale
    # git lock or hung network mount must not block the listing path
    # forever. Stdlib `Timeout.timeout` raises across threads via
    # `Thread#raise`, which corrupts the Async fiber-scheduler state when
    # the caller is inside a reactor, so we drain stdout/stderr on side
    # threads (so a full pipe buffer can't deadlock git) and SIGKILL the
    # child if the deadline passes. Matches Python's
    # `subprocess.run(..., timeout=5)`.
    def detect_worktrees(path) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- bounded git subprocess: drained pipes, deadline kill
      stdin, stdout, stderr, wait_thr = Open3.popen3('git', '-C', path, 'worktree', 'list', '--porcelain')
      stdin.close
      stdout.binmode # bytes: no transcoding to Encoding.default_internal; tagged in worktree_paths

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

      paths = worktree_paths(stdout_buf)
      paths.empty? ? [path] : paths
    rescue StandardError
      [path]
    ensure
      stdout_reader&.kill if stdout_reader&.alive?
      stderr_reader&.kill if stderr_reader&.alive?
      [stdout, stderr].each { |io| io&.close rescue nil } # rubocop:disable Style/RescueModifier
    end

    # The paths in the output of `git worktree list --porcelain`.
    #
    # The output was read as bytes and is UTF-8 here, whatever the locale:
    # under LANG=C the pipe yielded US-ASCII Strings, the first non-ASCII
    # worktree path made String#strip raise, and detect_worktrees' rescue
    # then dropped EVERY worktree. Each path is NFC-normalized, like every
    # path the SDK derives a project dir name from (canonicalize_path; Python
    # normalizes here too): git prints a path as the filesystem stores it, and
    # a decomposed name sanitizes to a different project dir than the one the
    # CLI created.
    def worktree_paths(porcelain)
      porcelain.force_encoding(Encoding::UTF_8).lines.filter_map do |line|
        line.strip.delete_prefix('worktree ').unicode_normalize(:nfc) if line.start_with?('worktree ')
      end
    end

    def find_session_file(session_id, directory)
      projects_dir = File.join(config_dir, 'projects')
      return nil unless File.directory?(projects_dir)

      file_name = "#{session_id}.jsonl"

      if directory
        path = canonicalize_path(directory)
        found = stat_candidate(find_project_dir(path), file_name, path)
        return found if found

        detect_worktrees(path).each do |wt_path|
          next if wt_path == path # already tried above

          found = stat_candidate(find_project_dir(wt_path), file_name, wt_path)
          return found if found
        end

        # An explicit directory strictly scopes the search — never fall
        # through to the global scan, which could resolve an unrelated
        # project's same-id session (mirrors Python's _resolve_session_file_path).
        return nil
      end

      # No directory provided — search all project directories.
      Dir.children(projects_dir).each do |child|
        dir = File.join(projects_dir, child)
        next unless File.directory?(dir)

        found = stat_candidate(dir, file_name)
        return found if found
      end

      nil
    end

    # Mirrors Python's _stat_candidate: a candidate counts only when it
    # exists AND is non-empty — a 0-byte stub in one project dir must not
    # stop the search when the real transcript lives under another
    # worktree's project dir (same hazard SessionMutations.try_append guards).
    # With +path+ (a directory-scoped lookup), the candidate must also be one
    # of that path's own transcripts (own_transcript?).
    def stat_candidate(project_dir, file_name, path = nil)
      return nil if project_dir.nil?

      candidate = File.join(project_dir, file_name)
      return nil unless File.size(candidate).positive?
      return nil if path && !own_transcript?(project_dir, candidate, path)

      candidate
    rescue SystemCallError
      nil
    end

    # Resolve the on-disk subagents directory for a session:
    # <projectDir>/<sessionId>/subagents (mirrors Python's
    # _resolve_subagents_dir). nil when the session transcript can't be found.
    def resolve_subagents_dir(session_id, directory)
      resolved = find_session_file(session_id, directory)
      return nil if resolved.nil?

      File.join(resolved.delete_suffix('.jsonl'), 'subagents')
    end

    # Depth-first sorted walk collecting [agent_id, path] pairs for
    # agent-<id>.jsonl files, recursing into subdirectories (e.g.
    # workflows/<runId>/) in the same sorted interleave. Mirrors Python's
    # _collect_agent_files: no dedupe; [] for a missing/unreadable base dir.
    def collect_agent_files(base_dir, results = [])
      begin
        children = Dir.children(base_dir).sort
      rescue SystemCallError
        return results
      end

      children.each do |name|
        path = File.join(base_dir, name)
        if File.directory?(path)
          collect_agent_files(path, results)
        elsif File.file?(path) && name.start_with?('agent-') && name.end_with?('.jsonl')
          results << [name.delete_prefix('agent-').delete_suffix('.jsonl'), path]
        end
      end
      results
    end

    def parse_jsonl_entries(file_path)
      entries = []

      File.foreach(file_path, mode: 'rb') do |line|
        entry = JSON.parse(utf8_transcript_text(line).strip, symbolize_names: false)
        next unless entry.is_a?(Hash)
        next unless TRANSCRIPT_ENTRY_TYPES.include?(entry['type'])
        next unless entry['uuid'].is_a?(String)

        entries << entry
      rescue JSON::ParserError
        next
      end
      entries
    end

    # Transcript text (one line, or a run of lines) read in binary mode, as
    # UTF-8. Transcripts are UTF-8 whatever the process locale says: a line
    # tagged with the locale's encoding (File.foreach's default) raised from
    # String#strip on the first non-ASCII character under LANG=C. Bytes that
    # are not valid UTF-8 — a final line the CLI was killed in the middle of,
    # raw binary in a tool result — become U+FFFD, the policy
    # SessionMutations.parse_fork_transcript already has: a torn line then
    # fails JSON.parse and is skipped like any other bad line instead of
    # raising, and a complete line keeps its entry.
    def utf8_transcript_text(text)
      text.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub
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

      best_leaf = pick_leaf(leaf_candidates, by_uuid, by_position)
      return [] unless best_leaf

      reattach_parallel_tool_results(walk_to_root(by_uuid, best_leaf), entries, skip_flagged: true)
    end

    # The leaf a conversation is read back from: the main-chain candidate
    # (not sidechain, team or meta) with the highest file position.
    #
    # Without one, fall back to the other candidates instead of reading the
    # conversation as empty, as Python does (`_pick_best(main_leaves) if
    # main_leaves else _pick_best(leaves)`): a session can end on a meta
    # entry nobody answered (a slash-command or skill body, a stop-hook
    # message, a system reminder — the user closed the session first), and
    # filter_visible_messages drops the flagged entries of the chain anyway.
    # Among those candidates one whose path to the root passes a visible
    # message comes first, then file position: the latest of them may be a
    # sidechain or teammate leaf with nothing visible above it, and taking
    # it would still read the conversation as empty.
    def pick_leaf(candidates, by_uuid, by_position)
      latest = ->(leaves) { leaves.max_by { |e| by_position[e['uuid']] || 0 } }
      main_leaves = candidates.reject { |e| off_main_conversation?(e) }
      return latest.call(main_leaves) unless main_leaves.empty?

      known = {}
      with_visible = candidates.select { |e| visible_ancestor?(by_uuid, e, known) }
      latest.call(with_visible.empty? ? candidates : with_visible)
    end

    # Whether the path from +leaf+ to its root passes an entry
    # filter_visible_messages returns. +known+ carries the answer for every
    # uuid already walked, so all the candidates of one transcript cost one
    # pass over it.
    def visible_ancestor?(by_uuid, leaf, known)
      walked = []
      current = leaf
      found = false
      while current && !known.key?(current['uuid'])
        known[current['uuid']] = false # a parentUuid cycle ends here
        walked << current['uuid']
        break if (found = visible_message?(current))

        current = by_uuid[current['parentUuid']]
      end
      found ||= current ? known[current['uuid']] : false
      walked.each { |uuid| known[uuid] = found }
      found
    end

    # An entry that is not part of the user's own conversation: written by a
    # subagent (sidechain) or a teammate, or a meta injection.
    def off_main_conversation?(entry)
      entry['isSidechain'] || entry['teamName'] || entry['isMeta']
    end

    # A user/assistant entry of the user's own conversation.
    def visible_message?(entry)
      %w[user assistant].include?(entry['type']) && !off_main_conversation?(entry)
    end

    # Put the results of parallel tool calls back on a leaf-to-root chain.
    #
    # The CLI writes one assistant entry per tool_use block (chained through
    # parentUuid) and parents every tool_result on the entry that holds ITS
    # tool_use. With two or more calls in one API message, only the result
    # the conversation continued from is an ancestor of the leaf; the others
    # are siblings of the next tool_use entry, and a single-path walk returns
    # their tool_use without them.
    #
    # For each assistant entry on the chain, take its user children that are
    # not on the chain and carry a tool_result for a tool_use on the chain,
    # and insert them — in file order — before the next user entry of the
    # chain (the batch's own on-chain result), or at the end when the chain
    # has none. The anchor, not the raw file position, decides the place: a
    # result that arrived after the conversation had already moved on to a
    # further tool_use of the same message still lands with its batch, so
    # every result follows the assistant turn that asked for it.
    #
    # The tool_use_id match is what keeps other user siblings out: a prompt
    # abandoned by a rewind is a second child of a chain entry too, and
    # starts a branch that was dropped — and so is the old result of a call
    # the conversation was rewound to and answered again: the chain's own
    # result for a tool_use_id wins, and at most one off-chain result per id
    # is ever added (the first in file order). +skip_flagged+ additionally
    # rejects sidechain / meta / team entries (main transcripts; a subagent
    # transcript is sidechain throughout).
    def reattach_parallel_tool_results(chain, entries, skip_flagged:)
      off_chain = off_chain_tool_results(chain, entries, skip_flagged)
      return chain if off_chain.empty?

      placed = []
      pending = []
      chain.each do |entry|
        if entry['type'] == 'user' && !pending.empty?
          placed.concat(pending.sort_by(&:first).map(&:last))
          pending = []
        end
        placed << entry
        pending.concat(off_chain.fetch(entry['uuid'], []))
      end
      placed.concat(pending.sort_by(&:first).map(&:last))
    end

    # { uuid of an assistant entry on the chain => [[file position, entry], ...] }
    # for the off-chain user children reattach_parallel_tool_results places.
    def off_chain_tool_results(chain, entries, skip_flagged) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- one filter per condition of the re-attachment rule
      on_chain = Set.new
      assistants = Set.new
      tool_use_ids = Set.new
      answered = Set.new # tool_use ids the chain's own results answer
      chain.each do |entry|
        on_chain << entry['uuid']
        case entry['type']
        when 'assistant'
          assistants << entry['uuid']
          tool_use_ids.merge(content_block_values(entry, 'tool_use', 'id'))
        when 'user' then answered.merge(content_block_values(entry, 'tool_result', 'tool_use_id'))
        end
      end
      return {} if (tool_use_ids - answered).empty?

      found = {}
      entries.each_with_index do |entry, position|
        next unless entry['type'] == 'user' && assistants.include?(entry['parentUuid'])
        next if on_chain.include?(entry['uuid'])
        next if skip_flagged && off_main_conversation?(entry)

        ids = content_block_values(entry, 'tool_result', 'tool_use_id')
        next if ids.empty? || !ids.all? { |id| tool_use_ids.include?(id) && !answered.include?(id) }

        # Claimed: a later result for the same call is not added — nor a
        # second copy of this entry, which a store can hold (a retried mirror
        # batch overlaps the write it retries).
        answered.merge(ids)
        (found[entry['parentUuid']] ||= []) << [position, entry]
      end
      found
    end

    # Values of +key+ over the +type+ content blocks of an entry's message
    # ([] for a message without array content — entries are opaque blobs).
    def content_block_values(entry, type, key)
      message = entry['message']
      content = message.is_a?(Hash) ? message['content'] : nil
      return [] unless content.is_a?(Array)

      content.filter_map { |block| block[key] if block.is_a?(Hash) && block['type'] == type }
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
        next unless visible_message?(entry)

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

    private_class_method :project_dir_records_cwd?, :recorded_cwd, :each_parsed_entry, :get_session_info_for_directory,
                         :list_sessions_for_directory, :list_all_sessions,
                         :deduplicate_sessions, :dedup_rank,
                         :worktree_paths, :find_session_file, :stat_candidate, :resolve_subagents_dir,
                         :collect_agent_files, :parse_jsonl_entries, :utf8_transcript_text,
                         :build_conversation_chain, :walk_to_leaf, :walk_to_root,
                         :pick_leaf, :visible_ancestor?, :off_main_conversation?, :visible_message?,
                         :reattach_parallel_tool_results, :off_chain_tool_results,
                         :content_block_values,
                         :filter_visible_messages, :build_session_info, :created_at_from_file, :user_entry_texts,
                         :each_line_past_head,
                         :first_prompt_in, :first_prompt_from_file, :first_prompt_past_head,
                         :valid_agent_id?, :sidechain_head?,
                         :list_sessions_via_summaries, :paginate_resolving_gaps, :resolve_gap_slot,
                         :derive_info_from_entries, :store_session_mtime, :mtime_from_entries,
                         :apply_sort_limit_offset,
                         :filter_transcript_entries, :entries_to_messages,
                         :entries_to_subagent_messages, :build_subagent_chain, :resolve_subagent_subpath,
                         :import_subagent_files, :append_jsonl_file_in_batches, :collect_jsonl_files,
                         :read_agent_metadata_sidecar, :parent_ids_from_agent_metadata

    # These remain accessible for SessionMutations / SessionResume:
    # config_dir, sanitize_path, find_project_dir, detect_worktrees,
    # valid_session_id? (mutation boundary checks), listing_sort_key
    # (--continue candidate order), read_head_tail, title_and_first_prompt
    # and display_title (the fork title), own_transcript? (the mutations'
    # lookups)
  end
end
