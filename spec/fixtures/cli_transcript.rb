# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

# Hand-built Claude Code transcripts for the session specs.
#
# The shape is the one CLI 2.1.285-2.1.287 writes: key names, key order and
# nesting were read off real transcripts, every value here is invented.
# What the fixtures must not lose (each has hidden a bug behind a
# hand-simplified fixture before):
#
# * An assistant API message is written as ONE ENTRY PER CONTENT BLOCK. The
#   entries are chained through parentUuid and share message.id.
# * A tool_result is a user entry whose parentUuid (and
#   sourceToolAssistantUUID) names the assistant entry that holds ITS
#   tool_use. With parallel tool calls the results are therefore siblings of
#   the next tool_use entry, not links of one chain.
# * Hook attachments hang off the tool_use entry (PreToolUse) and off the
#   tool_result entry (PostToolUse); the next API message is parented on the
#   last entry written under the result it follows.
# * Metadata lines (queue-operation, permission-mode, ai-title, custom-title,
#   last-prompt, tag, file-history-snapshot, ...) have no uuid.
# * Every entry of a subagent transcript carries isSidechain: true and agentId.
#
# Entries carry a subset of the real keys, never a different structure.
#
# Labels stand in for uuids: #id maps a label to a stable UUID (the CLI's
# uuid / parentUuid values are UUIDs) and #labels maps SessionMessages back,
# so an expectation reads %w[prompt use_a use_b result_a result_b].
class CLITranscript
  CLI_VERSION = '2.1.286'
  MODEL = 'claude-haiku-4-5-20251001'

  attr_reader :session_id, :cwd, :entries

  # The branch stamped on the entries built from here on.
  attr_writer :git_branch

  # @param agent_id [String, nil] build a SUBAGENT transcript (agent-<id>.jsonl)
  def initialize(session_id:, cwd: '/work/app', agent_id: nil, git_branch: 'main',
                 start: Time.utc(2026, 9, 8, 5, 19, 30))
    @session_id = session_id
    @cwd = cwd
    @agent_id = agent_id
    @git_branch = git_branch
    @clock = start
    @entries = []
    @labels = {}
  end

  # Stable UUID for a label (nil stays nil: a root entry's parentUuid).
  def id(label)
    return nil if label.nil?

    hex = Digest::MD5.hexdigest("#{@session_id}/#{@agent_id}/#{label}")
    uuid = "#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-8#{hex[17, 3]}-#{hex[20, 12]}"
    @labels[uuid] = label.to_s
    uuid
  end

  # Labels of the given SessionMessages, in order.
  def labels(messages)
    messages.map { |message| @labels.fetch(message.uuid, message.uuid) }
  end

  # -- conversation entries (each is appended to the file and returned) ------

  # A prompt the user typed: message.content is a String.
  def prompt(label, text, parent: nil, **extra)
    add(label, parent,
        { 'promptId' => id("prompt-id-#{label}"), 'type' => 'user',
          'message' => { 'role' => 'user', 'content' => text } },
        { 'permissionMode' => 'default' }.merge(extra.transform_keys(&:to_s)))
  end

  # A meta injection: a user entry the CLI writes itself (the body of a slash
  # command or skill, a stop-hook message, a system reminder). +content+ is a
  # String or an Array of content blocks.
  def meta(label, content, parent:, **extra)
    add(label, parent,
        { 'promptId' => id('prompt-id-turn'), 'type' => 'user',
          'message' => { 'role' => 'user', 'content' => content }, 'isMeta' => true },
        extra.transform_keys(&:to_s))
  end

  # A system entry, e.g. the stop-hook summary that closes a turn.
  def system(label, parent:, subtype: 'stop_hook_summary', **extra)
    add(label, parent,
        { 'type' => 'system', 'subtype' => subtype, 'hookCount' => 1,
          'hookInfos' => [{ 'command' => 'true', 'durationMs' => 3 }], 'hookErrors' => [],
          'preventedContinuation' => false, 'stopReason' => '', 'hasOutput' => false, 'level' => 'suggestion' },
        extra.transform_keys(&:to_s))
  end

  # One content block of an assistant API message (see the header).
  def assistant(label, block, parent:, message: 'msg_01', **extra)
    add(label, parent,
        { 'message' => {
            'model' => MODEL, 'id' => message, 'type' => 'message', 'role' => 'assistant',
            'content' => [block],
            'stop_reason' => block['type'] == 'tool_use' ? 'tool_use' : 'end_turn', 'stop_sequence' => nil,
            'usage' => { 'input_tokens' => 3, 'cache_creation_input_tokens' => 0,
                         'cache_read_input_tokens' => 0, 'output_tokens' => 12 }
          },
          'requestId' => "req_#{message}", 'type' => 'assistant' },
        extra.transform_keys(&:to_s))
  end

  # The result of one tool call: a user entry parented on the assistant entry
  # that holds the tool_use.
  def tool_result(label, tool_use_id, content, parent:, **extra)
    add(label, parent,
        { 'promptId' => id('prompt-id-turn'), 'type' => 'user',
          'message' => { 'role' => 'user',
                         'content' => [{ 'tool_use_id' => tool_use_id, 'type' => 'tool_result',
                                         'content' => content }] } },
        { 'toolUseResult' => { 'type' => 'text', 'file' => { 'filePath' => '/work/app/a.rb', 'numLines' => 1 } },
          'sourceToolAssistantUUID' => id(parent) }.merge(extra.transform_keys(&:to_s)))
  end

  # A hook attachment (PreToolUse under a tool_use entry, PostToolUse under a
  # tool_result entry), or any other attachment type.
  def attachment(label, parent:, hook: 'PostToolUse', type: 'hook_success', **extra)
    body = if type == 'hook_success'
             { 'type' => type, 'hookName' => "#{hook}:Read", 'toolUseID' => id("hook-#{label}"),
               'hookEvent' => hook, 'content' => '', 'stdout' => '', 'stderr' => '', 'exitCode' => 0,
               'command' => 'true', 'durationMs' => 3 }
           else
             { 'type' => type }
           end
    add(label, parent, { 'attachment' => body.merge(extra.transform_keys(&:to_s)), 'type' => 'attachment' })
  end

  # -- content blocks --------------------------------------------------------

  def text(text) = { 'type' => 'text', 'text' => text }

  def thinking(text = 'Let me look.') = { 'type' => 'thinking', 'thinking' => text, 'signature' => 'sig' }

  def tool_use(tool_use_id, name = 'Read', input = { 'file_path' => '/work/app/a.rb' })
    { 'type' => 'tool_use', 'id' => tool_use_id, 'name' => name, 'input' => input }
  end

  # -- metadata lines (no uuid) ----------------------------------------------

  # The two lines an SDK-driven session starts with.
  def queue_operations(text)
    raw({ 'type' => 'queue-operation', 'operation' => 'enqueue', 'timestamp' => tick,
          'sessionId' => @session_id, 'content' => text })
    raw({ 'type' => 'queue-operation', 'operation' => 'dequeue', 'timestamp' => tick, 'sessionId' => @session_id })
  end

  # The first line of an interactive session.
  def mode(mode = 'default')
    raw({ 'type' => 'mode', 'mode' => mode, 'sessionId' => @session_id })
  end

  def permission_mode(mode = 'default')
    raw({ 'type' => 'permission-mode', 'permissionMode' => mode, 'sessionId' => @session_id })
  end

  # Its timestamp is NESTED: the entry itself has no top-level timestamp.
  def file_history_snapshot(timestamp:)
    message_id = id("snapshot-#{@entries.length}")
    raw({ 'type' => 'file-history-snapshot', 'messageId' => message_id,
          'snapshot' => { 'messageId' => message_id, 'trackedFileBackups' => {}, 'timestamp' => timestamp },
          'isSnapshotUpdate' => false })
  end

  def custom_title(title)
    raw({ 'type' => 'custom-title', 'customTitle' => title, 'sessionId' => @session_id })
  end

  def ai_title(title)
    raw({ 'type' => 'ai-title', 'aiTitle' => title, 'sessionId' => @session_id })
  end

  def last_prompt(text, leaf: nil)
    raw({ 'type' => 'last-prompt', 'lastPrompt' => text, 'leafUuid' => id(leaf), 'sessionId' => @session_id })
  end

  def tag(tag)
    raw({ 'type' => 'tag', 'tag' => tag, 'sessionId' => @session_id })
  end

  # Append any other line verbatim (a Hash is one entry; a String one raw line).
  def raw(entry)
    @entries << entry
    entry
  end

  # -- output ----------------------------------------------------------------

  # The file as the CLI leaves it: one compact JSON object per line, each
  # line newline-terminated.
  def to_jsonl
    @entries.map { |entry| entry.is_a?(String) ? "#{entry}\n" : "#{JSON.generate(entry)}\n" }.join
  end

  def write(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, to_jsonl)
    path
  end

  # The parsed objects, as a SessionStore receives them from the mirror.
  def store_entries
    @entries.grep(Hash).map { |entry| JSON.parse(JSON.generate(entry)) }
  end

  private

  def add(label, parent, head, tail = {})
    entry = { 'parentUuid' => id(parent), 'isSidechain' => !@agent_id.nil? }
    if @agent_id
      # Real subagent entries: promptId (user entries) comes before agentId.
      prompt_id = head.key?('promptId') ? { 'promptId' => head['promptId'] } : {}
      entry.merge!(prompt_id, 'agentId' => @agent_id)
    end
    entry.merge!(head)
    entry['uuid'] = id(label)
    entry['timestamp'] = tick
    entry.merge!(tail)
    entry.merge!('userType' => 'external', 'entrypoint' => 'cli', 'cwd' => @cwd,
                 'sessionId' => @session_id, 'version' => CLI_VERSION, 'gitBranch' => @git_branch)
    @entries << entry
    entry
  end

  # Millisecond-precision ISO timestamps, one per entry, as the CLI writes them.
  def tick
    @clock += 0.25
    @clock.strftime('%Y-%m-%dT%H:%M:%S.%3NZ')
  end
end
