# frozen_string_literal: true

require 'json'
require 'async'
require 'async/queue'
require 'async/condition'
require 'securerandom'
require_relative 'transport'

module ClaudeAgentSDK
  # Handles bidirectional control protocol on top of Transport
  #
  # This class manages:
  # - Control request/response routing
  # - Hook callbacks
  # - Tool permission callbacks
  # - Message streaming
  # - Initialization handshake
  class Query
    attr_reader :transport, :is_streaming_mode, :sdk_mcp_servers

    def initialize(transport:, is_streaming_mode:, can_use_tool: nil, hooks: nil, sdk_mcp_servers: nil)
      @transport = transport
      @is_streaming_mode = is_streaming_mode
      @can_use_tool = can_use_tool
      @hooks = hooks || {}
      @sdk_mcp_servers = sdk_mcp_servers || {}

      # Control protocol state
      @pending_control_responses = {}
      @pending_control_results = {}
      @hook_callbacks = {}
      @hook_callback_timeouts = {}
      @next_callback_id = 0
      @request_counter = 0
      @inflight_control_request_tasks = {}

      # Message stream
      @message_queue = Async::Queue.new
      @task = nil
      @initialized = false
      @closed = false
      @initialization_result = nil
    end

    # Initialize control protocol if in streaming mode
    # @return [Hash, nil] Initialize response with supported commands, or nil if not streaming
    def initialize_protocol
      return nil unless @is_streaming_mode

      # Build hooks configuration for initialization
      hooks_config = {}
      if @hooks && !@hooks.empty?
        @hooks.each do |event, matchers|
          next if matchers.nil? || matchers.empty?

          hooks_config[event] = []
          matchers.each do |matcher|
            callback_ids = []
            (matcher[:hooks] || []).each do |callback|
              callback_id = "hook_#{@next_callback_id}"
              @next_callback_id += 1
              @hook_callbacks[callback_id] = callback
              @hook_callback_timeouts[callback_id] = matcher[:timeout] if matcher[:timeout]
              callback_ids << callback_id
            end
            hooks_config[event] << {
              matcher: matcher[:matcher],
              hookCallbackIds: callback_ids
            }
          end
        end
      end

      # Send initialize request
      request = {
        subtype: 'initialize',
        hooks: hooks_config.empty? ? nil : hooks_config
      }

      response = send_control_request(request)
      @initialized = true
      @initialization_result = response
      response
    end

    # Start reading messages from transport
    def start
      return if @task

      @task = Async do |task|
        task.async { read_messages }
      end
    end

    private

    def read_messages
      @transport.read_messages do |message|
        break if @closed

        msg_type = message[:type]

        # Route control messages
        case msg_type
        when 'control_response'
          handle_control_response(message)
        when 'control_request'
          request_id = message[:request_id]
          task = Async do
            begin
              handle_control_request(message)
            ensure
              @inflight_control_request_tasks.delete(request_id) if request_id
            end
          end
          @inflight_control_request_tasks[request_id] = task if request_id
        when 'control_cancel_request'
          request_id = message[:request_id] || message[:requestId]
          task = request_id ? @inflight_control_request_tasks[request_id] : nil
          task&.stop
          next
        else
          # Regular SDK messages go to the queue
          @message_queue.enqueue(message)
        end
      end
    rescue StandardError => e
      # Put error in queue so iterators can handle it
      @message_queue.enqueue({ type: 'error', error: e.message })
    ensure
      # Always signal end of stream
      @message_queue.enqueue({ type: 'end' })
    end

    def handle_control_response(message)
      response = message[:response] || {}
      request_id = response[:request_id]
      return unless @pending_control_responses.key?(request_id)

      if response[:subtype] == 'error'
        @pending_control_results[request_id] = StandardError.new(response[:error] || 'Unknown error')
      else
        @pending_control_results[request_id] = response
      end

      # Signal that response is ready
      @pending_control_responses[request_id].signal
    end

    def handle_control_request(request)
      request_id = request[:request_id]
      request_data = request[:request]
      subtype = request_data[:subtype]

      response_data = {}

      case subtype
      when 'can_use_tool'
        response_data = handle_permission_request(request_data)
      when 'hook_callback'
        response_data = handle_hook_callback(request_data)
      when 'mcp_message'
        response_data = handle_mcp_message(request_data)
      else
        raise "Unsupported control request subtype: #{subtype}"
      end

      # Send success response
      success_response = {
        type: 'control_response',
        response: {
          subtype: 'success',
          request_id: request_id,
          response: response_data
        }
      }
      @transport.write(JSON.generate(success_response) + "\n")
    rescue Async::Stop
      # Cancellation requested; respond with an error so the CLI can unblock.
      cancelled_response = {
        type: 'control_response',
        response: {
          subtype: 'error',
          request_id: request_id,
          error: 'Cancelled'
        }
      }
      @transport.write(JSON.generate(cancelled_response) + "\n")
    rescue StandardError => e
      # Send error response
      error_response = {
        type: 'control_response',
        response: {
          subtype: 'error',
          request_id: request_id,
          error: e.message
        }
      }
      @transport.write(JSON.generate(error_response) + "\n")
    end

    def handle_permission_request(request_data)
      raise 'canUseTool callback is not provided' unless @can_use_tool

      original_input = request_data[:input]

      context = ToolPermissionContext.new(
        signal: nil,
        suggestions: request_data[:permission_suggestions] || []
      )

      response = @can_use_tool.call(
        request_data[:tool_name],
        request_data[:input],
        context
      )

      # Convert PermissionResult to expected format
      case response
      when PermissionResultAllow
        result = {
          behavior: 'allow',
          updatedInput: response.updated_input || original_input
        }
        if response.updated_permissions
          result[:updatedPermissions] = response.updated_permissions.map(&:to_h)
        end
        result
      when PermissionResultDeny
        result = { behavior: 'deny', message: response.message }
        result[:interrupt] = response.interrupt if response.interrupt
        result
      else
        raise "Tool permission callback must return PermissionResult, got #{response.class}"
      end
    end

    def handle_hook_callback(request_data)
      callback_id = request_data[:callback_id]
      callback = @hook_callbacks[callback_id]
      raise "No hook callback found for ID: #{callback_id}" unless callback

      # Parse input data into typed HookInput object
      input_data = request_data[:input] || {}
      hook_input = parse_hook_input(input_data)

      # Create typed HookContext
      context = HookContext.new(signal: nil)

      hook_output = callback.call(
        hook_input,
        request_data[:tool_use_id],
        context
      ) unless @hook_callback_timeouts[callback_id]

      if (timeout = @hook_callback_timeouts[callback_id])
        hook_output = Async::Task.current.with_timeout(timeout) do
          callback.call(
            hook_input,
            request_data[:tool_use_id],
            context
          )
        end
      end

      # Convert Ruby-safe field names to CLI-expected names
      convert_hook_output_for_cli(hook_output)
    end

    def parse_hook_input(input_data)
      event_name = input_data[:hook_event_name] || input_data['hook_event_name']
      fetch = ->(key) { input_data[key] || input_data[key.to_s] }
      base_args = {
        session_id: fetch.call(:session_id),
        transcript_path: fetch.call(:transcript_path),
        cwd: fetch.call(:cwd),
        permission_mode: fetch.call(:permission_mode)
      }

      case event_name
      when 'PreToolUse'
        PreToolUseHookInput.new(
          tool_name: fetch.call(:tool_name),
          tool_input: fetch.call(:tool_input),
          **base_args
        )
      when 'PostToolUse'
        PostToolUseHookInput.new(
          tool_name: fetch.call(:tool_name),
          tool_input: fetch.call(:tool_input),
          tool_response: fetch.call(:tool_response),
          **base_args
        )
      when 'PostToolUseFailure'
        PostToolUseFailureHookInput.new(
          tool_name: fetch.call(:tool_name),
          tool_input: fetch.call(:tool_input),
          tool_use_id: fetch.call(:tool_use_id),
          error: fetch.call(:error),
          is_interrupt: fetch.call(:is_interrupt),
          **base_args
        )
      when 'UserPromptSubmit'
        UserPromptSubmitHookInput.new(
          prompt: fetch.call(:prompt),
          **base_args
        )
      when 'Stop'
        StopHookInput.new(
          stop_hook_active: fetch.call(:stop_hook_active),
          **base_args
        )
      when 'SubagentStop'
        SubagentStopHookInput.new(
          stop_hook_active: fetch.call(:stop_hook_active),
          agent_id: fetch.call(:agent_id),
          agent_transcript_path: fetch.call(:agent_transcript_path),
          agent_type: fetch.call(:agent_type),
          **base_args
        )
      when 'Notification'
        NotificationHookInput.new(
          message: fetch.call(:message),
          title: fetch.call(:title),
          notification_type: fetch.call(:notification_type),
          **base_args
        )
      when 'SubagentStart'
        SubagentStartHookInput.new(
          agent_id: fetch.call(:agent_id),
          agent_type: fetch.call(:agent_type),
          **base_args
        )
      when 'PermissionRequest'
        PermissionRequestHookInput.new(
          tool_name: fetch.call(:tool_name),
          tool_input: fetch.call(:tool_input),
          permission_suggestions: fetch.call(:permission_suggestions),
          **base_args
        )
      when 'PreCompact'
        PreCompactHookInput.new(
          trigger: fetch.call(:trigger),
          custom_instructions: fetch.call(:custom_instructions),
          **base_args
        )
      else
        # Return base input for unknown event types
        BaseHookInput.new(**base_args)
      end
    end

    def handle_mcp_message(request_data)
      server_name = request_data[:server_name]
      mcp_message = request_data[:message]

      raise 'Missing server_name or message for MCP request' unless server_name && mcp_message

      mcp_response = handle_sdk_mcp_request(server_name, mcp_message)
      { mcp_response: mcp_response }
    end

    def convert_hook_output_for_cli(hook_output)
      # Handle typed output objects
      if hook_output.respond_to?(:to_h) && !hook_output.is_a?(Hash)
        return hook_output.to_h
      end

      return {} unless hook_output.is_a?(Hash)

      # Convert Ruby hash with symbol keys to CLI format
      # Handle special keywords that might be Ruby-safe versions
      converted = {}
      hook_output.each do |key, value|
        converted_key = case key
                        when :async_, 'async_' then 'async'
                        when :continue_, 'continue_' then 'continue'
                        when :hook_specific_output then 'hookSpecificOutput'
                        when :suppress_output then 'suppressOutput'
                        when :stop_reason then 'stopReason'
                        when :system_message then 'systemMessage'
                        when :async_timeout then 'asyncTimeout'
                        else key.to_s
                        end

        # Recursively convert nested objects
        converted_value = if value.respond_to?(:to_h) && !value.is_a?(Hash)
                            value.to_h
                          else
                            value
                          end
        converted[converted_key] = converted_value
      end
      converted
    end

    def send_control_request(request)
      raise 'Control requests require streaming mode' unless @is_streaming_mode

      # Generate unique request ID
      @request_counter += 1
      request_id = "req_#{@request_counter}_#{SecureRandom.hex(4)}"

      # Create condition for response
      condition = Async::Condition.new
      @pending_control_responses[request_id] = condition

      # Build and send request
      control_request = {
        type: 'control_request',
        request_id: request_id,
        request: request
      }

      @transport.write(JSON.generate(control_request) + "\n")

      # Wait for response with timeout
      Async do |task|
        task.with_timeout(60.0) do
          condition.wait
        end

        result = @pending_control_results.delete(request_id)
        @pending_control_responses.delete(request_id)

        raise result if result.is_a?(Exception)

        result[:response] || {}
      end.wait
    rescue Async::TimeoutError
      @pending_control_responses.delete(request_id)
      @pending_control_results.delete(request_id)
      raise "Control request timeout: #{request[:subtype]}"
    end

    def handle_sdk_mcp_request(server_name, message)
      # Convert server_name to symbol if needed for hash lookup
      server_key = @sdk_mcp_servers.key?(server_name) ? server_name : server_name.to_sym

      unless @sdk_mcp_servers.key?(server_key)
        return {
          jsonrpc: '2.0',
          id: message[:id],
          error: {
            code: -32601,
            message: "Server '#{server_name}' not found"
          }
        }
      end

      server = @sdk_mcp_servers[server_key]
      method = message[:method]
      params = message[:params] || {}

      case method
      when 'initialize'
        handle_mcp_initialize(server, message)
      when 'tools/list'
        handle_mcp_tools_list(server, message)
      when 'tools/call'
        handle_mcp_tools_call(server, message, params)
      when 'resources/list'
        handle_mcp_resources_list(server, message)
      when 'resources/read'
        handle_mcp_resources_read(server, message, params)
      when 'prompts/list'
        handle_mcp_prompts_list(server, message)
      when 'prompts/get'
        handle_mcp_prompts_get(server, message, params)
      when 'notifications/initialized'
        { jsonrpc: '2.0', result: {} }
      else
        {
          jsonrpc: '2.0',
          id: message[:id],
          error: { code: -32601, message: "Method '#{method}' not found" }
        }
      end
    rescue StandardError => e
      {
        jsonrpc: '2.0',
        id: message[:id],
        error: { code: -32603, message: e.message }
      }
    end

    def handle_mcp_initialize(server, message)
      capabilities = {}
      capabilities[:tools] = {} if server.tools && !server.tools.empty?
      capabilities[:resources] = {} if server.resources && !server.resources.empty?
      capabilities[:prompts] = {} if server.prompts && !server.prompts.empty?

      {
        jsonrpc: '2.0',
        id: message[:id],
        result: {
          protocolVersion: '2024-11-05',
          capabilities: capabilities,
          serverInfo: {
            name: server.name,
            version: server.version || '1.0.0'
          }
        }
      }
    end

    def handle_mcp_tools_list(server, message)
      # List tools from the SDK MCP server
      tools_data = server.list_tools
      {
        jsonrpc: '2.0',
        id: message[:id],
        result: { tools: tools_data }
      }
    end

    def handle_mcp_tools_call(server, message, params)
      # Execute tool on the SDK MCP server
      tool_name = params[:name]
      arguments = params[:arguments] || {}

      # Call the tool
      result = server.call_tool(tool_name, arguments)

      # Format response
      content = []
      if result[:content]
        result[:content].each do |item|
          if item[:type] == 'text'
            content << { type: 'text', text: item[:text] }
          end
        end
      end

      response_data = { content: content }
      response_data[:is_error] = true if result[:is_error]

      {
        jsonrpc: '2.0',
        id: message[:id],
        result: response_data
      }
    end

    def handle_mcp_resources_list(server, message)
      # List resources from the SDK MCP server
      resources_data = server.list_resources
      {
        jsonrpc: '2.0',
        id: message[:id],
        result: { resources: resources_data }
      }
    end

    def handle_mcp_resources_read(server, message, params)
      # Read a resource from the SDK MCP server
      uri = params[:uri]
      raise 'Missing uri parameter for resources/read' unless uri

      # Read the resource
      result = server.read_resource(uri)

      {
        jsonrpc: '2.0',
        id: message[:id],
        result: result
      }
    end

    def handle_mcp_prompts_list(server, message)
      # List prompts from the SDK MCP server
      prompts_data = server.list_prompts
      {
        jsonrpc: '2.0',
        id: message[:id],
        result: { prompts: prompts_data }
      }
    end

    def handle_mcp_prompts_get(server, message, params)
      # Get a prompt from the SDK MCP server
      name = params[:name]
      raise 'Missing name parameter for prompts/get' unless name

      arguments = params[:arguments] || {}

      # Get the prompt
      result = server.get_prompt(name, arguments)

      {
        jsonrpc: '2.0',
        id: message[:id],
        result: result
      }
    end

    public

    # Get current MCP server connection status (only works with streaming mode)
    # @return [Hash] MCP status information, including mcpServers list
    def get_mcp_status
      send_control_request({ subtype: 'mcp_status' })
    end

    # Send interrupt control request
    def interrupt
      send_control_request({ subtype: 'interrupt' })
    end

    # Change permission mode
    def set_permission_mode(mode)
      send_control_request({
                             subtype: 'set_permission_mode',
                             mode: mode
                           })
    end

    # Change the AI model
    def set_model(model)
      send_control_request({
                             subtype: 'set_model',
                             model: model
                           })
    end

    # Rewind files to a previous checkpoint (v0.1.15+)
    # Restores file state to what it was at the given user message
    # Requires enable_file_checkpointing to be true in options
    # @param user_message_uuid [String] The UUID of the UserMessage to rewind to
    def rewind_files(user_message_uuid)
      send_control_request({
                             subtype: 'rewind_files',
                             userMessageUuid: user_message_uuid
                           })
    end

    # Stream input messages to transport
    def stream_input(stream)
      stream.each do |message|
        break if @closed
        @transport.write(JSON.generate(message) + "\n")
      end
      @transport.end_input
    rescue StandardError => e
      # Log error but don't raise
      warn "Error streaming input: #{e.message}"
    end

    # Receive SDK messages (not control messages)
    def receive_messages(&block)
      return enum_for(:receive_messages) unless block

      loop do
        message = @message_queue.dequeue
        break if message[:type] == 'end'
        raise message[:error] if message[:type] == 'error'

        block.call(message)
      end
    end

    # Close the query and transport
    def close
      @closed = true
      @task&.stop
      @transport.close
    end
  end
end
