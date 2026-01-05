# frozen_string_literal: true

require_relative 'claude_agent_sdk/version'
require_relative 'claude_agent_sdk/errors'
require_relative 'claude_agent_sdk/types'
require_relative 'claude_agent_sdk/transport'
require_relative 'claude_agent_sdk/subprocess_cli_transport'
require_relative 'claude_agent_sdk/message_parser'
require_relative 'claude_agent_sdk/query'
require_relative 'claude_agent_sdk/sdk_mcp_server'
require_relative 'claude_agent_sdk/streaming'
require 'async'
require 'securerandom'

# Claude Agent SDK for Ruby
module ClaudeAgentSDK
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
  #     if msg.is_a?(ClaudeAgentSDK::AssistantMessage)
  #       msg.content.each do |block|
  #         puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
  #       end
  #     end
  #   end
  #
  # @example Streaming input
  #   messages = Streaming.from_array(['Hello', 'What is 2+2?', 'Thanks!'])
  #   ClaudeAgentSDK.query(prompt: messages) do |message|
  #     puts message
  #   end
  def self.query(prompt:, options: nil, &block)
    return enum_for(:query, prompt: prompt, options: options) unless block

    options ||= ClaudeAgentOptions.new
    ENV['CLAUDE_CODE_ENTRYPOINT'] = 'sdk-rb'

    Async do
      transport = SubprocessCLITransport.new(prompt, options)
      begin
        transport.connect

        # If prompt is an Enumerator, write each message to stdin
        if prompt.is_a?(Enumerator) || prompt.respond_to?(:each)
          Async do
            begin
              prompt.each do |message_json|
                transport.write(message_json)
              end
            ensure
              transport.end_input
            end
          end
        end

        # Read and yield messages
        transport.read_messages do |data|
          message = MessageParser.parse(data)
          block.call(message)
        end
      ensure
        transport.close
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

    def initialize(options: nil)
      @options = options || ClaudeAgentOptions.new
      @transport = nil
      @query_handler = nil
      @connected = false
      ENV['CLAUDE_CODE_ENTRYPOINT'] = 'sdk-rb-client'
    end

    # Connect to Claude with optional initial prompt
    # @param prompt [String, Enumerator, nil] Initial prompt or message stream
    def connect(prompt = nil)
      return if @connected

      # Validate and configure permission settings
      configured_options = @options
      if @options.can_use_tool
        # can_use_tool requires streaming mode
        if prompt.is_a?(String)
          raise ArgumentError, 'can_use_tool callback requires streaming mode'
        end

        # can_use_tool and permission_prompt_tool_name are mutually exclusive
        if @options.permission_prompt_tool_name
          raise ArgumentError, 'can_use_tool callback cannot be used with permission_prompt_tool_name'
        end

        # Set permission_prompt_tool_name to stdio for control protocol
        configured_options = @options.dup_with(permission_prompt_tool_name: 'stdio')
      end

      # Auto-connect with empty enumerator if no prompt is provided
      # This matches the Python SDK pattern where ClaudeSDKClient always uses streaming mode
      # An empty enumerator keeps stdin open for bidirectional communication
      actual_prompt = prompt || [].to_enum
      @transport = SubprocessCLITransport.new(actual_prompt, configured_options)
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

      # Create Query handler
      @query_handler = Query.new(
        transport: @transport,
        is_streaming_mode: true,
        can_use_tool: configured_options.can_use_tool,
        hooks: hooks,
        sdk_mcp_servers: sdk_mcp_servers
      )

      # Start query handler and initialize
      @query_handler.start
      @query_handler.initialize_protocol

      @connected = true
    end

    # Send a query to Claude
    # @param prompt [String] The prompt to send
    # @param session_id [String] Session identifier
    def query(prompt, session_id: 'default')
      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected

      message = {
        type: 'user',
        message: { role: 'user', content: prompt },
        parent_tool_use_id: nil,
        session_id: session_id
      }
      @transport.write(JSON.generate(message) + "\n")
    end

    # Receive all messages from Claude
    # @yield [Message] Each message received
    def receive_messages(&block)
      return enum_for(:receive_messages) unless block

      raise CLIConnectionError, 'Not connected. Call connect() first' unless @connected

      @query_handler.receive_messages do |data|
        message = MessageParser.parse(data)
        block.call(message)
      end
    end

    # Receive messages until a ResultMessage is received
    # @yield [Message] Each message received
    def receive_response(&block)
      return enum_for(:receive_response) unless block

      receive_messages do |message|
        block.call(message)
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

    # Disconnect from Claude
    def disconnect
      return unless @connected

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
          internal_hooks[event.to_s] << {
            matcher: matcher.matcher,
            hooks: matcher.hooks
          }
        end
      end
      internal_hooks
    end
  end
end
