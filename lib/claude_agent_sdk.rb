# frozen_string_literal: true

require_relative 'claude_agent_sdk/version'
require_relative 'claude_agent_sdk/errors'
require_relative 'claude_agent_sdk/configuration'
require_relative 'claude_agent_sdk/types'
require_relative 'claude_agent_sdk/observer'
require_relative 'claude_agent_sdk/transport'
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
require 'async'
require 'securerandom'

# Claude Agent SDK for Ruby
module ClaudeAgentSDK
  # The duck-typed observer surface probed by resolve_observers — implementing
  # any one of these counts as an observer (see Observer's no-op defaults).
  OBSERVER_INTERFACE = %i[on_user_prompt on_message on_error on_close].freeze

  # Resolve observers array: callables (Proc/lambda) are invoked to produce
  # a fresh instance per query/session (thread-safe); plain objects are used as-is.
  # Array() guards against nil (e.g., when observers: nil is passed explicitly).
  # Anything implementing none of the observer methods is warned about and
  # skipped — most commonly a Class passed instead of an instance, which
  # previously produced silent zero instrumentation (every notify raised
  # NoMethodError, swallowed by notify_observers' error containment).
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
  # guard, so its in-process server was silently never registered.
  def self.extract_sdk_mcp_servers(mcp_servers)
    return {} unless mcp_servers.is_a?(Hash)

    servers = {}
    mcp_servers.each do |name, config|
      config = config.to_h if config.is_a?(Type)
      servers[name] = config[:instance] if config.is_a?(Hash) && config[:type] == 'sdk'
    end
    servers
  end

  # Internal: pull exclude_dynamic_sections out of a preset system prompt for
  # the initialize request (older CLIs ignore unknown initialize fields).
  # Shared by Client#connect and the one-shot query() path.
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

  # Safely call a method on each observer, suppressing any errors.
  # Each observer is invoked through FiberBoundary so that user code runs
  # on a plain thread (no Fiber scheduler) even when called from inside
  # the SDK's Async reactor.
  def self.notify_observers(observers, method, *args)
    observers.each do |obs|
      FiberBoundary.invoke { obs.send(method, *args) }
    rescue StandardError, ScriptError
      # ScriptError too: NotImplementedError < ScriptError (not
      # StandardError), and a stubbed observer must never mask the original
      # error being notified or abort connect/teardown cleanup.
      nil
    end
  end

  # Extract the user-visible prompt text from a streamed input item, or nil
  # when there is none (non-user messages, tool_result-only content, …).
  # Only Hash and JSON-string items are inspected; arbitrary objects written
  # via to_s are never notified.
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
  def self.observing_prompt_stream(prompt, observers)
    return prompt if observers.empty?

    Enumerator.new do |yielder|
      prompt.each do |message|
        text = extract_user_prompt_text(message)
        notify_observers(observers, :on_user_prompt, text) if text
        yielder << message
      end
    end
  end

  # Look up a value in a hash that may use symbol or string keys in camelCase or snake_case.
  # Returns the first non-nil value found, preserving false as a meaningful value.
  def self.flexible_fetch(hash, camel_key, snake_key)
    val = hash[camel_key.to_sym]
    val = hash[camel_key.to_s] if val.nil?
    val = hash[snake_key.to_sym] if val.nil?
    val = hash[snake_key.to_s] if val.nil?
    val
  end

  # List sessions for a directory (or all sessions)
  # @param directory [String, nil] Working directory to list sessions for
  # @param limit [Integer, nil] Maximum number of sessions to return
  # @param offset [Integer] Number of sessions to skip (for pagination)
  # @param include_worktrees [Boolean] Whether to include git worktree sessions
  # @return [Array<SDKSessionInfo>] Sessions sorted by last_modified descending
  def self.list_sessions(directory: nil, limit: nil, offset: 0, include_worktrees: true)
    Sessions.list_sessions(directory: directory, limit: limit, offset: offset, include_worktrees: include_worktrees)
  end

  # Read metadata for a single session by ID (no full directory scan)
  # @param session_id [String] UUID of the session to look up
  # @param directory [String, nil] Project directory path
  # @return [SDKSessionInfo, nil] Session info, or nil if not found
  def self.get_session_info(session_id:, directory: nil)
    Sessions.get_session_info(session_id: session_id, directory: directory)
  end

  # Get messages from a session transcript
  # @param session_id [String] The session UUID
  # @param directory [String, nil] Working directory to search in
  # @param limit [Integer, nil] Maximum number of messages
  # @param offset [Integer] Number of messages to skip
  # @return [Array<SessionMessage>] Ordered messages from the session
  def self.get_session_messages(session_id:, directory: nil, limit: nil, offset: 0)
    Sessions.get_session_messages(session_id: session_id, directory: directory, limit: limit, offset: offset)
  end

  # List subagent IDs recorded for a session on local disk
  # @param session_id [String] The session UUID
  # @param directory [String, nil] Working directory to search in
  # @return [Array<String>] Subagent IDs
  def self.list_subagents(session_id:, directory: nil)
    Sessions.list_subagents(session_id: session_id, directory: directory)
  end

  # Read a subagent's conversation messages from local disk
  # @param session_id [String] The session UUID
  # @param agent_id [String] The subagent ID (without the agent- prefix)
  # @param directory [String, nil] Working directory to search in
  # @param limit [Integer, nil] Maximum number of messages
  # @param offset [Integer] Number of messages to skip
  # @return [Array<SessionMessage>] Ordered messages from the subagent
  def self.get_subagent_messages(session_id:, agent_id:, directory: nil, limit: nil, offset: 0)
    Sessions.get_subagent_messages(session_id: session_id, agent_id: agent_id,
                                   directory: directory, limit: limit, offset: offset)
  end

  # Rename a session by appending a custom-title entry
  # @param session_id [String] UUID of the session to rename
  # @param title [String] New session title
  # @param directory [String, nil] Project directory path
  def self.rename_session(session_id:, title:, directory: nil)
    SessionMutations.rename_session(session_id: session_id, title: title, directory: directory)
  end

  # Tag a session. Pass nil to clear the tag.
  # @param session_id [String] UUID of the session to tag
  # @param tag [String, nil] Tag string, or nil to clear
  # @param directory [String, nil] Project directory path
  def self.tag_session(session_id:, tag:, directory: nil)
    SessionMutations.tag_session(session_id: session_id, tag: tag, directory: directory)
  end

  # Delete a session by removing its JSONL file (hard delete).
  # @param session_id [String] UUID of the session to delete
  # @param directory [String, nil] Project directory path
  def self.delete_session(session_id:, directory: nil)
    SessionMutations.delete_session(session_id: session_id, directory: directory)
  end

  # Fork a session into a new branch with fresh UUIDs.
  # @param session_id [String] UUID of the session to fork
  # @param directory [String, nil] Project directory path
  # @param up_to_message_id [String, nil] Truncate the fork at this message UUID
  # @param title [String, nil] Custom title for the fork
  # @return [ForkSessionResult] Result containing the new session ID
  def self.fork_session(session_id:, directory: nil, up_to_message_id: nil, title: nil)
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

  # List sessions from a SessionStore (store-backed counterpart to list_sessions).
  # @param session_store [SessionStore] the store to read from
  # @return [Array<SDKSessionInfo>] sorted by last_modified descending
  def self.list_sessions_from_store(session_store:, directory: nil, limit: nil, offset: 0)
    Sessions.list_sessions_from_store(session_store: session_store, directory: directory, limit: limit, offset: offset)
  end

  # Read metadata for a single session from a SessionStore.
  # @return [SDKSessionInfo, nil]
  def self.get_session_info_from_store(session_store:, session_id:, directory: nil)
    Sessions.get_session_info_from_store(session_store: session_store, session_id: session_id, directory: directory)
  end

  # Read a session's conversation messages from a SessionStore.
  # @return [Array<SessionMessage>]
  def self.get_session_messages_from_store(session_store:, session_id:, directory: nil, limit: nil, offset: 0)
    Sessions.get_session_messages_from_store(session_store: session_store, session_id: session_id,
                                             directory: directory, limit: limit, offset: offset)
  end

  # List subagent IDs for a session from a SessionStore (requires list_subkeys).
  # @return [Array<String>]
  def self.list_subagents_from_store(session_store:, session_id:, directory: nil)
    Sessions.list_subagents_from_store(session_store: session_store, session_id: session_id, directory: directory)
  end

  # Read a subagent's conversation messages from a SessionStore.
  # @return [Array<SessionMessage>]
  def self.get_subagent_messages_from_store(session_store:, session_id:, agent_id:, directory: nil, limit: nil,
                                            offset: 0)
    Sessions.get_subagent_messages_from_store(session_store: session_store, session_id: session_id,
                                              agent_id: agent_id, directory: directory, limit: limit, offset: offset)
  end

  # Rename a session in a SessionStore (store-backed counterpart to
  # rename_session). Appends a custom-title entry carrying a fresh uuid +
  # timestamp via SessionStore#append.
  # @raise [ArgumentError] if session_id is invalid or title is empty
  def self.rename_session_via_store(session_store:, session_id:, title:, directory: nil)
    SessionMutations.rename_session_via_store(session_store: session_store, session_id: session_id,
                                              title: title, directory: directory)
  end

  # Tag a session in a SessionStore (store-backed counterpart to tag_session).
  # Pass nil to clear the tag.
  # @raise [ArgumentError] if session_id is invalid or tag is empty after sanitization
  def self.tag_session_via_store(session_store:, session_id:, tag:, directory: nil)
    SessionMutations.tag_session_via_store(session_store: session_store, session_id: session_id,
                                           tag: tag, directory: directory)
  end

  # Delete a session from a SessionStore (store-backed counterpart to
  # delete_session). No-op when the store does not implement #delete
  # (WORM/append-only backends).
  # @raise [ArgumentError] if session_id is invalid
  def self.delete_session_via_store(session_store:, session_id:, directory: nil)
    SessionMutations.delete_session_via_store(session_store: session_store, session_id: session_id,
                                              directory: directory)
  end

  # Fork a session in a SessionStore into a new branch with fresh UUIDs
  # (store-backed counterpart to fork_session).
  # @return [ForkSessionResult] result containing the new session ID
  # @raise [ArgumentError] if session_id/up_to_message_id is invalid or there are no messages
  # @raise [Errno::ENOENT] if the source session is not found in the store
  def self.fork_session_via_store(session_store:, session_id:, directory: nil, up_to_message_id: nil, title: nil)
    SessionMutations.fork_session_via_store(session_store: session_store, session_id: session_id,
                                            directory: directory, up_to_message_id: up_to_message_id, title: title)
  end

  # Replay a local on-disk session transcript into a SessionStore (migration /
  # gap-backfill). Keys under the on-disk project dir so the imported session is
  # resumable via session_store + resume from the original cwd.
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

    configured_options = options
    if options.can_use_tool
      if prompt.is_a?(String)
        raise ArgumentError,
              'can_use_tool callback requires streaming mode. Please provide prompt as an Enumerator instead of a String.'
      end

      raise ArgumentError, 'can_use_tool callback cannot be used with permission_prompt_tool_name' if options.permission_prompt_tool_name

      configured_options = options.dup_with(permission_prompt_tool_name: 'stdio')
    end

    # Fail fast on invalid session_store combinations before spawning the CLI.
    SessionStores.validate_session_store_options(configured_options)

    # Resolve callable observers into fresh instances (thread-safe for global defaults)
    resolved_observers = ClaudeAgentSDK.resolve_observers(configured_options.observers)

    raise ArgumentError, 'transport must respond to #connect (see ClaudeAgentSDK::Transport)' if transport && !transport.respond_to?(:connect)

    Async do
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

        hooks = nil
        if configured_options.hooks
          hooks = {}
          configured_options.hooks.each do |event, matchers|
            next if matchers.nil? || matchers.empty?

            entries = []
            matchers.each do |matcher|
              config = {
                matcher: matcher.matcher,
                hooks: matcher.hooks
              }
              config[:timeout] = matcher.timeout if matcher.timeout
              entries << config
            end
            hooks[event.to_s] = entries unless entries.empty?
          end
          hooks = nil if hooks.empty?
        end

        # Create Query handler for control protocol
        query_handler = Query.new(
          transport: transport,
          is_streaming_mode: true,
          can_use_tool: configured_options.can_use_tool,
          hooks: hooks,
          agents: configured_options.agents,
          sdk_mcp_servers: sdk_mcp_servers,
          exclude_dynamic_sections: ClaudeAgentSDK.extract_exclude_dynamic_sections(configured_options.system_prompt),
          skills: configured_options.skills
        )

        # Mirror transcripts to the session_store, if configured. Installed
        # before #start so the read loop captures transcript_mirror frames.
        if configured_options.session_store
          query_handler.set_transcript_mirror_batcher(
            SessionResume.build_mirror_batcher(
              store: configured_options.session_store,
              env: configured_options.env,
              on_error: ->(key, message) { query_handler.report_mirror_error(key, message) },
              eager: configured_options.session_store_flush.to_s == 'eager'
            )
          )
        end

        # Start reading messages in background
        query_handler.start

        # Initialize the control protocol (sends agents)
        query_handler.initialize_protocol

        # Send prompt(s) as user messages, then close stdin
        if prompt.is_a?(String)
          ClaudeAgentSDK.notify_observers(resolved_observers, :on_user_prompt, prompt)
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
          observed_prompt = ClaudeAgentSDK.observing_prompt_stream(prompt, resolved_observers)
          query_handler.spawn_task { query_handler.stream_input(observed_prompt) }
        end

        # Read and yield messages from the query handler (filters out control messages).
        # User block is invoked through FiberBoundary so ActiveRecord / PG calls
        # inside it don't see the async gem's Fiber scheduler.
        query_handler.receive_messages do |data|
          message = MessageParser.parse(data)
          next unless message

          ClaudeAgentSDK.notify_observers(resolved_observers, :on_message, message)
          signal = FiberBoundary.invoke_iteration(block, message)
          break signal.value if signal.is_a?(FiberBoundary::Break)
        end
      rescue StandardError => e
        # One notify point for every error surfacing from query() — transport
        # connect, initialize, stream errors re-raised from the message queue,
        # parse errors, and user-block errors. StandardError only: Async::Stop
        # is cancellation, not an error. Bare raise preserves the backtrace;
        # the ensure below still fires on_close after on_error.
        ClaudeAgentSDK.notify_observers(resolved_observers, :on_error, e)
        raise
      ensure
        ClaudeAgentSDK.notify_observers(resolved_observers, :on_close)
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
          # close itself raises.
          materialized&.cleanup
        end
      end
    end.wait
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
    attr_reader :query_handler

    # @param options [ClaudeAgentOptions, nil] Configuration options
    # @param transport_class [Class] Transport class to use (must implement Transport interface).
    #   Defaults to SubprocessCLITransport.
    # @param transport_args [Hash] Additional keyword arguments passed to transport_class.new(options, **transport_args)
    def initialize(options: nil, transport_class: SubprocessCLITransport, transport_args: {})
      @options = options || ClaudeAgentOptions.new
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

      Sync do
        client = new(options: options, transport_class: transport_class, transport_args: transport_args)
        # connect failures self-clean via connect's rescue -> disconnect ->
        # raise, and disconnect is idempotent — no double-teardown.
        client.connect(prompt)
        begin
          yield client
        ensure
          client.disconnect
        end
      end
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

      raise ArgumentError, "prompt must be a String, an Enumerator, or nil (got #{prompt.class})" unless prompt.nil? || prompt.is_a?(String) || prompt.respond_to?(:each)

      # Validate and configure permission settings
      configured_options = @options
      if @options.can_use_tool
        # can_use_tool and permission_prompt_tool_name are mutually exclusive
        raise ArgumentError, 'can_use_tool callback cannot be used with permission_prompt_tool_name' if @options.permission_prompt_tool_name

        # Set permission_prompt_tool_name to stdio for control protocol
        configured_options = @options.dup_with(permission_prompt_tool_name: 'stdio')
      end

      # Fail fast on invalid session_store combinations before spawning the CLI.
      # Configuration validation is a usage error, like the ArgumentErrors
      # above — deliberately outside the on_error notify scope.
      SessionStores.validate_session_store_options(configured_options)

      # Resolve observers before the first failable runtime step so
      # connect-phase failures (including resume materialization) can be
      # notified via on_error.
      @resolved_observers = ClaudeAgentSDK.resolve_observers(@options.observers)

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
          ClaudeAgentSDK.notify_observers(@resolved_observers, :on_user_prompt, prompt)
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

          ClaudeAgentSDK.notify_observers(@resolved_observers, :on_message, message)
          signal = FiberBoundary.invoke_iteration(block, message)
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

          ClaudeAgentSDK.notify_observers(@resolved_observers, :on_message, message)
          signal = FiberBoundary.invoke_iteration(block, message)
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

    # Change the AI model during conversation
    # @param model [String, nil] Model name or nil for default
    def set_model(model)
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.set_model(model)
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
      @query_handler&.instance_variable_get(:@initialization_result)
    end

    # Get a breakdown of current context window usage by category.
    # Returns token counts per category (system prompt, tools, messages, etc.),
    # total/max tokens, model info, MCP tools, memory files, and more.
    # @return [Hash] Context usage response
    def get_context_usage
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.get_context_usage
    end

    # Get current MCP server connection status (only works with streaming mode)
    # @return [Hash] MCP status information, including mcpServers list
    def get_mcp_status
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      @query_handler.get_mcp_status
    end

    # Get server initialization info including available commands and output styles
    # @return [Hash] Server info
    def get_server_info
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected
      server_info
    end

    # Disconnect from Claude
    def disconnect
      ClaudeAgentSDK.notify_observers(@resolved_observers || [], :on_close) if @connected
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
      begin
        @query_handler&.close
      ensure
        @query_handler = nil
        begin
          @transport&.close
        ensure
          @transport = nil
          @connected = false
          # Remove the materialized resume temp dir AFTER the subprocess exited.
          if @materialized
            @materialized.cleanup
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
      hooks = convert_hooks_to_internal_format(configured_options.hooks) if configured_options.hooks

      # Extract exclude_dynamic_sections from preset system prompt for the
      # initialize request (older CLIs ignore unknown initialize fields)
      exclude_dynamic_sections = ClaudeAgentSDK.extract_exclude_dynamic_sections(configured_options.system_prompt)

      # Create Query handler
      @query_handler = Query.new(
        transport: @transport,
        is_streaming_mode: true,
        can_use_tool: configured_options.can_use_tool,
        hooks: hooks,
        sdk_mcp_servers: sdk_mcp_servers,
        agents: configured_options.agents,
        exclude_dynamic_sections: exclude_dynamic_sections,
        skills: configured_options.skills
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
        # notified to observers once, then swallowed-with-warn by
        # stream_input (Python parity) — they no longer abort connect.
        observed = ClaudeAgentSDK.observing_prompt_stream(prompt, @resolved_observers)
        notifying = error_notifying_stream(observed)
        @query_handler.spawn_task { @query_handler.stream_input(notifying) }
      end
    end

    # Wrap a stream so a raising user enumerator fires on_error exactly once
    # before stream_input's swallow-with-warn handling takes over.
    def error_notifying_stream(stream)
      Enumerator.new do |yielder|
        stream.each { |message| yielder << message }
      rescue StandardError => e
        notify_error(e)
        raise
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
            ClaudeAgentSDK.notify_observers(@resolved_observers, :on_user_prompt, text)
          end
          writeln(JSON.generate(msg))
        when String
          if (text = ClaudeAgentSDK.extract_user_prompt_text(msg))
            ClaudeAgentSDK.notify_observers(@resolved_observers, :on_user_prompt, text)
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
      ClaudeAgentSDK.notify_observers(@resolved_observers || [], :on_error, error)
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
        eager: options.session_store_flush.to_s == 'eager'
      )
      @query_handler.set_transcript_mirror_batcher(batcher)
    end

    def convert_hooks_to_internal_format(hooks)
      return nil unless hooks

      internal_hooks = {}
      hooks.each do |event, matchers|
        internal_hooks[event.to_s] = []
        matchers.each do |matcher|
          config = {
            matcher: matcher.matcher,
            hooks: matcher.hooks
          }
          config[:timeout] = matcher.timeout if matcher.timeout
          internal_hooks[event.to_s] << config
        end
      end
      internal_hooks
    end

    def writeln(string)
      write string.end_with?("\n") ? string : "#{string}\n"
    end

    def write(string)
      @transport.write(string)
    end
  end
end
