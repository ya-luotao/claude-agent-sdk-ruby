# frozen_string_literal: true

require 'json'
require 'async'
require 'async/queue'
require 'async/condition'
require 'securerandom'
require_relative 'transport'
require_relative 'errors'

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

    CONTROL_REQUEST_TIMEOUT_ENV_VAR = 'CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS'
    DEFAULT_CONTROL_REQUEST_TIMEOUT_SECONDS = 1200.0
    STREAM_CLOSE_TIMEOUT_ENV_VAR = 'CLAUDE_CODE_STREAM_CLOSE_TIMEOUT'
    DEFAULT_STREAM_CLOSE_TIMEOUT_SECONDS = 60.0

    def initialize(transport:, is_streaming_mode:, can_use_tool: nil, hooks: nil, sdk_mcp_servers: nil, agents: nil,
                   exclude_dynamic_sections: nil)
      @transport = transport
      @is_streaming_mode = is_streaming_mode
      @can_use_tool = can_use_tool
      @hooks = hooks || {}
      @sdk_mcp_servers = sdk_mcp_servers || {}
      @agents = agents
      @exclude_dynamic_sections = exclude_dynamic_sections

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
      @first_result_received = false
      @first_result_condition = Async::Condition.new
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

      # Build agents dict for initialization
      agents_dict = nil
      if @agents
        agents_dict = @agents.transform_values do |agent_def|
          {
            description: agent_def.description,
            prompt: agent_def.prompt,
            tools: agent_def.tools,
            disallowedTools: agent_def.disallowed_tools,
            model: agent_def.model,
            skills: agent_def.skills,
            memory: agent_def.memory,
            mcpServers: agent_def.mcp_servers,
            initialPrompt: agent_def.initial_prompt,
            maxTurns: agent_def.max_turns,
            background: agent_def.background,
            effort: agent_def.effort,
            permissionMode: agent_def.permission_mode
          }.compact
        end
      end

      # Send initialize request
      request = {
        subtype: 'initialize',
        hooks: hooks_config.empty? ? nil : hooks_config,
        agents: agents_dict
      }
      request[:excludeDynamicSections] = @exclude_dynamic_sections unless @exclude_dynamic_sections.nil?

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

    def control_request_timeout_seconds
      raw_value = ENV.fetch(CONTROL_REQUEST_TIMEOUT_ENV_VAR, nil)
      return DEFAULT_CONTROL_REQUEST_TIMEOUT_SECONDS if raw_value.nil? || raw_value.strip.empty?

      value = Float(raw_value)
      value.positive? ? value : DEFAULT_CONTROL_REQUEST_TIMEOUT_SECONDS
    rescue ArgumentError
      DEFAULT_CONTROL_REQUEST_TIMEOUT_SECONDS
    end

    def stream_close_timeout_seconds
      raw_value = ENV.fetch(STREAM_CLOSE_TIMEOUT_ENV_VAR, nil)
      return DEFAULT_STREAM_CLOSE_TIMEOUT_SECONDS if raw_value.nil? || raw_value.strip.empty?

      value = Float(raw_value) / 1000.0
      value.positive? ? value : DEFAULT_STREAM_CLOSE_TIMEOUT_SECONDS
    rescue ArgumentError
      DEFAULT_STREAM_CLOSE_TIMEOUT_SECONDS
    end

    def read_messages
      @transport.read_messages do |message|
        break if @closed

        msg_type = message[:type]

        # Route control messages
        case msg_type
        when 'control_response'
          handle_control_response(message)
        when 'control_request'
          request_id = message[:request_id] || message[:requestId]
          # Spawn as a child of the current task so @task.stop cascades and
          # nothing keeps running after close; bare Async do may root at the
          # reactor and leak past shutdown.
          handler_task = Async::Task.current.async do
            begin
              handle_control_request(message)
            ensure
              @inflight_control_request_tasks.delete(request_id) if request_id
            end
          end
          @inflight_control_request_tasks[request_id] = handler_task if request_id
        when 'control_cancel_request'
          request_id = message[:request_id] || message[:requestId]
          task = request_id ? @inflight_control_request_tasks[request_id] : nil
          task&.stop
          next
        else
          if message[:type] == 'result' && !@first_result_received
            @first_result_received = true
            @first_result_condition.signal
          end
          # Regular SDK messages go to the queue
          @message_queue.enqueue(message)
        end
      end
    rescue ProcessError => e
      # The CLI can exit non-zero after delivering a valid result (e.g.,
      # StructuredOutput tool_use triggers exit code 1). When we already
      # received a result message, treat the process error as non-fatal.
      if @first_result_received
        warn "Claude SDK: Process exited with code #{e.exit_code} after result — ignoring"
      else
        @pending_control_responses.dup.each do |request_id, condition|
          @pending_control_results[request_id] ||= e
          condition.signal
        end
        @message_queue.enqueue({ type: 'error', error: e })
      end
    rescue StandardError => e
      # Unblock pending control requests (e.g., initialize) so callers don't hang until timeout.
      @pending_control_responses.dup.each do |request_id, condition|
        @pending_control_results[request_id] ||= e
        condition.signal
      end

      # Put error in queue so iterators can handle it
      @message_queue.enqueue({ type: 'error', error: e })
    ensure
      unless @first_result_received
        @first_result_received = true
        @first_result_condition.signal
      end
      # Always signal end of stream
      @message_queue.enqueue({ type: 'end' })
    end

    def handle_control_response(message)
      response = message[:response] || {}
      request_id = response[:request_id] || response[:requestId] || message[:request_id] || message[:requestId]
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
      request_id = request[:request_id] || request[:requestId]
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
          requestId: request_id,
          response: response_data
        }
      }
      writeln(JSON.generate(success_response))
    rescue Async::Stop
      # Cancellation requested; respond with an error so the CLI can unblock.
      cancelled_response = {
        type: 'control_response',
        response: {
          subtype: 'error',
          request_id: request_id,
          requestId: request_id,
          error: 'Cancelled'
        }
      }
      writeln(JSON.generate(cancelled_response))
    rescue StandardError => e
      # Send error response
      error_response = {
        type: 'control_response',
        response: {
          subtype: 'error',
          request_id: request_id,
          requestId: request_id,
          error: e.message
        }
      }
      writeln(JSON.generate(error_response))
    end

    def handle_permission_request(request_data)
      raise 'canUseTool callback is not provided' unless @can_use_tool

      original_input = request_data[:input]

      context = ToolPermissionContext.new(
        signal: nil,
        suggestions: request_data[:permission_suggestions] || [],
        tool_use_id: request_data[:tool_use_id],
        agent_id: request_data[:agent_id]
      )

      # User-supplied permission callback runs on a plain thread, not the
      # Async reactor, so AR/PG calls inside it aren't intercepted.
      response = FiberBoundary.invoke do
        @can_use_tool.call(request_data[:tool_name], request_data[:input], context)
      end

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

      # Hop off the Fiber scheduler before invoking user hook code. The
      # Async-side timeout still wraps the hop; if it fires, .value returns
      # early with an exception and the worker thread is left to finish on
      # its own (matches prior best-effort cancellation semantics).
      unless @hook_callback_timeouts[callback_id]
        hook_output = FiberBoundary.invoke do
          callback.call(hook_input, request_data[:tool_use_id], context)
        end
      end

      if (timeout = @hook_callback_timeouts[callback_id])
        hook_output = Async::Task.current.with_timeout(timeout) do
          FiberBoundary.invoke do
            callback.call(hook_input, request_data[:tool_use_id], context)
          end
        end
      end

      # Convert Ruby-safe field names to CLI-expected names
      convert_hook_output_for_cli(hook_output)
    end

    def parse_hook_input(input_data)
      event_name = input_data[:hook_event_name] || input_data['hook_event_name']
      fetch = lambda do |key|
        if input_data.key?(key)
          input_data[key]
        elsif input_data.key?(key.to_s)
          input_data[key.to_s]
        end
      end
      base_args = {
        session_id: fetch.call(:session_id),
        transcript_path: fetch.call(:transcript_path),
        cwd: fetch.call(:cwd),
        permission_mode: fetch.call(:permission_mode)
      }

      # Subagent context fields shared by tool-lifecycle hooks
      subagent_args = {
        agent_id: fetch.call(:agent_id),
        agent_type: fetch.call(:agent_type)
      }

      case event_name
      when 'PreToolUse'
        PreToolUseHookInput.new(
          tool_name: fetch.call(:tool_name),
          tool_input: fetch.call(:tool_input),
          tool_use_id: fetch.call(:tool_use_id),
          **subagent_args, **base_args
        )
      when 'PostToolUse'
        PostToolUseHookInput.new(
          tool_name: fetch.call(:tool_name),
          tool_input: fetch.call(:tool_input),
          tool_response: fetch.call(:tool_response),
          tool_use_id: fetch.call(:tool_use_id),
          **subagent_args, **base_args
        )
      when 'PostToolUseFailure'
        PostToolUseFailureHookInput.new(
          tool_name: fetch.call(:tool_name),
          tool_input: fetch.call(:tool_input),
          tool_use_id: fetch.call(:tool_use_id),
          error: fetch.call(:error),
          is_interrupt: fetch.call(:is_interrupt),
          **subagent_args, **base_args
        )
      when 'UserPromptSubmit'
        UserPromptSubmitHookInput.new(
          prompt: fetch.call(:prompt),
          **base_args
        )
      when 'Stop'
        StopHookInput.new(
          stop_hook_active: fetch.call(:stop_hook_active),
          last_assistant_message: fetch.call(:last_assistant_message),
          **base_args
        )
      when 'SubagentStop'
        SubagentStopHookInput.new(
          stop_hook_active: fetch.call(:stop_hook_active),
          agent_id: fetch.call(:agent_id),
          agent_transcript_path: fetch.call(:agent_transcript_path),
          agent_type: fetch.call(:agent_type),
          last_assistant_message: fetch.call(:last_assistant_message),
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
          **subagent_args, **base_args
        )
      when 'PreCompact'
        PreCompactHookInput.new(
          trigger: fetch.call(:trigger),
          custom_instructions: fetch.call(:custom_instructions),
          **base_args
        )
      when 'SessionStart'
        SessionStartHookInput.new(
          source: fetch.call(:source),
          agent_type: fetch.call(:agent_type),
          model: fetch.call(:model),
          **base_args
        )
      when 'SessionEnd'
        SessionEndHookInput.new(
          reason: fetch.call(:reason),
          **base_args
        )
      when 'Setup'
        SetupHookInput.new(
          trigger: fetch.call(:trigger),
          **base_args
        )
      when 'TeammateIdle'
        TeammateIdleHookInput.new(
          teammate_name: fetch.call(:teammate_name),
          team_name: fetch.call(:team_name),
          **base_args
        )
      when 'TaskCompleted'
        TaskCompletedHookInput.new(
          task_id: fetch.call(:task_id),
          task_subject: fetch.call(:task_subject),
          task_description: fetch.call(:task_description),
          teammate_name: fetch.call(:teammate_name),
          team_name: fetch.call(:team_name),
          **base_args
        )
      when 'ConfigChange'
        ConfigChangeHookInput.new(
          source: fetch.call(:source),
          file_path: fetch.call(:file_path),
          **base_args
        )
      when 'WorktreeCreate'
        WorktreeCreateHookInput.new(
          name: fetch.call(:name),
          **base_args
        )
      when 'WorktreeRemove'
        WorktreeRemoveHookInput.new(
          worktree_path: fetch.call(:worktree_path),
          **base_args
        )
      when 'StopFailure'
        StopFailureHookInput.new(
          error: fetch.call(:error),
          error_details: fetch.call(:error_details),
          last_assistant_message: fetch.call(:last_assistant_message),
          **base_args
        )
      when 'PostCompact'
        PostCompactHookInput.new(
          trigger: fetch.call(:trigger),
          compact_summary: fetch.call(:compact_summary),
          **base_args
        )
      when 'PermissionDenied'
        PermissionDeniedHookInput.new(
          tool_name: fetch.call(:tool_name),
          tool_input: fetch.call(:tool_input),
          tool_use_id: fetch.call(:tool_use_id),
          reason: fetch.call(:reason),
          **subagent_args, **base_args
        )
      when 'TaskCreated'
        TaskCreatedHookInput.new(
          task_id: fetch.call(:task_id),
          task_subject: fetch.call(:task_subject),
          task_description: fetch.call(:task_description),
          teammate_name: fetch.call(:teammate_name),
          team_name: fetch.call(:team_name),
          **base_args
        )
      when 'Elicitation'
        ElicitationHookInput.new(
          mcp_server_name: fetch.call(:mcp_server_name),
          message: fetch.call(:message),
          mode: fetch.call(:mode),
          url: fetch.call(:url),
          elicitation_id: fetch.call(:elicitation_id),
          requested_schema: fetch.call(:requested_schema),
          **base_args
        )
      when 'ElicitationResult'
        ElicitationResultHookInput.new(
          mcp_server_name: fetch.call(:mcp_server_name),
          elicitation_id: fetch.call(:elicitation_id),
          mode: fetch.call(:mode),
          action: fetch.call(:action),
          content: fetch.call(:content),
          **base_args
        )
      when 'InstructionsLoaded'
        InstructionsLoadedHookInput.new(
          file_path: fetch.call(:file_path),
          memory_type: fetch.call(:memory_type),
          load_reason: fetch.call(:load_reason),
          globs: fetch.call(:globs),
          trigger_file_path: fetch.call(:trigger_file_path),
          **base_args
        )
      when 'CwdChanged'
        CwdChangedHookInput.new(
          old_cwd: fetch.call(:old_cwd),
          new_cwd: fetch.call(:new_cwd),
          **base_args
        )
      when 'FileChanged'
        FileChangedHookInput.new(
          file_path: fetch.call(:file_path),
          event: fetch.call(:event),
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

      timeout_seconds = control_request_timeout_seconds

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
        requestId: request_id,
        request: request
      }

      writeln(JSON.generate(control_request))

      # Wait for response with timeout (default 1200s to handle slow CLI startup)
      Async do |task|
        task.with_timeout(timeout_seconds) do
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
      raise ControlRequestTimeoutError, "Control request timeout: #{request[:subtype]}"
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
      content = ClaudeAgentSDK.flexible_fetch(result, 'content', 'content') || []
      response_data = { content: content }

      is_error = ClaudeAgentSDK.flexible_fetch(result, 'isError', 'is_error')
      response_data[:isError] = !!is_error unless is_error.nil?

      structured_content = ClaudeAgentSDK.flexible_fetch(result, 'structuredContent', 'structured_content')
      response_data[:structuredContent] = structured_content unless structured_content.nil?

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

    # Get a breakdown of current context window usage by category.
    # @return [Hash] Context usage response with categories, totalTokens, maxTokens, etc.
    def get_context_usage
      send_control_request({ subtype: 'get_context_usage' })
    end

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

    # Reconnect a failed MCP server
    # @param server_name [String] Name of the MCP server to reconnect
    def reconnect_mcp_server(server_name)
      send_control_request({
                             subtype: 'mcp_reconnect',
                             serverName: server_name
                           })
    end

    # Enable or disable an MCP server
    # @param server_name [String] Name of the MCP server
    # @param enabled [Boolean] Whether to enable or disable
    def toggle_mcp_server(server_name, enabled)
      send_control_request({
                             subtype: 'mcp_toggle',
                             serverName: server_name,
                             enabled: enabled
                           })
    end

    # Stop a running background task
    # @param task_id [String] The ID of the task to stop
    def stop_task(task_id)
      send_control_request({
                             subtype: 'stop_task',
                             task_id: task_id
                           })
    end

    # Rewind files to a previous checkpoint (v0.1.15+)
    # Restores file state to what it was at the given user message
    # Requires enable_file_checkpointing to be true in options
    # @param user_message_uuid [String] The UUID of the UserMessage to rewind to
    def rewind_files(user_message_uuid)
      send_control_request({
                             subtype: 'rewind_files',
                             user_message_id: user_message_uuid
                           })
    end

    # Wait for the first result before closing stdin when hooks or SDK MCP
    # servers may still need to exchange control messages with the CLI.
    def wait_for_result_and_end_input
      if !@first_result_received &&
         ((@sdk_mcp_servers && !@sdk_mcp_servers.empty?) || (@hooks && !@hooks.empty?))
        Async::Task.current.with_timeout(stream_close_timeout_seconds) do
          @first_result_condition.wait unless @first_result_received
        end
      end
    rescue Async::TimeoutError
      nil
    ensure
      @transport.end_input
    end

    # Stream input messages to transport
    def stream_input(stream)
      stream.each do |message|
        break if @closed
        serialized = message.is_a?(Hash) ? JSON.generate(message) : message.to_s
        writeln(serialized)
      end
    rescue StandardError => e
      # Log error but don't raise
      warn "Error streaming input: #{e.message}"
    ensure
      wait_for_result_and_end_input
    end

    def writeln(string)
      write string.end_with?("\n") ? string : "#{string}\n"
    end

    def write(string)
      @transport.write(string)
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
