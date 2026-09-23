# frozen_string_literal: true

require_relative 'claude_agent_sdk/version'
require_relative 'claude_agent_sdk/errors'
require_relative 'claude_agent_sdk/configuration'
require_relative 'claude_agent_sdk/types'
require_relative 'claude_agent_sdk/observer'
require_relative 'claude_agent_sdk/transport'
require_relative 'claude_agent_sdk/cli_installer'
require_relative 'claude_agent_sdk/subprocess_cli_transport'
require_relative 'claude_agent_sdk/message_parser'
require_relative 'claude_agent_sdk/query'
require_relative 'claude_agent_sdk/sdk_mcp_server'
require_relative 'claude_agent_sdk/streaming'
require_relative 'claude_agent_sdk/sessions'
require_relative 'claude_agent_sdk/session_summary'
require_relative 'claude_agent_sdk/session_store'
require_relative 'claude_agent_sdk/transcript_mirror_batcher'
require_relative 'claude_agent_sdk/session_resume'
require_relative 'claude_agent_sdk/session_mutations'
require_relative 'claude_agent_sdk/fiber_boundary'
require_relative 'claude_agent_sdk/option_warnings'
require_relative 'claude_agent_sdk/deprecation'
# Rails apps only: Bundler.require runs after `require 'rails'`, so the
# Railtie (rake tasks; the generator lives under lib/generators) is picked up
# there and nowhere else.
require_relative 'claude_agent_sdk/railtie' if defined?(Rails::Railtie)
require 'async'
require 'securerandom'

