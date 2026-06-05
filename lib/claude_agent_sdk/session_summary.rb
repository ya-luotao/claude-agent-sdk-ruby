# frozen_string_literal: true

require 'time'
require_relative 'sessions'

module ClaudeAgentSDK
  # Incremental session-summary derivation for SessionStore adapters.
  #
  # fold_session_summary lets a store maintain a per-session summary sidecar
  # incrementally inside #append so list_sessions_from_store can fetch all
  # metadata in a single #list_session_summaries call instead of N per-session
  # #load calls. Every derived field is append-incremental (set-once or
  # last-wins) so adapters never need to re-read previously appended entries.
  #
  # All structures use STRING keys throughout: entries are raw JSONL objects
  # (string keys from JSON), and the summary's opaque +data+ dict is persisted
  # verbatim by adapters — string keys survive a JSON round-trip (Postgres
  # JSONB, Redis) losslessly, whereas symbol keys would not.
  module SessionSummary
    # JSONL entry keys -> summary data keys for last-wins string fields. Each
    # appended entry overwrites the previous value when present.
    LAST_WINS_FIELDS = {
      'customTitle' => 'custom_title',
      'aiTitle' => 'ai_title',
      'lastPrompt' => 'last_prompt',
      'summary' => 'summary_hint',
      'gitBranch' => 'git_branch'
    }.freeze

    module_function

    # Fold a batch of appended entries into the running summary for +key+.
    #
    # Stores call this from inside #append to keep a summary sidecar up to date
    # without re-reading the transcript. +prev+ is the previous summary for the
    # same key (or nil for the first append).
    #
    # Do NOT call this for keys with a +subpath+ — subagent transcripts must
    # not contribute to the main session's summary. Guard with
    # `if key['subpath'].nil?` before calling.
    #
    # +mtime+ is NOT touched by the fold — it is the sidecar's storage write
    # time and must be stamped by the adapter after persisting (sharing a clock
    # with the mtime returned by SessionStore#list_sessions). For a new session
    # (prev nil) the fold returns mtime 0 as a placeholder for the adapter to
    # overwrite.
    #
    # @param prev [Hash, nil] previous summary entry for this key
    # @param key [Hash] the SessionKey (string keys)
    # @param entries [Array<Hash>] newly appended transcript entries
    # @return [Hash] the updated summary entry ({ 'session_id', 'mtime', 'data' })
    def fold_session_summary(prev, key, entries)
      summary = if prev
                  { 'session_id' => prev['session_id'], 'mtime' => prev['mtime'], 'data' => prev['data'].dup }
                else
                  { 'session_id' => key['session_id'], 'mtime' => 0, 'data' => {} }
                end
      data = summary['data']

      entries.each do |entry|
        next unless entry.is_a?(Hash)

        ms = Sessions.parse_iso_timestamp_ms(entry['timestamp'])

        data['is_sidechain'] = (entry['isSidechain'] == true) unless data.key?('is_sidechain')
        data['created_at'] = ms if !data.key?('created_at') && ms

        unless data.key?('cwd')
          cwd = entry['cwd']
          data['cwd'] = cwd if cwd.is_a?(String) && !cwd.empty?
        end

        fold_first_prompt(data, entry)

        LAST_WINS_FIELDS.each do |src, dst|
          val = entry[src]
          data[dst] = val if val.is_a?(String)
        end

        next unless entry['type'] == 'tag'

        tag_val = entry['tag']
        if tag_val.is_a?(String) && !tag_val.empty?
          data['tag'] = tag_val
        else
          # Empty string or absent tag clears the tag.
          data.delete('tag')
        end
      end

      summary
    end

    # Convert a summary entry to SDKSessionInfo. Returns nil for sidechain
    # sessions or sessions with no extractable summary, matching the disk
    # lite-parse's filtering in Sessions#build_session_info.
    #
    # @param entry [Hash] a summary entry from SessionStore#list_session_summaries
    # @param project_path [String, nil] fallback cwd
    # @return [SDKSessionInfo, nil]
    def summary_entry_to_sdk_info(entry, project_path)
      data = entry['data'] || {}
      return nil if data['is_sidechain']

      first_prompt = presence(data['first_prompt_locked'] ? data['first_prompt'] : data['command_fallback'])
      custom_title = presence(data['custom_title']) || presence(data['ai_title'])
      summary = custom_title || presence(data['last_prompt']) || presence(data['summary_hint']) || first_prompt
      return nil unless summary

      SDKSessionInfo.new(
        session_id: entry['session_id'],
        summary: summary,
        last_modified: entry['mtime'],
        # file_size is a JSONL byte count — meaningful only for the local-disk
        # path. Stores have no equivalent.
        file_size: nil,
        custom_title: custom_title,
        first_prompt: first_prompt,
        git_branch: presence(data['git_branch']),
        cwd: presence(data['cwd']) || presence(project_path),
        tag: presence(data['tag']),
        created_at: data['created_at']
      )
    end

    # Python's `x or None`: nil for nil/empty-string, else the value.
    def presence(val)
      return nil if val.nil?
      return nil if val.is_a?(String) && val.empty?

      val
    end

    # Replicate Sessions#extract_first_prompt_from_head for a single parsed
    # entry. Mutates +data+ in place: sets first_prompt + first_prompt_locked on
    # a real match, or stashes a command_fallback for slash-command messages.
    #
    # The newline normalization (gsub(/\n+/, ' ')) and no-rstrip truncation
    # deliberately match the disk extractor (not Python's per-char replace) so
    # the Ruby store path and disk path produce identical first_prompt values
    # for the same transcript.
    def fold_first_prompt(data, entry)
      return if data['first_prompt_locked']
      return unless entry['type'] == 'user'
      return if entry['isMeta'] == true || entry['isCompactSummary'] == true

      message = entry['message']
      if message.is_a?(Hash)
        content = message['content']
        return if content.is_a?(Array) && content.any? { |b| b.is_a?(Hash) && b['type'] == 'tool_result' }
      end

      entry_text_blocks(entry).each do |raw|
        text = raw.gsub(/\n+/, ' ').strip
        next if text.empty?

        if (match = Sessions::COMMAND_NAME_RE.match(text))
          data['command_fallback'] ||= match[1]
          next
        end
        next if text.match?(Sessions::SKIP_FIRST_PROMPT_PATTERN)

        data['first_prompt'] = text.length > 200 ? "#{text[0, 200]}…" : text
        data['first_prompt_locked'] = true
        break
      end
    end

    # Extract text strings from a type=="user" entry's message content.
    def entry_text_blocks(entry)
      message = entry['message']
      return [] unless message.is_a?(Hash)

      content = message['content']
      case content
      when String then [content]
      when Array
        content.filter_map { |b| b['text'] if b.is_a?(Hash) && b['type'] == 'text' && b['text'].is_a?(String) }
      else []
      end
    end

    private_class_method :presence, :fold_first_prompt, :entry_text_blocks
  end
end
