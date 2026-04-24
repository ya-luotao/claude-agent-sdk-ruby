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
require_relative 'claude_agent_sdk/session_mutations'
require_relative 'claude_agent_sdk/fiber_boundary'
require 'async'
require 'securerandom'

# Claude Agent SDK for Ruby
module ClaudeAgentSDK
  # Resolve observers array: callables (Proc/lambda) are invoked to produce
  # a fresh instance per query/session (thread-safe); plain objects are used as-is.
  # Array() guards against nil (e.g., when observers: nil is passed explicitly).
  def self.resolve_observers(observers)
    Array(observers).map do |obs|
      obs.respond_to?(:call) ? obs.call : obs
    end
  end

  # Safely call a method on each observer, suppressing any errors.
  # Each observer is invoked through FiberBoundary so that user code runs
  # on a plain thread (no Fiber scheduler) even when called from inside
  # the SDK's Async reactor.
  def self.notify_observers(observers, method, *args)
    observers.each do |obs|
      FiberBoundary.invoke { obs.send(method, *args) }
    rescue StandardError
      nil
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

  # Query Claude Code for one-shot or unidirectional streaming interactions
  #
  # This function is ideal for simple, stateless queries where you don't need
  # bidirectional communication or conversation management.
  #
  # @param prompt [String, Enumerator] The prompt to send to Claude, or an Enumerator for streaming input
  # @param options [ClaudeAgentOptions] Optional configuration
  # @yield [Message] Each message from the conversation
  # @return [Enumerator] if no block given
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

  def self.query(prompt:, options: nil, &block)
    return enum_for(:query, prompt: prompt, options: options) unless block

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

    # Resolve callable observers into fresh instances (thread-safe for global defaults)
    resolved_observers = ClaudeAgentSDK.resolve_observers(configured_options.observers)

    Async do
      # Always use streaming mode with control protocol (matches Python SDK).
      # This sends agents via initialize request instead of CLI args,
      # avoiding OS ARG_MAX limits.
      transport = SubprocessCLITransport.new(configured_options)
      begin
        transport.connect

        # Extract SDK MCP servers
        sdk_mcp_servers = {}
        if configured_options.mcp_servers.is_a?(Hash)
          configured_options.mcp_servers.each do |name, config|
            sdk_mcp_servers[name] = config[:instance] if config.is_a?(Hash) && config[:type] == 'sdk'
          end
        end

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
          sdk_mcp_servers: sdk_mcp_servers
        )

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
          query_handler.wait_for_result_and_end_input
        elsif prompt.is_a?(Enumerator) || prompt.respond_to?(:each)
          Async do
            query_handler.stream_input(prompt)
          end
        end

        # Read and yield messages from the query handler (filters out control messages).
        # User block is invoked through FiberBoundary so ActiveRecord / PG calls
        # inside it don't see the async gem's Fiber scheduler.
        query_handler.receive_messages do |data|
          message = MessageParser.parse(data)
          if message
            ClaudeAgentSDK.notify_observers(resolved_observers, :on_message, message)
            FiberBoundary.invoke { block.call(message) }
          end
        end
      ensure
        ClaudeAgentSDK.notify_observers(resolved_observers, :on_close)
        # query_handler.close stops the background read task and closes the transport
        if query_handler
          query_handler.close
        else
          transport.close
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
    end

    # Connect to Claude with optional initial prompt.
    #
    # Client always uses streaming mode for bidirectional communication. If you
    # pass a String, it will be sent as an initial user message after the
    # connection is established. If you pass an Enumerator, it should yield
    # JSONL messages (e.g., from ClaudeAgentSDK::Streaming.user_message).
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

      # Client always uses streaming mode; keep stdin open for bidirectional communication.
      @transport = @transport_class.new(configured_options, **@transport_args)
      @transport.connect

      # Extract SDK MCP servers
      sdk_mcp_servers = {}
      if configured_options.mcp_servers.is_a?(Hash)
        configured_options.mcp_servers.each do |name, config|
          sdk_mcp_servers[name] = config[:instance] if config.is_a?(Hash) && config[:type] == 'sdk'
        end
      end

      # Convert hooks to internal format
      hooks = convert_hooks_to_internal_format(configured_options.hooks) if configured_options.hooks

      # Extract exclude_dynamic_sections from preset system prompt for the
      # initialize request (older CLIs ignore unknown initialize fields)
      exclude_dynamic_sections = extract_exclude_dynamic_sections(configured_options.system_prompt)

      # Create Query handler
      @query_handler = Query.new(
        transport: @transport,
        is_streaming_mode: true,
        can_use_tool: configured_options.can_use_tool,
        hooks: hooks,
        sdk_mcp_servers: sdk_mcp_servers,
        agents: configured_options.agents,
        exclude_dynamic_sections: exclude_dynamic_sections
      )

      # Start query handler and initialize
      @query_handler.start
      @query_handler.initialize_protocol

      # Resolve callable observers into fresh instances (thread-safe for global defaults)
      @resolved_observers = ClaudeAgentSDK.resolve_observers(@options.observers)

      @connected = true

      # Optionally send initial prompt/messages after connection is ready.
      case prompt
      when nil
        nil
      when String
        query(prompt)
      else
        prompt.each do |message_json|
          writeln(message_json.to_s)
        end
      end
    end

    # Send a query to Claude
    # @param prompt [String] The prompt to send
    # @param session_id [String] Session identifier
    def query(prompt, session_id: 'default')
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected

      ClaudeAgentSDK.notify_observers(@resolved_observers, :on_user_prompt, prompt)
      message = {
        type: 'user',
        message: { role: 'user', content: prompt },
        parent_tool_use_id: nil,
        session_id: session_id
      }
      writeln(JSON.generate(message))
    end

    # Receive all messages from Claude
    # @yield [Message] Each message received
    def receive_messages(&block)
      return enum_for(:receive_messages) unless block

      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected

      @query_handler.receive_messages do |data|
        message = MessageParser.parse(data)
        if message
          ClaudeAgentSDK.notify_observers(@resolved_observers, :on_message, message)
          FiberBoundary.invoke { block.call(message) }
        end
      end
    end

    # Receive messages until a ResultMessage is received
    # @yield [Message] Each message received
    def receive_response(&block)
      return enum_for(:receive_response) unless block

      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected

      # Keep `break` on the same fiber as the underlying dequeue. Going through
      # Client#receive_messages would put the FiberBoundary hop above the break
      # and hang in Client mode — the CLI keeps stdin open and never emits `:end`.
      @query_handler.receive_messages do |data|
        message = MessageParser.parse(data)
        next unless message

        ClaudeAgentSDK.notify_observers(@resolved_observers, :on_message, message)
        FiberBoundary.invoke { block.call(message) }
        break if message.is_a?(ResultMessage)
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
      return unless @connected

      ClaudeAgentSDK.notify_observers(@resolved_observers || [], :on_close)
      @query_handler&.close
      @query_handler = nil
      @transport = nil
      @connected = false
    end

    private

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

    def extract_exclude_dynamic_sections(system_prompt)
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

    def writeln(string)
      write string.end_with?("\n") ? string : "#{string}\n"
    end

    def write(string)
      @transport.write(string)
    end
  end
end