# Claude Agent SDK for Ruby
module ClaudeAgentSDK
  # The duck-typed observer surface probed by resolve_observers — implementing
  # any one of these counts as an observer (see Observer's no-op defaults).
  #
  # @api private
  OBSERVER_INTERFACE = %i[on_user_prompt on_message on_error on_close].freeze

  # Resolve observers array: callables (Proc/lambda) are invoked to produce
  # a fresh instance per query/session (thread-safe); plain objects are used as-is.
  # Array() guards against nil (e.g., when observers: nil is passed explicitly).
  # Anything implementing none of the observer methods is warned about and
  # skipped — most commonly a Class passed instead of an instance, which
  # previously produced silent zero instrumentation (every notify raised
  # NoMethodError, swallowed by notify_observers' error containment).
  # @api private
  def self.resolve_observers(observers)
    Array(observers).filter_map do |obs|
      resolved = obs.respond_to?(:call) ? obs.call : obs
      if OBSERVER_INTERFACE.none? { |m| resolved.respond_to?(m) }
        label = resolved.is_a?(Module) ? resolved : resolved.class
        hint = resolved.is_a?(Module) ? " — pass an instance (#{resolved}.new) or a factory lambda" : ''
        warn "ClaudeAgentSDK: ignoring observer #{label}: it implements none of #{OBSERVER_INTERFACE.join('/')}#{hint}"
        next nil
      end
      resolved
    end
  end

  # Internal: pull live SDK MCP server instances out of an mcp_servers Hash.
  # Accepts both raw Hash configs and typed Mcp*ServerConfig objects — a
  # McpSdkServerConfig passed without .to_h previously failed the Hash-only
  # guard, so its in-process server was silently never registered. Hash
  # configs may use String or Symbol keys (and a Symbol :sdk type) — the
  # recognition rule must match CommandBuilder#append_mcp_servers, which
  # strips the instance from exactly these entries.
  # @api private
  def self.extract_sdk_mcp_servers(mcp_servers)
    return {} unless mcp_servers.is_a?(Hash)

    servers = {}
    mcp_servers.each do |name, config|
      config = config.to_h if config.is_a?(Type)
      next unless config.is_a?(Hash) && (config[:type] || config['type']).to_s == 'sdk'

      servers[name] = config.key?(:instance) ? config[:instance] : config['instance']
    end
    servers
  end

  # Internal: normalize hook lists for the control protocol. An absent or
  # disabled event must not become an empty registration in initialize.
  # @api private
  def self.convert_hooks_to_internal_format(hooks)
    return nil unless hooks

    internal_hooks = {}
    hooks.each do |event, matchers|
      next if matchers.nil? || matchers.empty?

      entries = []
      matchers.each do |matcher|
        config = { matcher: matcher.matcher, hooks: matcher.hooks }
        config[:timeout] = matcher.timeout if matcher.timeout
        entries << config
      end
      internal_hooks[event.to_s] = entries unless entries.empty?
    end
    internal_hooks.empty? ? nil : internal_hooks
  end

  # Internal: validate can_use_tool and route permission prompts over stdio.
  #
  # Shared by query() and Client#connect so both entry points enforce the
  # same rules. Returns options unchanged when no callback is set; otherwise
  # checks it is not combined with permission_prompt_tool_name, emits the
  # shadowing advisory, and returns a copy with permission_prompt_tool_name
  # set to 'stdio' so the CLI sends permission requests over the control
  # protocol.
  #
  # A String prompt is fine here: the SDK is always streaming internally (a
  # String is written to stdin as a user message like any other), so as long
  # as stdin stays open for the turn — which Query#bidirectional_needs? now
  # guarantees for can_use_tool — the permission round-trip works. The old
  # "requires streaming mode" ArgumentError was a needless restriction
  # (Python #1204).
  # @api private
  def self.configure_can_use_tool(options)
    return options unless options.can_use_tool

    # can_use_tool and permission_prompt_tool_name are mutually exclusive
    raise ArgumentError, 'can_use_tool callback cannot be used with permission_prompt_tool_name' if options.permission_prompt_tool_name

    # Advisory: warn if other options shadow the callback. After the
    # ArgumentError above so invalid configs raise, not warn.
    OptionWarnings.warn_if_can_use_tool_shadowed(options)

    options.dup_with(permission_prompt_tool_name: 'stdio')
  end

  # Internal: pull exclude_dynamic_sections out of a preset system prompt for
  # the initialize request (older CLIs ignore unknown initialize fields).
  # Shared by Client#connect and the one-shot query() path.
  # @api private
  def self.extract_exclude_dynamic_sections(system_prompt)
    if system_prompt.is_a?(SystemPromptPreset)
      eds = system_prompt.exclude_dynamic_sections
      return eds if [true, false].include?(eds)
    elsif system_prompt.is_a?(Hash)
      type = system_prompt[:type] || system_prompt['type']
      if type == 'preset'
        eds = system_prompt.fetch(:exclude_dynamic_sections) { system_prompt['exclude_dynamic_sections'] }
        return eds if [true, false].include?(eds)
      end
    end
    nil
  end

  # Internal: pull snapshot out of a preset or custom system prompt for the
  # initialize request (older CLIs ignore unknown initialize fields). A
  # String or file prompt has no snapshot, and only a genuine true/false is
  # forwarded — `snapshot: false` is the primary use case, so the Hash lookup
  # must not collapse it to nil. Shared by Client#connect and query().
  # @api private
  def self.extract_system_prompt_snapshot(system_prompt)
    case system_prompt
    when SystemPromptPreset, SystemPromptCustom
      snapshot = system_prompt.snapshot
      return snapshot if [true, false].include?(snapshot)
    when Hash
      type = system_prompt[:type] || system_prompt['type']
      if %w[preset custom].include?(type)
        snapshot = system_prompt.fetch(:snapshot) { system_prompt['snapshot'] }
        return snapshot if [true, false].include?(snapshot)
      end
    end
    nil
  end

  # Safely call a method on each observer, suppressing any errors.
  # Each observer is invoked through FiberBoundary so that user code runs
  # on a plain thread (no Fiber scheduler) even when called from inside
  # the SDK's Async reactor — or in place when scheduling is :inline.
  # @api private
  def self.notify_observers(observers, method, *args, scheduling: :thread, wrapper: nil)
    observers.each do |obs|
      FiberBoundary.invoke(scheduling: scheduling, wrapper: wrapper) { obs.send(method, *args) }
    rescue StandardError, ScriptError
      # ScriptError too: NotImplementedError < ScriptError (not
      # StandardError), and a stubbed observer must never mask the original
      # error being notified or abort connect/teardown cleanup.
      nil
    end
  end

  # Public escape hatch for hosts running with callback_scheduling: :inline:
  # run a heavy piece of a callback on a plain thread instead of the shared
  # reactor fiber. What that buys, precisely:
  # - scheduler-opaque BLOCKING that releases the GVL (native DB drivers,
  #   file/socket calls the scheduler can't see): the reactor keeps running.
  # - pure-Ruby CPU-bound work: degrades a hard reactor stall into GVL
  #   time-slicing — added latency for other fibers, not starvation.
  # - a C extension that HOLDS the GVL for the whole computation: no help;
  #   nothing in-process can protect the reactor from that — move such work
  #   to a subprocess.
  # No-op outside a Fiber scheduler, so it is safe to call unconditionally.
  # Returns the block's value; exceptions propagate.
  #
  # @example Inside an inline-mode tool handler
  #   ClaudeAgentSDK.offload { blocking_db_call }
  def self.offload(&)
    FiberBoundary.invoke(&)
  end

  # Guards the once-per-process flag below: two sessions connecting
  # concurrently must not both pass the unset check and warn twice.
  INLINE_ISOLATION_WARN_LOCK = Mutex.new
  private_constant :INLINE_ISOLATION_WARN_LOCK

  # Internal: warn once per process when :inline callback scheduling is
  # enabled while ActiveSupport reports thread isolation — the host then
  # almost certainly violates inline mode's fiber-isolation precondition
  # (solid_queue fiber workers require isolation_level = :fiber).
  # defined? probing only; the SDK never loads ActiveSupport itself.
  # @api private
  def self.check_inline_isolation(scheduling)
    return unless scheduling == :inline
    return unless defined?(ActiveSupport::IsolatedExecutionState)
    return unless ActiveSupport::IsolatedExecutionState.isolation_level == :thread

    INLINE_ISOLATION_WARN_LOCK.synchronize do
      return if @inline_isolation_warned

      @inline_isolation_warned = true
    end
    warn 'ClaudeAgentSDK: callback_scheduling: :inline is enabled but ' \
         'ActiveSupport::IsolatedExecutionState.isolation_level is :thread. ' \
         'Inline callbacks run on reactor fibers that share one thread, so ' \
         'thread-keyed Rails state will leak across fibers. Set ' \
         'isolation_level = :fiber (as solid_queue fiber workers require) ' \
         'or use the default callback_scheduling: :thread.'
  end

  # Extract the user-visible prompt text from a streamed input item, or nil
  # when there is none (non-user messages, tool_result-only content, …).
  # Only Hash and JSON-string items are inspected; arbitrary objects written
  # via to_s are never notified.
  # @api private
  def self.extract_user_prompt_text(message)
    data = case message
           when Hash then message
           when String
             # Cheap prefilter: skip the full parse for items that cannot be
             # user messages (e.g. multi-MB tool_result frames) — parsing
             # would block the reactor fiber for the duration. False
             # positives just cost one parse; correctness is unchanged.
             return nil unless message.include?('user')

             begin
               JSON.parse(message)
             rescue JSON::ParserError
               nil
             end
           end
    return nil unless data.is_a?(Hash)
    return nil unless (data[:type] || data['type']) == 'user'

    inner = data[:message] || data['message']
    return nil unless inner.is_a?(Hash)

    prompt_text_from_content(inner[:content] || inner['content'])
  end

  # Text from a user-message content payload: the string itself, or the
  # newline-joined non-empty top-level text blocks. Returns nil (never '')
  # when there is no extractable text — on_user_prompt('') would latch
  # OTelObserver's first-prompt buffer while never setting the attribute,
  # permanently suppressing later real prompts.
  # @api private
  def self.prompt_text_from_content(content)
    case content
    when String
      content.empty? ? nil : content
    when Array
      texts = content.filter_map do |block|
        next unless block.is_a?(Hash)
        next unless (block[:type] || block['type']) == 'text'

        text = block[:text] || block['text']
        text unless text.to_s.empty?
      end
      texts.empty? ? nil : texts.join("\n")
    end
  end

  # Wrap a streaming-input enumerable so observers get on_user_prompt for
  # each user message before it is written to stdin. Identity when no
  # observers are configured.
  # @api private
  def self.observing_prompt_stream(prompt, observers, scheduling: :thread, wrapper: nil)
    return prompt if observers.empty?

    Enumerator.new do |yielder|
      prompt.each do |message|
        text = extract_user_prompt_text(message)
        notify_observers(observers, :on_user_prompt, text, scheduling: scheduling, wrapper: wrapper) if text
        yielder << message
      end
    end
  end

  # Look up a value in a hash that may use symbol or string keys in camelCase or snake_case.
  # Returns the first non-nil value found, preserving false as a meaningful value.
  # @api private
  def self.flexible_fetch(hash, camel_key, snake_key)
    val = hash[camel_key.to_sym]
    val = hash[camel_key.to_s] if val.nil?
    val = hash[snake_key.to_sym] if val.nil?
    val = hash[snake_key.to_s] if val.nil?
    val
  end

  # ---- Session browsing & mutation ----
  #
  # One function per operation. By default each reads or writes the local-disk
  # transcripts under CLAUDE_CONFIG_DIR; pass +session_store:+ to operate on a
  # SessionStore instead. The two paths differ in a few documented ways:
  #
  # - +directory: nil+ searches every project directory on disk, but means the
  #   current working directory with a store (a SessionStore is keyed by
  #   project_key and cannot enumerate projects — parity with the Python SDK).
  # - +include_worktrees:+ filters only on disk (list_sessions); with a
  #   +session_store:+, anything but the default +true+ raises ArgumentError.

  # List sessions for a directory (or all sessions), newest first.
  # @param directory [String, nil] Working directory to list sessions for. On
  #   disk, nil lists every project; with a session_store, nil means the
  #   current working directory.
  # @param limit [Integer, nil] Maximum number of sessions to return
  # @param offset [Integer] Number of sessions to skip (for pagination)
  # @param include_worktrees [Boolean] Disk only: also list the project's git
  #   worktree sessions. A store has no worktrees, so with a session_store only
  #   the default true is accepted; false or nil raises ArgumentError (the
  #   store path cannot apply the filter the caller asked for).
  # @param session_store [SessionStore, nil] List from this store instead of
  #   local disk. Uses the store's list_session_summaries when implemented,
  #   else list_sessions + one load per listed session.
  # @return [Array<SDKSessionInfo>] Sessions sorted by last_modified descending
  # @raise [ArgumentError] if include_worktrees is not true with a session_store,
  #   or the store implements neither list_session_summaries nor list_sessions
  def self.list_sessions(directory: nil, limit: nil, offset: 0, include_worktrees: true, session_store: nil)
    unless session_store.nil?
      unless include_worktrees == true
        raise ArgumentError, "include_worktrees: #{include_worktrees.inspect} applies only to local-disk " \
                             'listing; a session_store is keyed by project and has no worktrees to exclude'
      end

      return Sessions.list_sessions_from_store(session_store: session_store, directory: directory,
                                               limit: limit, offset: offset)
    end

    Sessions.list_sessions(directory: directory, limit: limit, offset: offset, include_worktrees: include_worktrees)
  end

  # Read metadata for a single session by ID (no full directory scan)
  # @param session_id [String] UUID of the session to look up
  # @param directory [String, nil] Project directory path. On disk, nil
  #   searches every project; with a session_store, nil means the current
  #   working directory.
  # @param session_store [SessionStore, nil] Read from this store instead of local disk
  # @return [SDKSessionInfo, nil] Session info, or nil if not found / sidechain / no summary
  def self.get_session_info(session_id:, directory: nil, session_store: nil)
    unless session_store.nil?
      return Sessions.get_session_info_from_store(session_store: session_store, session_id: session_id,
                                                  directory: directory)
    end

    Sessions.get_session_info(session_id: session_id, directory: directory)
  end

  # Get messages from a session transcript
  # @param session_id [String] The session UUID
  # @param directory [String, nil] Working directory to search in. On disk,
  #   nil searches every project; with a session_store, nil means the current
  #   working directory.
  # @param limit [Integer, nil] Maximum number of messages
  # @param offset [Integer] Number of messages to skip
  # @param session_store [SessionStore, nil] Read from this store instead of local disk
  # @return [Array<SessionMessage>] Ordered messages from the session
  def self.get_session_messages(session_id:, directory: nil, limit: nil, offset: 0, session_store: nil)
    unless session_store.nil?
      return Sessions.get_session_messages_from_store(session_store: session_store, session_id: session_id,
                                                      directory: directory, limit: limit, offset: offset)
    end

    Sessions.get_session_messages(session_id: session_id, directory: directory, limit: limit, offset: offset)
  end

  # List subagent IDs recorded for a session
  # @param session_id [String] The session UUID
  # @param directory [String, nil] Working directory to search in. On disk,
  #   nil searches every project; with a session_store, nil means the current
  #   working directory.
  # @param session_store [SessionStore, nil] Read from this store instead of
  #   local disk (the store must implement list_subkeys)
  # @return [Array<String>] Subagent IDs
  # @raise [ArgumentError] if the session_store does not implement list_subkeys
  def self.list_subagents(session_id:, directory: nil, session_store: nil)
    unless session_store.nil?
      return Sessions.list_subagents_from_store(session_store: session_store, session_id: session_id,
                                                directory: directory)
    end

    Sessions.list_subagents(session_id: session_id, directory: directory)
  end

  # Read a subagent's optional metadata (not live status). With a
  # session_store, the last agent_metadata entry wins and its synthetic type
  # marker is omitted.
  # @param session_id [String] The parent session UUID
  # @param agent_id [String] The subagent ID, without the agent- prefix
  # @param directory [String, nil] Project directory to search in. On disk,
  #   nil searches every project; with a session_store, nil means the current
  #   working directory.
  # @param session_store [SessionStore, nil] Read from this store instead of local disk
  # @return [Hash{String => Object}, nil] CLI metadata, or nil if unavailable
  def self.get_subagent_metadata(session_id:, agent_id:, directory: nil, session_store: nil)
    unless session_store.nil?
      return Sessions.get_subagent_metadata_from_store(session_store: session_store, session_id: session_id,
                                                       agent_id: agent_id, directory: directory)
    end

    Sessions.get_subagent_metadata(session_id: session_id, agent_id: agent_id, directory: directory)
  end

  # Read a subagent's conversation messages
  # @param session_id [String] The session UUID
  # @param agent_id [String] The subagent ID (without the agent- prefix)
  # @param directory [String, nil] Working directory to search in. On disk,
  #   nil searches every project; with a session_store, nil means the current
  #   working directory.
  # @param limit [Integer, nil] Maximum number of messages
  # @param offset [Integer] Number of messages to skip
  # @param session_store [SessionStore, nil] Read from this store instead of local disk
  # @return [Array<SessionMessage>] Ordered messages from the subagent
  def self.get_subagent_messages(session_id:, agent_id:, directory: nil, limit: nil, offset: 0, session_store: nil)
    unless session_store.nil?
      return Sessions.get_subagent_messages_from_store(session_store: session_store, session_id: session_id,
                                                       agent_id: agent_id, directory: directory,
                                                       limit: limit, offset: offset)
    end

    Sessions.get_subagent_messages(session_id: session_id, agent_id: agent_id,
                                   directory: directory, limit: limit, offset: offset)
  end

  # Rename a session by appending a custom-title entry. With a session_store
  # the entry is appended via SessionStore#append and carries a fresh uuid +
  # timestamp (so uuid-deduping adapters treat it correctly).
  # @param session_id [String] UUID of the session to rename
  # @param title [String] New session title
  # @param directory [String, nil] Project directory path (nil = cwd with a session_store)
  # @param session_store [SessionStore, nil] Rename in this store instead of on local disk
  # @raise [ArgumentError] if session_id is invalid or title is empty
  # @raise [Errno::ENOENT] if the session is not found (nothing is written)
  def self.rename_session(session_id:, title:, directory: nil, session_store: nil)
    unless session_store.nil?
      return SessionMutations.rename_session_via_store(session_store: session_store, session_id: session_id,
                                                       title: title, directory: directory)
    end

    SessionMutations.rename_session(session_id: session_id, title: title, directory: directory)
  end

  # Tag a session. Pass nil to clear the tag.
  # @param session_id [String] UUID of the session to tag
  # @param tag [String, nil] Tag string, or nil to clear
  # @param directory [String, nil] Project directory path (nil = cwd with a session_store)
  # @param session_store [SessionStore, nil] Tag in this store instead of on local disk
  # @raise [ArgumentError] if session_id is invalid or tag is empty after sanitization
  # @raise [Errno::ENOENT] if the session is not found (nothing is written)
  def self.tag_session(session_id:, tag:, directory: nil, session_store: nil)
    unless session_store.nil?
      return SessionMutations.tag_session_via_store(session_store: session_store, session_id: session_id,
                                                    tag: tag, directory: directory)
    end

    SessionMutations.tag_session(session_id: session_id, tag: tag, directory: directory)
  end

  # Delete a session (hard delete). On disk, removes its JSONL file and
  # subagent directory, raising Errno::ENOENT if the session is not found.
  # With a session_store, calls SessionStore#delete — a no-op when the store
  # does not implement #delete (WORM/append-only backends); whether subagent
  # subkeys are removed too depends on the store's cascade semantics.
  # @param session_id [String] UUID of the session to delete
  # @param directory [String, nil] Project directory path (nil = cwd with a session_store)
  # @param session_store [SessionStore, nil] Delete from this store instead of local disk
  # @raise [ArgumentError] if session_id is invalid
  # @raise [Errno::ENOENT] on disk, if the session file cannot be found
  def self.delete_session(session_id:, directory: nil, session_store: nil)
    unless session_store.nil?
      return SessionMutations.delete_session_via_store(session_store: session_store, session_id: session_id,
                                                       directory: directory)
    end

    SessionMutations.delete_session(session_id: session_id, directory: directory)
  end

  # Fork a session into a new branch with fresh UUIDs. With a session_store
  # the fork transform runs over the store's entries and the fork is appended
  # to the same store.
  # @param session_id [String] UUID of the session to fork
  # @param directory [String, nil] Project directory path (nil = cwd with a session_store)
  # @param up_to_message_id [String, nil] Truncate the fork at this message UUID
  # @param title [String, nil] Custom title for the fork
  # @param session_store [SessionStore, nil] Fork within this store instead of on local disk
  # @return [ForkSessionResult] Result containing the new session ID
  # @raise [ArgumentError] if session_id/up_to_message_id is invalid or there are no messages
  # @raise [Errno::ENOENT] if the source session is not found
  def self.fork_session(session_id:, directory: nil, up_to_message_id: nil, title: nil, session_store: nil)
    unless session_store.nil?
      return SessionMutations.fork_session_via_store(session_store: session_store, session_id: session_id,
                                                     directory: directory, up_to_message_id: up_to_message_id,
                                                     title: title)
    end

    SessionMutations.fork_session(session_id: session_id, directory: directory,
                                  up_to_message_id: up_to_message_id, title: title)
  end

  # Derive the SessionStore +project_key+ for a directory (default: cwd).
  # Matches the CLI's project-directory naming so keys align between local-disk
  # and store-mirrored transcripts.
  # @param directory [String, Pathname, nil] Directory to key (nil = cwd)
  # @return [String] The project key
  def self.project_key_for_directory(directory = nil)
    Sessions.project_key_for_directory(directory)
  end

  # Fold a batch of appended transcript entries into a running session summary.
  # SessionStore adapters call this inside #append to maintain a summary sidecar
  # incrementally (see SessionStore#list_session_summaries).
  # @param prev [Hash, nil] previous summary entry for this key
  # @param key [Hash] the SessionKey (string keys)
  # @param entries [Array<Hash>] newly appended transcript entries
  # @return [Hash] the updated summary entry
  def self.fold_session_summary(prev, key, entries)
    SessionSummary.fold_session_summary(prev, key, entries)
  end

  # ---- Deprecated store twins (removed in 1.0) ----
  #
  # Each forwards to the same implementation as before — not to the merged
  # function, so a nil session_store keeps failing as it always did instead
  # of silently reading local disk — after one warning per method per process.

  # @deprecated Use {.list_sessions} with +session_store:+. Removed in 1.0.
  # @return [Array<SDKSessionInfo>] sorted by last_modified descending
  def self.list_sessions_from_store(session_store:, directory: nil, limit: nil, offset: 0)
    Deprecation.warn_once(:list_sessions_from_store, 'list_sessions(session_store: store)')
    Sessions.list_sessions_from_store(session_store: session_store, directory: directory, limit: limit, offset: offset)
  end

  # @deprecated Use {.get_session_info} with +session_store:+. Removed in 1.0.
  # @return [SDKSessionInfo, nil]
  def self.get_session_info_from_store(session_store:, session_id:, directory: nil)
    Deprecation.warn_once(:get_session_info_from_store, 'get_session_info(session_store: store, ...)')
    Sessions.get_session_info_from_store(session_store: session_store, session_id: session_id, directory: directory)
  end

  # @deprecated Use {.get_session_messages} with +session_store:+. Removed in 1.0.
  # @return [Array<SessionMessage>]
  def self.get_session_messages_from_store(session_store:, session_id:, directory: nil, limit: nil, offset: 0)
    Deprecation.warn_once(:get_session_messages_from_store, 'get_session_messages(session_store: store, ...)')
    Sessions.get_session_messages_from_store(session_store: session_store, session_id: session_id,
                                             directory: directory, limit: limit, offset: offset)
  end

  # @deprecated Use {.list_subagents} with +session_store:+. Removed in 1.0.
  # @return [Array<String>]
  def self.list_subagents_from_store(session_store:, session_id:, directory: nil)
    Deprecation.warn_once(:list_subagents_from_store, 'list_subagents(session_store: store, ...)')
    Sessions.list_subagents_from_store(session_store: session_store, session_id: session_id, directory: directory)
  end

  # @deprecated Use {.get_subagent_metadata} with +session_store:+. Removed in 1.0.
  # @return [Hash{String => Object}, nil]
  def self.get_subagent_metadata_from_store(session_store:, session_id:, agent_id:, directory: nil)
    Deprecation.warn_once(:get_subagent_metadata_from_store, 'get_subagent_metadata(session_store: store, ...)')
    Sessions.get_subagent_metadata_from_store(session_store: session_store, session_id: session_id,
                                              agent_id: agent_id, directory: directory)
  end

  # @deprecated Use {.get_subagent_messages} with +session_store:+. Removed in 1.0.
  # @return [Array<SessionMessage>]
  def self.get_subagent_messages_from_store(session_store:, session_id:, agent_id:, directory: nil, limit: nil,
                                            offset: 0)
    Deprecation.warn_once(:get_subagent_messages_from_store, 'get_subagent_messages(session_store: store, ...)')
    Sessions.get_subagent_messages_from_store(session_store: session_store, session_id: session_id,
                                              agent_id: agent_id, directory: directory, limit: limit, offset: offset)
  end

  # @deprecated Use {.rename_session} with +session_store:+. Removed in 1.0.
  def self.rename_session_via_store(session_store:, session_id:, title:, directory: nil)
    Deprecation.warn_once(:rename_session_via_store, 'rename_session(session_store: store, ...)')
    SessionMutations.rename_session_via_store(session_store: session_store, session_id: session_id,
                                              title: title, directory: directory)
  end

  # @deprecated Use {.tag_session} with +session_store:+. Removed in 1.0.
  def self.tag_session_via_store(session_store:, session_id:, tag:, directory: nil)
    Deprecation.warn_once(:tag_session_via_store, 'tag_session(session_store: store, ...)')
    SessionMutations.tag_session_via_store(session_store: session_store, session_id: session_id,
                                           tag: tag, directory: directory)
  end

  # @deprecated Use {.delete_session} with +session_store:+. Removed in 1.0.
  def self.delete_session_via_store(session_store:, session_id:, directory: nil)
    Deprecation.warn_once(:delete_session_via_store, 'delete_session(session_store: store, ...)')
    SessionMutations.delete_session_via_store(session_store: session_store, session_id: session_id,
                                              directory: directory)
  end

  # @deprecated Use {.fork_session} with +session_store:+. Removed in 1.0.
  # @return [ForkSessionResult]
  def self.fork_session_via_store(session_store:, session_id:, directory: nil, up_to_message_id: nil, title: nil)
    Deprecation.warn_once(:fork_session_via_store, 'fork_session(session_store: store, ...)')
    SessionMutations.fork_session_via_store(session_store: session_store, session_id: session_id,
                                            directory: directory, up_to_message_id: up_to_message_id, title: title)
  end

  # Replay a local on-disk session transcript into a SessionStore (migration /
  # gap-backfill). Keys under the on-disk project dir so the imported session is
  # resumable via session_store + resume from the original cwd.
  # @param batch_size [Integer] entries per SessionStore#append call (default 500)
  # @raise [ArgumentError] if session_id is not a valid UUID
  # @raise [Errno::ENOENT] if the session JSONL cannot be found
  def self.import_session_to_store(session_id:, session_store:, directory: nil, include_subagents: true,
                                   batch_size: TranscriptMirrorBatcher::MAX_PENDING_ENTRIES)
    Sessions.import_session_to_store(session_id: session_id, session_store: session_store, directory: directory,
                                     include_subagents: include_subagents, batch_size: batch_size)
  end

  # Query Claude Code for one-shot or unidirectional streaming interactions
  #
  # This function is ideal for simple, stateless queries where you don't need
  # bidirectional communication or conversation management.
  #
  # @param prompt [String, Enumerator] The prompt to send to Claude, or an Enumerator for streaming input
  # @param options [ClaudeAgentOptions] Optional configuration
  # @yield [Message] Each message from the conversation
  # @return [Enumerator] if no block given. Internal iteration only: consume
  #   with #each or each-driven Enumerable methods (#first, #take, #map,
  #   #to_a). External iteration (#next, #peek, #rewind) is NOT supported —
  #   message delivery runs inside the SDK's Async reactor, which cannot run
  #   on the Enumerator's fiber; #next raises or hangs depending on context.
  # @note An attempted #next may still spawn the CLI subprocess before
  #   failing and leaves the query unusable.
  #
  # @example Simple query
  #   ClaudeAgentSDK.query(prompt: "What is 2 + 2?") do |message|
  #     puts message
  #   end
  #
  # @example With options
  #   options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  #     allowed_tools: ['Read', 'Bash'],
  #     permission_mode: 'acceptEdits'
  #   )
  #   ClaudeAgentSDK.query(prompt: "Create a hello.rb file", options: options) do |msg|
  #     puts msg.text if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
  #   end
  #
  # @example Streaming input
  #   messages = Streaming.from_array(['Hello', 'What is 2+2?', 'Thanks!'])
  #   ClaudeAgentSDK.query(prompt: messages) do |message|
  #     puts message
  #   end
  def self.query(prompt:, options: nil, transport: nil, &block)
    # Validate BEFORE the block-less enum_for return so a bad prompt fails at
    # the call site, not on first iteration. Mirrors Client#query: a bare Hash
    # responds to #each and would stream [key, value] pairs' to_s garbage to
    # the CLI; nil/Integer would hang forever waiting for input.
    raise ArgumentError, 'prompt must be a String or an Enumerable of message Hashes/JSONL Strings (got Hash)' if prompt.is_a?(Hash)
    raise ArgumentError, "prompt must be a String or respond to #each (got #{prompt.class})" unless prompt.is_a?(String) || prompt.respond_to?(:each)

    return enum_for(:query, prompt: prompt, options: options, transport: transport) unless block

    options ||= ClaudeAgentOptions.new

    configured_options = ClaudeAgentSDK.configure_can_use_tool(options)

    # Fail fast on invalid session_store combinations before spawning the CLI.
    SessionStores.validate_session_store_options(configured_options)

    # Resolve callable observers into fresh instances (thread-safe for global defaults)
    resolved_observers = ClaudeAgentSDK.resolve_observers(configured_options.observers)

    # Where user callbacks run (see ClaudeAgentOptions#callback_scheduling)
    # and the middleware wrapped around them (#callback_wrapper).
    callback_scheduling = configured_options.callback_scheduling || :thread
    callback_wrapper = configured_options.callback_wrapper
    ClaudeAgentSDK.check_inline_isolation(callback_scheduling)

    raise ArgumentError, 'transport must respond to #connect (see ClaudeAgentSDK::Transport)' if transport && !transport.respond_to?(:connect)

    Async(&FiberBoundary.capture_otel_context do
      materialized = nil
      query_handler = nil
      begin
        if transport.nil?
          # Resume-from-store: when a session_store is set and resume/continue
          # is requested, load the session into a temp CLAUDE_CONFIG_DIR and
          # repoint options at it (env + --resume) BEFORE spawning. Returns
          # options unchanged when no materialization applies. Skipped
          # entirely for an injected transport — the materialized
          # env/--resume only apply to the CLI subprocess (Python parity:
          # client.py skips materialization when a transport is supplied).
          materialized = SessionResume.materialize_resume_session(configured_options)
          configured_options = SessionResume.apply_materialized_options(configured_options, materialized) if materialized

          # Always use streaming mode with control protocol (matches Python
          # SDK). This sends agents via initialize request instead of CLI
          # args, avoiding OS ARG_MAX limits.
          transport = SubprocessCLITransport.new(configured_options)
        end
        # Deliberate deviation from Python: the ensure below also closes an
        # injected transport whose #connect raised (Python leaves it
        # unclosed); Transport#close must be idempotent.
        transport.connect

        # Extract SDK MCP servers
        sdk_mcp_servers = extract_sdk_mcp_servers(configured_options.mcp_servers)

        hooks = convert_hooks_to_internal_format(configured_options.hooks)

        # Create Query handler for control protocol
        query_handler = Query.new(
          transport: transport,
          is_streaming_mode: true,
          can_use_tool: configured_options.can_use_tool,
          hooks: hooks,
          agents: configured_options.agents,
          sdk_mcp_servers: sdk_mcp_servers,
          exclude_dynamic_sections: ClaudeAgentSDK.extract_exclude_dynamic_sections(configured_options.system_prompt),
          system_prompt_snapshot: ClaudeAgentSDK.extract_system_prompt_snapshot(configured_options.system_prompt),
          skills: configured_options.skills,
          forward_subagent_text: configured_options.forward_subagent_text?,
          agent_progress_summaries: configured_options.agent_progress_summaries,
          callback_scheduling: callback_scheduling,
          callback_wrapper: callback_wrapper
        )

        # Mirror transcripts to the session_store, if configured. Installed
        # before #start so the read loop captures transcript_mirror frames.
        if configured_options.session_store
          query_handler.set_transcript_mirror_batcher(
            SessionResume.build_mirror_batcher(
              store: configured_options.session_store,
              env: configured_options.env,
              on_error: ->(key, message) { query_handler.report_mirror_error(key, message) },
              eager: configured_options.session_store_flush.to_s == 'eager',
              callback_wrapper: callback_wrapper
            )
          )
        end

        # Start reading messages in background
        query_handler.start

        # Initialize the control protocol (sends agents)
        query_handler.initialize_protocol

        # Send prompt(s) as user messages, then close stdin
        if prompt.is_a?(String)
          ClaudeAgentSDK.notify_observers(resolved_observers, :on_user_prompt, prompt,
                                          scheduling: callback_scheduling, wrapper: callback_wrapper)
          message = {
            type: 'user',
            message: { role: 'user', content: prompt },
            parent_tool_use_id: nil,
            session_id: ''
          }
          transport.write(JSON.generate(message) + "\n")
          # Background-spawn so messages stream to the user block while stdin
          # close waits (without timeout) for the first result; a synchronous
          # call would defer all delivery until the turn completes (mirrors
          # Python's query.spawn_task(query.wait_for_result_and_end_input())).
          query_handler.spawn_task { query_handler.wait_for_result_and_end_input }
        elsif prompt.is_a?(Enumerator) || prompt.respond_to?(:each)
          # Tracked on the Query so close() stops it; an untracked Async task
          # here kept the root reactor alive forever when the read loop died
          # while the user enumerator was still blocked (matches Python's
          # query.spawn_task(query.stream_input(prompt))).
          observed_prompt = ClaudeAgentSDK.observing_prompt_stream(prompt, resolved_observers,
                                                                   scheduling: callback_scheduling, wrapper: callback_wrapper)
          query_handler.spawn_task { query_handler.stream_input(observed_prompt) }
        end

        # Read and yield messages from the query handler (filters out control messages).
        # User block is invoked through FiberBoundary so ActiveRecord / PG calls
        # inside it don't see the async gem's Fiber scheduler (default :thread
        # mode; :inline runs it in place on the reactor fiber).
        query_handler.receive_messages do |data|
          message = MessageParser.parse(data)
          next unless message

          ClaudeAgentSDK.notify_observers(resolved_observers, :on_message, message,
                                          scheduling: callback_scheduling, wrapper: callback_wrapper)
          signal = FiberBoundary.invoke_iteration(block, message, scheduling: callback_scheduling,
                                                                  wrapper: callback_wrapper)
          break signal.value if signal.is_a?(FiberBoundary::Break)
        end
      rescue StandardError => e
        # One notify point for every error surfacing from query() — transport
        # connect, initialize, stream errors re-raised from the message queue,
        # parse errors, and user-block errors. StandardError only: Async::Stop
        # is cancellation, not an error. Bare raise preserves the backtrace;
        # the ensure below still fires on_close after on_error.
        ClaudeAgentSDK.notify_observers(resolved_observers, :on_error, e,
                                        scheduling: callback_scheduling, wrapper: callback_wrapper)
        raise
      ensure
        ClaudeAgentSDK.notify_observers(resolved_observers, :on_close,
                                        scheduling: callback_scheduling, wrapper: callback_wrapper)
        # query_handler.close stops the background read task and closes the
        # transport (flushing the mirror batcher first). Fall back to a bare
        # transport close when the handler was never built.
        begin
          if query_handler
            query_handler.close
          elsif transport
            transport.close
          end
        ensure
          # Remove the materialized resume temp dir (which holds a redacted
          # .credentials.json copy) AFTER the subprocess has exited, even when
          # close itself raises — unless the mirror dropped batches: the store
          # copy is then incomplete and the temp dir holds the only copy of
          # the dropped turns, so it is preserved (scrubbed of credentials)
          # with a warning instead of deleted.
          if materialized
            query_handler&.mirror_batches_dropped? ? materialized.preserve_transcripts : materialized.cleanup
          end
        end
      end
    end).wait
  end

  # Run a query to completion and return its final ResultMessage.
  #
  # The one-call form of {.query} for when you want the answer rather than
  # the stream: +ask(prompt).result+ is the final text, and the returned
  # ResultMessage also carries cost, usage, duration, session_id and
  # structured_output. It is {.query} underneath — same prompt types, same
  # options, same errors — and it consumes the whole stream before
  # returning. With an Enumerable prompt that produces several turns, the
  # last ResultMessage is returned.
  #
  # An error result is returned like any other (check #is_error / #subtype);
  # when the CLI then exits non-zero, {.query} raises ResultError, which
  # propagates from here unchanged.
  #
  # @param prompt [String, Enumerable] The prompt, as for {.query}
  # @param options [ClaudeAgentOptions, nil] Optional configuration
  # @param transport [Transport, nil] Optional transport, as for {.query}
  # @yield [Message] Optionally, every message as it arrives (including the
  #   final ResultMessage), so you can stream progress and still get the
  #   result back. Runs where {.query}'s block runs. The block observes the
  #   stream; it cannot end it early — use {.query} for that.
  # @return [ResultMessage]
  # @raise [CLIConnectionError] if the stream ends without a ResultMessage
  #
  # @example
  #   puts ClaudeAgentSDK.ask('What is 2 + 2?').result
  #
  # @example Stream progress, keep the result
  #   result = ClaudeAgentSDK.ask('Refactor lib/foo.rb', options: options) do |message|
  #     puts message.text if message.is_a?(ClaudeAgentSDK::AssistantMessage)
  #   end
  #   puts result   # => [result: success, 3 turns, 12.4s, $0.0421]
  def self.ask(prompt, options: nil, transport: nil, &block)
    result = nil
    query(prompt: prompt, options: options, transport: transport) do |message|
      result = message if message.is_a?(ResultMessage)
      block&.call(message)
    end
    # The same class Query raises to a caller still waiting on the stream
    # when it ends ("Control stream ended").
    raise CLIConnectionError, 'Claude Code ended the conversation without a result message' unless result

    result
  end

  # Client for bidirectional, interactive conversations with Claude Code
  #
  # This client provides full control over the conversation flow with support
  # for streaming, hooks, permission callbacks, and dynamic message sending.
  # The Client class always uses streaming mode for bidirectional communication.
  #
  # @example Basic usage
  #   Async do
  #     client = ClaudeAgentSDK::Client.new
  #     client.connect  # No arguments needed - automatically uses streaming mode
  #
  #     client.query("What is the capital of France?")
  #     client.receive_response do |msg|
  #       puts msg if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
  #     end
  #
  #     client.disconnect
  #   end
  #
  # @example With hooks
  #   options = ClaudeAgentOptions.new(
  #     hooks: {
  #       'PreToolUse' => [
  #         HookMatcher.new(
  #           matcher: 'Bash',
  #           hooks: [
  #             ->(input, tool_use_id, context) {
  #               # Return hook output
  #               {}
  #             }
  #           ]
  #         )
  #       ]
  #     }
  #   )
  #   client = ClaudeAgentSDK::Client.new(options: options)
  class Client
    # The session's control-protocol handler (nil until #connect).
    #
    # @api private
    attr_reader :query_handler

    # @param options [ClaudeAgentOptions, nil] Configuration options
    # @param transport_class [Class] Transport class to use (must implement Transport interface).
    #   Defaults to SubprocessCLITransport.
    # @param transport_args [Hash] Additional keyword arguments passed to transport_class.new(options, **transport_args)
    def initialize(options: nil, transport_class: SubprocessCLITransport, transport_args: {})
      @options = options || ClaudeAgentOptions.new
      @callback_scheduling = @options.callback_scheduling || :thread
      @callback_wrapper = @options.callback_wrapper
      @transport_class = transport_class
      @transport_args = transport_args
      @transport = nil
      @query_handler = nil
      @connected = false
      @materialized = nil
    end

    # Block-scoped Client lifecycle, mirroring Python's
    # `async with ClaudeSDKClient() as client` and File.open ergonomics:
    # connects, yields the client, and always disconnects (block exceptions
    # propagate). Kernel#Sync runs inline inside an existing reactor and
    # creates one otherwise, so this works standalone too. Returns the
    # block's value.
    #
    # @param prompt [String, Enumerator, nil] Optional initial prompt (same as #connect)
    # @note In standalone (non-Async) use, `break` inside the block raises
    #   LocalJumpError (teardown still runs) — return a value instead.
    # @example
    #   ClaudeAgentSDK::Client.open(options: options) do |client|
    #     client.query('Hello')
    #     client.receive_response { |msg| puts msg }
    #   end
    def self.open(prompt = nil, options: nil, transport_class: SubprocessCLITransport, transport_args: {})
      raise ArgumentError, 'Client.open requires a block' unless block_given?

      Sync(&FiberBoundary.capture_otel_context do
        client = new(options: options, transport_class: transport_class, transport_args: transport_args)
        # connect failures self-clean via connect's rescue -> disconnect ->
        # raise, and disconnect is idempotent — no double-teardown.
        client.connect(prompt)
        begin
          yield client
        ensure
          client.disconnect
        end
      end)
    end

    # Connect to Claude with optional initial prompt.
    #
    # Client always uses streaming mode for bidirectional communication. If you
    # pass a String, it will be sent as an initial user message after the
    # connection is established. If you pass an Enumerator, it should yield
    # JSONL messages (e.g., from ClaudeAgentSDK::Streaming.user_message);
    # the stream is consumed in the BACKGROUND (connect returns immediately)
    # and stdin closes when it is exhausted, so the stream is the session's
    # input — a later #query after exhaustion will fail. Enumerator code runs
    # on the reactor: use a producer Thread + Thread::Queue for blocking
    # reads (Queue#pop is scheduler-aware). Stream errors are reported via
    # Observer#on_error and logged, not raised out of connect.
    #
    # @param prompt [String, Enumerator, nil] Initial prompt or message stream
    def connect(prompt = nil)
      return if @connected

      raise ArgumentError, 'prompt must be a String or an Enumerable of message Hashes/JSONL Strings (got Hash)' if prompt.is_a?(Hash)
      raise ArgumentError, "prompt must be a String, an Enumerator, or nil (got #{prompt.class})" unless prompt.nil? || prompt.is_a?(String) || prompt.respond_to?(:each)

      # Validate and configure permission settings
      configured_options = ClaudeAgentSDK.configure_can_use_tool(@options)

      # Fail fast on invalid session_store combinations before spawning the CLI.
      # Configuration validation is a usage error, like the ArgumentErrors
      # above — deliberately outside the on_error notify scope.
      SessionStores.validate_session_store_options(configured_options)

      # Resolve observers before the first failable runtime step so
      # connect-phase failures (including resume materialization) can be
      # notified via on_error.
      @resolved_observers = ClaudeAgentSDK.resolve_observers(@options.observers)

      ClaudeAgentSDK.check_inline_isolation(@callback_scheduling)

      # If anything from materialization onward fails, tear down (closes the
      # subprocess and removes the materialized temp config dir) before
      # surfacing the error, so a partial connect never leaks a temp dir
      # holding a credential copy.
      begin
        # Resume-from-store: materialize the session from the store into a
        # temp CLAUDE_CONFIG_DIR BEFORE spawn, then repoint options at it.
        # Inside the instrumented begin so store IO failures fire on_error
        # (matching the one-shot query() path) and disconnect cleans up.
        configured_options = materialize_resume(configured_options)

        connect_inner(configured_options, prompt)
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Pre-handshake failures (@connected still false) are notified here;
        # post-handshake String-prompt send failures were already notified by
        # the instrumented #query — the gate keeps on_error exactly-once.
        # (The enumerator branch streams in the background and cannot raise
        # out of connect.) No on_close follows for pre-handshake failures
        # (disconnect gates it on @connected): the session never opened.
        notify_error(e) if e.is_a?(StandardError) && !@connected
        # Tear down the partial connect, but never let a cleanup failure (e.g. a
        # custom transport whose #close raises) mask the original connect error.
        # Rescue Exception (not StandardError) so reactor cancellation
        # (Async::Stop < Exception) after materialize_resume set @materialized
        # still runs disconnect -> @materialized.cleanup, never leaking the temp
        # CLAUDE_CONFIG_DIR that holds the redacted .credentials.json copy.
        begin
          disconnect
        rescue StandardError => cleanup_error
          warn "Claude SDK: cleanup after failed connect raised: #{cleanup_error.message}"
        end
        raise
      end
    end

    # Send a query to Claude
    # @param prompt [String, Enumerable] The prompt to send — a String, or an
    #   Enumerable of message Hashes / JSONL Strings streamed inline (blocks
    #   until exhausted, like Python's async-for). Hashes lacking a
    #   session_id are stamped with the session_id: argument; JSONL Strings
    #   pass through VERBATIM — generate them with the matching session_id
    #   (Streaming.user_message defaults to 'default'). Bare Hashes are
    #   rejected (they would iterate as key-value pairs).
    # @param session_id [String] Session identifier
    def query(prompt, session_id: 'default')
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      # A bare Hash responds to #each and would silently iterate [key, value]
      # pairs (Python's async-for over a dict raises TypeError).
      raise ArgumentError, 'prompt must be a String or an Enumerable of message Hashes/JSONL Strings (got Hash)' if prompt.is_a?(Hash)

      begin
        if prompt.is_a?(String)
          ClaudeAgentSDK.notify_observers(@resolved_observers, :on_user_prompt, prompt,
                                          scheduling: @callback_scheduling, wrapper: @callback_wrapper)
          message = {
            type: 'user',
            message: { role: 'user', content: prompt },
            parent_tool_use_id: nil,
            session_id: session_id
          }
          writeln(JSON.generate(message))
        elsif prompt.respond_to?(:each)
          # Inline iteration on the caller, Python client.py parity — NOT
          # Query#stream_input, whose ensure always ends input after
          # exhaustion (correct for connect-time sole-input streams, fatal
          # for a mid-session query). Blocks until the iterable is exhausted,
          # identical to Python's async-for.
          stream_query_messages(prompt, session_id)
        else
          raise ArgumentError, "prompt must be a String or respond to #each (got #{prompt.class})"
        end
      rescue StandardError => e
        notify_error(e)
        raise
      end
    end

    # Receive all messages from Claude
    # @yield [Message] Each message received
    # @return [Enumerator] when no block is given (internal iteration only)
    # @note #next/#peek either raise FiberError or hang depending on message
    #   timing, and can kill the session's read loop, leaving the client
    #   unusable; iterate with a block or each-driven Enumerable methods
    #   (#first, #take) inside the Async block instead.
    def receive_messages(&block)
      return enum_for(:receive_messages) unless block

      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected

      begin
        @query_handler.receive_messages do |data|
          message = MessageParser.parse(data)
          next unless message

          ClaudeAgentSDK.notify_observers(@resolved_observers, :on_message, message,
                                          scheduling: @callback_scheduling, wrapper: @callback_wrapper)
          signal = FiberBoundary.invoke_iteration(block, message, scheduling: @callback_scheduling,
                                                                  wrapper: @callback_wrapper)
          break signal.value if signal.is_a?(FiberBoundary::Break)
        end
      rescue StandardError => e
        notify_error(e)
        raise
      end
    end

    # Receive messages until a ResultMessage is received
    # @yield [Message] Each message received
    def receive_response(&block)
      return enum_for(:receive_response) unless block

      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected

      # Keep loop control on the same fiber as the underlying dequeue: both
      # the SDK's ResultMessage break and the user's translated break happen
      # here, never inside the FiberBoundary hop (break in a proc on a
      # foreign thread raises LocalJumpError).
      begin
        @query_handler.receive_messages do |data|
          message = MessageParser.parse(data)
          next unless message

          ClaudeAgentSDK.notify_observers(@resolved_observers, :on_message, message,
                                          scheduling: @callback_scheduling, wrapper: @callback_wrapper)
          signal = FiberBoundary.invoke_iteration(block, message, scheduling: @callback_scheduling,
                                                                  wrapper: @callback_wrapper)
          break signal.value if signal.is_a?(FiberBoundary::Break)
          break if message.is_a?(ResultMessage)
        end
      rescue StandardError => e
        notify_error(e)
        raise
      end
    end

    # Send interrupt signal
    def interrupt
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.interrupt
    end

    # Change permission mode during conversation
    # @param mode [String] Permission mode ('default', 'acceptEdits', 'bypassPermissions')
    def set_permission_mode(mode)
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.set_permission_mode(mode)
    end

    # Ruby-style spelling of #set_permission_mode: `client.permission_mode = 'plan'`.
    # Delegates (rather than aliasing) so an override of #set_permission_mode applies to both.
    def permission_mode=(mode)
      set_permission_mode(mode)
    end

    # Change the AI model during conversation
    # @param model [String, nil] Model name or nil for default
    def set_model(model)
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.set_model(model)
    end

    # Ruby-style spelling of #set_model: `client.model = 'claude-opus-5'`.
    def model=(model)
      set_model(model)
    end

    # Reconnect a failed MCP server
    # @param server_name [String] Name of the MCP server to reconnect
    def reconnect_mcp_server(server_name)
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.reconnect_mcp_server(server_name)
    end

    # Enable or disable an MCP server
    # @param server_name [String] Name of the MCP server
    # @param enabled [Boolean] Whether to enable or disable
    def toggle_mcp_server(server_name, enabled)
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.toggle_mcp_server(server_name, enabled)
    end

    # Stop a running background task
    # @param task_id [String] The ID of the task to stop
    def stop_task(task_id)
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.stop_task(task_id)
    end

    # Background in-flight foreground tasks (Bash commands and subagents) — the
    # control-request equivalent of pressing Ctrl+B in the terminal. Each
    # blocking tool call returns a "running in the background" tool_result and
    # the turn continues; the task keeps running and emits a
    # TaskNotificationMessage when it settles.
    #
    # The targeted form reports its outcome: `{ backgrounded: true }`, or
    # `{ backgrounded: false }` — a definitive miss (no matching foreground
    # task), so do not wait for an event after it. The all-tasks form returns
    # `{}` and says nothing about whether any task existed. Observe
    # TaskUpdatedMessage#is_backgrounded / BackgroundTasksChangedMessage for the
    # lifecycle state that follows.
    #
    # @param tool_use_id [String, nil] The id of the tool_use block that spawned
    #   the task — NOT a task_id or agent_id. nil is the explicit all-tasks form.
    #   Never substitute nil or '' for a per-task id you do not have yet
    #   (TaskStartedMessage#tool_use_id is optional on the wire)
    # @return [Hash] `{ backgrounded: true/false }` when tool_use_id was given,
    #   `{}` otherwise
    # @raise [ArgumentError] if tool_use_id is neither nil nor a non-empty String
    def background_tasks(tool_use_id: nil)
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.background_tasks(tool_use_id: tool_use_id)
    end

    # Rewind files to a previous checkpoint (v0.1.15+)
    # Restores file state to what it was at the given user message
    # Requires enable_file_checkpointing to be true in options
    # @param user_message_uuid [String] The UUID of the UserMessage to rewind to
    def rewind_files(user_message_uuid)
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.rewind_files(user_message_uuid)
    end

    # Get server initialization info
    # @return [Hash, nil] Server info or nil
    def server_info
      @query_handler&.initialization_result
    end

    # Get a breakdown of current context window usage by category.
    # Returns token counts per category (system prompt, tools, messages, etc.),
    # total/max tokens, model info, MCP tools, memory files, and more.
    # @return [Hash] Context usage response
    def get_context_usage
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.get_context_usage
    end

    # Ruby-style spelling of #get_context_usage.
    # @return [Hash] Context usage response
    def context_usage
      get_context_usage
    end

    # Get current MCP server connection status (only works with streaming mode)
    # @return [Hash] MCP status information, including mcpServers list
    def get_mcp_status
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.get_mcp_status
    end

    # Ruby-style spelling of #get_mcp_status.
    # @return [Hash] MCP status information, including mcpServers list
    def mcp_status
      get_mcp_status
    end

    # Get server initialization info including available commands and output styles
    # @return [Hash] Server info
    def get_server_info
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      server_info
    end

    # Disconnect from Claude
    #
    # Callable from inside a user callback (tool handler / hook /
    # can_use_tool). With the default `callback_scheduling: :thread` the
    # callback runs on a worker thread: the close is marshalled to the
    # reactor, returns normally once the teardown completed, and the
    # callback's return value is dropped (its reactor task was stopped). With
    # `:inline` the callback's task is a child of the read task being
    # stopped, so once the teardown has completed the deferred Async::Stop
    # unwinds the callback — disconnect raises rather than returns there;
    # ensure blocks run, `rescue StandardError` does not see it. The same
    # holds, in every scheduling mode, for a streaming-input enumerator that
    # calls disconnect: it is iterated on the reactor inside a task the close
    # stops, so it unwinds with Async::Stop once the teardown has completed.
    def disconnect
      if @connected
        ClaudeAgentSDK.notify_observers(@resolved_observers || [], :on_close,
                                        scheduling: @callback_scheduling, wrapper: @callback_wrapper)
      end
      # Tear down whatever exists — robust to a partial/failed connect, where
      # @connected is still false but a transport and/or materialized temp dir
      # were already created. #close on the query handler also closes the
      # transport (flushing the mirror batcher first); the extra @transport
      # close covers a failure before the query handler was built (idempotent).
      #
      # The nested ensures guarantee that even a raising close (e.g. a custom
      # transport whose #close raises) still runs the transport close, resets
      # state, and removes the materialized temp dir (which holds a redacted
      # .credentials.json copy) — so disconnect can never leave the client
      # half-open or leak the temp dir. The original error still propagates.
      # Keep a handle on the query handler past the nil-out below: whether the
      # mirror dropped batches is only final AFTER #close ran its last flush,
      # and the materialized-dir decision at the bottom needs to ask it.
      query_handler = @query_handler
      begin
        @query_handler&.close
      ensure
        @query_handler = nil
        begin
          @transport&.close
        ensure
          @transport = nil
          @connected = false
          # Remove the materialized resume temp dir AFTER the subprocess
          # exited — unless the mirror dropped batches: the store copy is then
          # incomplete and the temp dir holds the only copy of the dropped
          # turns, so it is preserved (scrubbed of credentials) with a warning
          # instead of deleted.
          if @materialized
            if query_handler&.mirror_batches_dropped?
              @materialized.preserve_transcripts
            else
              @materialized.cleanup
            end
            @materialized = nil
          end
        end
      end
    end

    private

    # Resume-from-store: when a session_store is set (and a subprocess transport
    # is in use), materialize the session into a temp CLAUDE_CONFIG_DIR and
    # return options repointed at it (env + --resume). Returns the options
    # unchanged when no materialization applies. Skipped for non-subprocess
    # transports — the materialized env/--resume only affect the CLI subprocess.
    # Ancestry (<=), not identity: a SubprocessCLITransport subclass spawns the
    # CLI with the same env/--resume semantics, and the transport is constructed
    # AFTER materialization, so the repointed options do reach it.
    def materialize_resume(options)
      subprocess_transport = @transport_class.is_a?(Class) && @transport_class <= SubprocessCLITransport
      return options unless options.session_store && subprocess_transport

      @materialized = SessionResume.materialize_resume_session(options)
      @materialized ? SessionResume.apply_materialized_options(options, @materialized) : options
    end

    # The connect body, wrapped by #connect so a failure triggers cleanup.
    def connect_inner(configured_options, prompt)
      # Client always uses streaming mode; keep stdin open for bidirectional
      # communication. Observers were already resolved by #connect.
      @transport = @transport_class.new(configured_options, **@transport_args)
      @transport.connect

      # Extract SDK MCP servers
      sdk_mcp_servers = ClaudeAgentSDK.extract_sdk_mcp_servers(configured_options.mcp_servers)

      # Convert hooks to internal format
      hooks = ClaudeAgentSDK.convert_hooks_to_internal_format(configured_options.hooks)

      # Extract exclude_dynamic_sections and snapshot from the system prompt
      # for the initialize request (older CLIs ignore unknown initialize fields)
      exclude_dynamic_sections = ClaudeAgentSDK.extract_exclude_dynamic_sections(configured_options.system_prompt)
      system_prompt_snapshot = ClaudeAgentSDK.extract_system_prompt_snapshot(configured_options.system_prompt)

      # Create Query handler
      @query_handler = Query.new(
        transport: @transport,
        is_streaming_mode: true,
        can_use_tool: configured_options.can_use_tool,
        hooks: hooks,
        sdk_mcp_servers: sdk_mcp_servers,
        agents: configured_options.agents,
        exclude_dynamic_sections: exclude_dynamic_sections,
        system_prompt_snapshot: system_prompt_snapshot,
        skills: configured_options.skills,
        forward_subagent_text: configured_options.forward_subagent_text?,
        agent_progress_summaries: configured_options.agent_progress_summaries,
        callback_scheduling: @callback_scheduling,
        callback_wrapper: @callback_wrapper
      )

      # Mirror transcripts to the session_store, if configured.
      install_transcript_mirror(configured_options)

      # Start query handler and initialize
      @query_handler.start
      @query_handler.initialize_protocol

      @connected = true

      # Optionally send initial prompt/messages after connection is ready.
      case prompt
      when nil
        nil
      when String
        query(prompt)
      else
        # Stream in the background, exactly like query()'s Enumerator path
        # (Python client.py: query.spawn_task(query.stream_input(prompt))).
        # The old inline `prompt.each` blocked connect until the stream was
        # exhausted — an interactive stream that waits for a response before
        # yielding deadlocked connect — and serialized Hash messages with
        # to_s (Ruby inspect, not JSON). stream_input JSON-generates Hashes
        # and is tracked on the Query so close() stops it. Stream errors are
        # swallowed-with-warn by stream_input (Python parity) — they don't
        # abort connect, and observers are NOT notified (the documented
        # Observer#on_error contract; notifying a swallowed error would mark
        # a still-live OTel trace as failed). Same behavior as query()'s
        # streaming path.
        observed = ClaudeAgentSDK.observing_prompt_stream(prompt, @resolved_observers,
                                                          scheduling: @callback_scheduling, wrapper: @callback_wrapper)
        @query_handler.spawn_task { @query_handler.stream_input(observed) }
      end
    end

    # Stream an iterable of message Hashes / JSONL Strings as session input,
    # stamping session_id on Hashes that lack one (key-presence check, both
    # key styles — an explicit nil is preserved, mirroring Python's
    # `"session_id" not in msg`). Strings pass through verbatim (Ruby
    # superset: Streaming.user_message emits pre-serialized JSONL; no
    # parse-stamp-regenerate, which would block the reactor on huge frames).
    def stream_query_messages(prompt, session_id)
      prompt.each do |msg|
        case msg
        when Hash
          msg = msg.merge(session_id: session_id) unless msg.key?(:session_id) || msg.key?('session_id')
          if (text = ClaudeAgentSDK.extract_user_prompt_text(msg))
            ClaudeAgentSDK.notify_observers(@resolved_observers, :on_user_prompt, text,
                                            scheduling: @callback_scheduling, wrapper: @callback_wrapper)
          end
          writeln(JSON.generate(msg))
        when String
          if (text = ClaudeAgentSDK.extract_user_prompt_text(msg))
            ClaudeAgentSDK.notify_observers(@resolved_observers, :on_user_prompt, text,
                                            scheduling: @callback_scheduling, wrapper: @callback_wrapper)
          end
          writeln(msg)
        else
          # No to_s fallback — silently serializing arbitrary objects is the
          # exact inspect-garbage bug class this method exists to prevent.
          raise ArgumentError, "stream items must be Hashes or JSONL Strings (got #{msg.class})"
        end
      end
    end

    # Notify observers of an error surfacing to the consumer. `|| []` keeps a
    # mis-scoped call before connect harmless instead of NoMethodError on nil.
    def notify_error(error)
      ClaudeAgentSDK.notify_observers(@resolved_observers || [], :on_error, error,
                                      scheduling: @callback_scheduling, wrapper: @callback_wrapper)
    end

    # Build and install the transcript-mirror batcher on the query handler when
    # a session_store is configured, via the shared SessionResume helper (also
    # used by the one-shot query() path).
    def install_transcript_mirror(options)
      return unless options.session_store

      batcher = SessionResume.build_mirror_batcher(
        store: options.session_store,
        env: options.env,
        on_error: ->(key, message) { @query_handler.report_mirror_error(key, message) },
        eager: options.session_store_flush.to_s == 'eager',
        callback_wrapper: @callback_wrapper
      )
      @query_handler.set_transcript_mirror_batcher(batcher)
    end

    def writeln(string)
      write string.end_with?("\n") ? string : "#{string}\n"
    end

    def write(string)
      @transport.write(string)
    end
  end
end
