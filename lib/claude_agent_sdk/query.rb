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

    # Waiter for control responses awaited OFF the reactor — i.e. a control
    # method called from inside a hook/can_use_tool/SDK-MCP callback, which
    # runs on a FiberBoundary worker thread (Python supports this reentrancy
    # natively: callbacks are event-loop tasks and anyio.Event is
    # level-triggered). Duck-types Async::Condition#signal for the read
    # loop's signal sites; the unconditional token push makes it
    # level-triggered, closing the check-then-wait gap that an
    # edge-triggered Condition would lose across threads.
    class ThreadWaiter
      def initialize
        @queue = ::Queue.new
      end

      def signal(_value = nil)
        @queue << true
      end

      def wait(timeout)
        @queue.pop(timeout: timeout)
      end
    end

    def initialize(transport:, is_streaming_mode:, can_use_tool: nil, hooks: nil, sdk_mcp_servers: nil, agents: nil,
                   exclude_dynamic_sections: nil, skills: nil)
      @transport = transport
      @is_streaming_mode = is_streaming_mode
      @can_use_tool = can_use_tool
      @hooks = hooks || {}
      @sdk_mcp_servers = sdk_mcp_servers || {}
      @agents = agents
      @exclude_dynamic_sections = exclude_dynamic_sections
      @skills = skills

      # Control protocol state
      @pending_control_responses = {}
      @pending_control_results = {}
      @hook_callbacks = {}
      @hook_callback_timeouts = {}
      @next_callback_id = 0
      @request_counter = 0
      @request_counter_mutex = Mutex.new
      @inflight_control_request_tasks = {}

      # Message stream
      @message_queue = Async::Queue.new
      @first_result_received = false
      @last_error_result_text = nil
      @first_result_condition = Async::Condition.new
      @task = nil
      @child_tasks = []
      @initialized = false
      @closed = false
      @initialization_result = nil
      @transcript_mirror_batcher = nil
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
            matcher_config = {
              matcher: matcher[:matcher],
              hookCallbackIds: callback_ids
            }
            # Wire field is literal "timeout" in SECONDS, per matcher,
            # omitted when absent (Python _internal/query.py parity — no
            # camelCase, no ms conversion). Local enforcement via
            # @hook_callback_timeouts stays as defense-in-depth for CLIs
            # that ignore the field.
            matcher_config[:timeout] = matcher[:timeout] if matcher[:timeout]
            hooks_config[event] << matcher_config
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
      # 'all' and omitted are equivalent at the wire level (no filter), so
      # only send the field when it's an explicit list (mirrors Python).
      request[:skills] = @skills if @skills.is_a?(Array)

      response = send_control_request(request)
      @initialized = true
      @initialization_result = response
      response
    end

    # Start reading messages from transport.
    #
    # Spawns `read_messages` as a direct child task of the current Async
    # task and stores that child in `@task`. An earlier version wrapped
    # `task.async { read_messages }` inside an outer `Async do ... end` and
    # assigned the outer task to `@task`; the outer task completed almost
    # immediately after spawning, so `close`'s `@task.stop` never reached
    # the actual `read_messages` fiber and the read loop kept running
    # until the transport raised. Now `@task.stop` stops the read loop.
    #
    # Must be called inside an Async{} block (matches `query()` which wraps
    # its own internals in Async, and the documented `Client#connect`
    # pattern). If invoked outside a reactor, raise a clear error rather
    # than letting Async::Task.current raise an opaque "No async task
    # available!" — earlier versions of this method *appeared* to work
    # from synchronous callers but actually hung indefinitely because the
    # outer Async{} root task waited for read_messages to finish, which
    # never happens for a live Client.
    def start
      return if @task

      parent = Async::Task.current?
      raise CLIConnectionError, 'Query#start must be called inside an Async{} block (e.g. wrap Client#connect in Async{...})' unless parent

      @task = parent.async { read_messages }
    end

    # Spawn a child task that is stopped by #close (mirrors the Python SDK's
    # Query#spawn_task / _child_tasks). Used for background input streaming so
    # a dying read loop or #close can never strand the stream task and hang
    # the enclosing Async reactor.
    #
    # NOTE: intentionally a partial mirror — Python prunes completed tasks via
    # add_done_callback(_child_tasks.discard); here entries live until #close.
    # Fine for the current one-shot call sites (max two tasks per Query); do
    # not route per-request work (control handlers, per-turn streams) through
    # this without adding completion-based removal.
    def spawn_task(&block)
      parent = Async::Task.current?
      raise CLIConnectionError, 'Query#spawn_task must be called inside an Async{} block' unless parent

      task = parent.async(&block)
      @child_tasks << task
      task
    end

    # Install the transcript-mirror batcher fed by `transcript_mirror` frames
    # (Client mode with a session_store). nil disables mirroring.
    def set_transcript_mirror_batcher(batcher)
      @transcript_mirror_batcher = batcher
    end

    # Synthesize a `mirror_error` system message and put it on the SDK message
    # stream so consumers learn a mirror batch was dropped after exhausting
    # retries. Non-blocking: the message queue is unbounded, so unlike the
    # Python SDK there is no buffer-full drop path.
    def report_mirror_error(key, error)
      session_id = key && (key['session_id'] || key[:session_id])
      @message_queue.enqueue(
        type: 'system',
        subtype: 'mirror_error',
        error: error,
        key: key,
        uuid: SecureRandom.uuid,
        session_id: session_id || ''
      )
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
        when 'transcript_mirror'
          # session_store mirror frame — fed to the batcher, never surfaced to
          # consumers. camelCase on the wire; transport symbolizes keys.
          @transcript_mirror_batcher&.enqueue(message[:filePath] || message[:file_path], message[:entries] || [])
          next
        else
          if message[:type] == 'result'
            # Flush the mirror before signaling/yielding the result so a
            # consumer observing the result sees an up-to-date store for the turn.
            flush_transcript_mirror
            unless @first_result_received
              @first_result_received = true
              @first_result_condition.signal
            end
            if message[:is_error]
              errors = (message[:errors] || []).join('; ')
              @last_error_result_text = errors.empty? ? (message[:subtype] || 'unknown error').to_s : errors
            else
              @last_error_result_text = nil
            end
          elsif !(msg_type == 'system' && message[:subtype] == 'session_state_changed')
            # Anything other than the post-turn session_state_changed marker
            # means the conversation moved on; a ProcessError now is a fresh
            # crash, not the expected exit from a prior error result. Mirrors
            # the Python/TypeScript SDK reset logic.
            @last_error_result_text = nil
          end
          # Regular SDK messages go to the queue
          @message_queue.enqueue(message)
        end
      end
    rescue StandardError => e
      # Unblock pending control requests (e.g., initialize) so callers don't
      # hang until timeout. INVARIANT: store the result before signaling —
      # senders check the slot before waiting (level-trigger).
      @pending_control_responses.dup.each do |request_id, condition|
        @pending_control_results[request_id] ||= e
        condition.signal
      end

      # When the CLI emits a result with is_error=true (e.g. error_max_turns,
      # error_during_execution, a StructuredOutput error) it then exits
      # non-zero on purpose, for shell-script consumers. The trailing
      # ProcessError carries no information beyond "exit code 1" — replace it
      # with the structured error the CLI already reported so the exception is
      # actionable. Mirrors the Python SDK (_read_messages) and the TypeScript
      # SDK (Query.ts readMessages).
      error = if e.is_a?(ProcessError) && @last_error_result_text
                ProcessError.new("Claude Code returned an error result: #{@last_error_result_text}",
                                 exit_code: e.exit_code, stderr: e.stderr)
              else
                e
              end

      # Put error in queue so iterators can handle it
      @message_queue.enqueue({ type: 'error', error: error })
    ensure
      # Catch entries from a turn that ended without a `result` (early EOF /
      # transport error) so they aren't dropped. The flush can suspend (lock
      # acquire / thread join), so Async::Stop delivered mid-flush would skip
      # the rest of this block — the nested ensure guarantees the signal and
      # the end sentinel (which have no suspension points) are still delivered,
      # mirroring the Python port's shielded flush + send_nowait sentinel.
      begin
        flush_transcript_mirror
      ensure
        unless @first_result_received
          @first_result_received = true
          @first_result_condition.signal
        end
        # Always signal end of stream
        @message_queue.enqueue({ type: 'end' })
      end
    end

    # Flush the transcript-mirror batcher, swallowing errors — a mirror failure
    # must never propagate into the read loop or its teardown.
    def flush_transcript_mirror
      @transcript_mirror_batcher&.flush
    rescue StandardError => e
      warn "Claude SDK: transcript mirror flush failed: #{e.message}"
    end

    def handle_control_response(message)
      response = message[:response] || {}
      request_id = response[:request_id] || response[:requestId] || message[:request_id] || message[:requestId]
      # Capture the waiter ONCE: a worker-thread caller can satisfy its
      # level-trigger check and evict the entries between our key? check and
      # a re-lookup, so `@pending_control_responses[request_id].signal` could
      # call signal on nil — a NoMethodError the read loop would treat as a
      # fatal transport error, tearing down the whole session. Signaling an
      # already-evicted waiter is harmless (orphan token push / no-op).
      waiter = @pending_control_responses[request_id]
      return unless waiter

      if response[:subtype] == 'error'
        @pending_control_results[request_id] = StandardError.new(response[:error] || 'Unknown error')
      else
        @pending_control_results[request_id] = response
      end

      # Signal that response is ready. INVARIANT: the result slot above
      # MUST be written before this signal — senders check the slot before
      # waiting (level-trigger).
      waiter.signal
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

      # Field order mirrors Python _internal/query.py's can_use_tool branch.
      # Suggestions are hydrated into PermissionUpdate (Python #920); a
      # malformed entry raises here, on the reactor, and becomes an error
      # control_response — same observable behavior as Python.
      context = ToolPermissionContext.new(
        signal: nil,
        suggestions: (request_data[:permission_suggestions] || []).map { |s| PermissionUpdate.new(s) },
        tool_use_id: request_data[:tool_use_id],
        agent_id: request_data[:agent_id],
        blocked_path: request_data[:blocked_path],
        decision_reason: request_data[:decision_reason],
        title: request_data[:title],
        display_name: request_data[:display_name],
        description: request_data[:description]
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
        # Unknown event: preserve the wire event name and full raw payload
        # rather than dropping event-specific fields (Python passes the raw
        # dict through, so nothing is lost there).
        UnknownHookInput.new(hook_event_name: event_name, raw_input: input_data, **base_args)
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

      # Detect the execution mode BEFORE any write: a control method called
      # from inside a hook/permission/SDK-MCP callback runs on a
      # FiberBoundary worker thread with no reactor. Detecting after the
      # write left a half-executed request (written to the CLI, then
      # RuntimeError; the eventual response dropped by the key? guard).
      task = Async::Task.current?

      # Generate unique request ID (callbacks may issue requests from
      # worker threads concurrently with the reactor)
      request_id = @request_counter_mutex.synchronize do
        @request_counter += 1
        "req_#{@request_counter}_#{SecureRandom.hex(4)}"
      end

      # Reactor callers wait on an Async::Condition; worker-thread callers
      # on a ThreadWaiter. Registration must precede the write.
      waiter = task ? Async::Condition.new : ThreadWaiter.new
      @pending_control_responses[request_id] = waiter

      control_request = {
        type: 'control_request',
        request_id: request_id,
        requestId: request_id,
        request: request
      }

      writeln(JSON.generate(control_request))

      begin
        await_control_response(request_id, waiter, task, timeout_seconds, request[:subtype])
        result = @pending_control_results[request_id]
        raise result if result.is_a?(Exception)

        result&.[](:response) || {}
      ensure
        # Always evict the entries so a late control_response (after timeout)
        # or an Async::Stop propagating through wait does not leak state.
        @pending_control_responses.delete(request_id)
        @pending_control_results.delete(request_id)
      end
    end

    # Level-triggered wait: every signal site stores the result BEFORE
    # signaling, so checking the result slot before (and between) waits
    # cannot lose a wakeup — Async::Condition is edge-triggered and a signal
    # arriving before the sender reaches wait would otherwise be dropped
    # (reachable when a custom transport's #write suspends after delivery,
    # or when the read loop's rescue broadcast fires mid-write). Mirrors
    # anyio.Event's level-trigger semantics in Python.
    #
    # Do NOT reimplement the reactor wait as a nested `Async do ... end.wait`
    # — that spawned a separate task and leaked the pending entries when an
    # Async::Stop propagated through `.wait` before cleanup ran.
    def await_control_response(request_id, waiter, task, timeout_seconds, subtype)
      if task
        begin
          task.with_timeout(timeout_seconds) do
            waiter.wait until @pending_control_results.key?(request_id)
          end
        rescue Async::TimeoutError
          raise ControlRequestTimeoutError, "Control request timeout: #{subtype}"
        end
      else
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
        until @pending_control_results.key?(request_id)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise ControlRequestTimeoutError, "Control request timeout: #{subtype}" if remaining <= 0

          waiter.wait(remaining)
        end
      end
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

    def handle_mcp_tools_call(server, message, _params)
      # Route through the official MCP::Server (Python parity: its lowlevel
      # server validates arguments against the tool's inputSchema BEFORE the
      # handler runs and reports validation failures, unknown tools, and
      # handler exceptions as in-band isError results). tools/list,
      # initialize, resources/* and prompts/* stay on the SDK paths — the
      # gem drops annotations/_meta from tools/list and negotiates newer
      # protocol versions.
      server.handle_message(message)
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
    # The control protocol requires stdin to stay open for the entire turn
    # (hook replies, can_use_tool replies and SDK MCP tool results are all
    # written to stdin), so no timeout is applied — closing stdin mid-turn
    # silently broke hooks/MCP on turns longer than the old 60s bound
    # (mirrors Python SDK commit c3d96cb). The condition is guaranteed to be
    # signaled: by the result branch in read_messages, or by its ensure block
    # when the process exits early.
    def wait_for_result_and_end_input
      if !@first_result_received &&
         ((@sdk_mcp_servers && !@sdk_mcp_servers.empty?) || (@hooks && !@hooks.empty?))
        @first_result_condition.wait
      end
    ensure
      @transport.end_input
    end

    # Stream input messages to transport. NOTE: iteration runs on the
    # reactor (the deliberate FiberBoundary carve-out — see
    # fiber_boundary.rb): scheduler-aware blocking (Thread::Queue#pop,
    # sleep, socket IO) parks only this task; CPU-bound or scheduler-opaque
    # work in the enumerator must be moved to a producer Thread by the user.
    def stream_input(stream)
      wrote_message = false
      stream.each do |message|
        break if @closed
        serialized = message.is_a?(Hash) ? JSON.generate(message) : message.to_s
        writeln(serialized)
        wrote_message = true
      end
    rescue StandardError => e
      # Log error but don't raise
      warn "Error streaming input: #{e.message}"
    ensure
      # Three teardown shapes:
      # - #close in progress (@closed, Async::Stop unwinding): do nothing —
      #   the transport is about to be closed, and waiting on
      #   @first_result_condition inside a stopping fiber could suspend
      #   teardown. Mirrors Python, where cancellation skips this entirely.
      # - A turn is in flight (some message reached the CLI): hold stdin
      #   open until its first result so hooks/SDK MCP control replies can
      #   still be written (no timeout — the result or process exit is
      #   guaranteed to signal).
      # - No complete message ever reached the CLI (empty stream, or the
      #   stream raised before the first write): no result can ever arrive,
      #   so waiting would park query() forever beside an idle CLI. Close
      #   stdin so the CLI sees EOF and exits. Deliberate improvement over
      #   Python, which leaves stdin open and hangs on this path.
      unless @closed
        if wrote_message
          wait_for_result_and_end_input
        else
          @transport.end_input
        end
      end
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
      # Wake pending control-request waiters (same shape as the read-loop
      # rescue broadcast): close stops the read task with Async::Stop, which
      # bypasses that broadcast — a worker-thread caller parked in
      # ThreadWaiter#wait would otherwise leak its OS thread for the full
      # control-request timeout (up to 1200s) in long-lived processes.
      # INVARIANT: store the result before signaling (level-trigger).
      @pending_control_responses.dup.each do |request_id, waiter|
        @pending_control_results[request_id] ||= CLIConnectionError.new('Query closed')
        waiter.signal
      end
      # Final mirror flush BEFORE stopping the read task, so the last turn's
      # entries reach the store. #close on the batcher never raises.
      @transcript_mirror_batcher&.close
      # Stop tracked child tasks (e.g. stream_input) before the read task and
      # transport so a parked input stream can never keep the reactor alive
      # (mirrors Python close() cancelling _child_tasks).
      @child_tasks.each(&:stop)
      @child_tasks.clear
      @task&.stop
      @transport.close
    end
  end
end
