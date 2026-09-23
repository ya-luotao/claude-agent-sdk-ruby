# frozen_string_literal: true

require 'json'
require 'async'
require 'async/queue'
require 'async/condition'
require 'securerandom'
require 'timeout'
require_relative 'transport'
require_relative 'errors'
require_relative 'cancellation_signal'

module ClaudeAgentSDK
  # Handles bidirectional control protocol on top of Transport
  #
  # This class manages:
  # - Control request/response routing
  # - Hook callbacks
  # - Tool permission callbacks
  # - Message streaming
  # - Initialization handshake
  #
  # @api private
  class Query
    attr_reader :transport, :is_streaming_mode, :sdk_mcp_servers

    # The CLI's response to the initialize control request (nil before
    # #initialize_protocol completes). Read by Client#server_info.
    #
    # @api private
    attr_reader :initialization_result

    CONTROL_REQUEST_TIMEOUT_ENV_VAR = 'CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS'
    DEFAULT_CONTROL_REQUEST_TIMEOUT_SECONDS = 1200.0

    # Task types whose completion runs a follow-up turn, and which therefore
    # may still need the control channel after the turn's result frame.
    #
    # Mirrors the set the CLI itself holds a result back for, which is
    # narrower than its notion of "delegated agent work". The types left out
    # are left out on purpose:
    #   - background shells and monitors run indefinitely by design, so
    #     deferring the close on one withholds it forever rather than briefly;
    #   - teammates are long-lived too — their status stays running for their
    #     whole lifetime, so they never settle the ledger;
    #   - remote agents can be long-running monitors the CLI likewise refuses
    #     to wait on.
    # Anything added here must be a type that reliably reaches a terminal
    # status, or it will hang the query (see #track_task_lifecycle).
    DEFERRING_TASK_TYPES = %w[local_agent local_workflow].freeze

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
                   exclude_dynamic_sections: nil, system_prompt_snapshot: nil, skills: nil,
                   forward_subagent_text: false, agent_progress_summaries: nil,
                   callback_scheduling: :thread, callback_wrapper: nil)
      @transport = transport
      @is_streaming_mode = is_streaming_mode
      @can_use_tool = can_use_tool
      @hooks = hooks || {}
      @sdk_mcp_servers = sdk_mcp_servers || {}
      @callback_scheduling = callback_scheduling || :thread
      @callback_wrapper = callback_wrapper
      @agents = agents
      @exclude_dynamic_sections = exclude_dynamic_sections
      @system_prompt_snapshot = system_prompt_snapshot
      @skills = skills
      @forward_subagent_text = forward_subagent_text
      @agent_progress_summaries = agent_progress_summaries

      # Control protocol state
      @pending_control_responses = {}
      @pending_control_results = {}
      @hook_callbacks = {}
      @hook_callback_timeouts = {}
      @next_callback_id = 0
      @request_counter = 0
      @request_counter_mutex = Mutex.new
      @control_stream_error = nil
      @inflight_control_request_tasks = {}
      @callback_request_signals = {}

      # Message stream
      @message_queue = Async::Queue.new
      # Set when a run-ending result arrives (a result frame with no tasks in
      # flight) so the stdin-closing waiter can wake. Named for history — it
      # once tracked the literal first result.
      @first_result_received = false
      # Task IDs of started-but-not-finished deferring tasks. A result frame
      # only ends one turn, not the run: a background task keeps running past
      # it and still needs stdin for hook/SDK-MCP control responses (Python
      # #1088/#1103), so a result that arrives while this set is non-empty
      # must not close stdin.
      @inflight_tasks = Set.new
      # Set to the result payload when the most recent message is a result
      # with is_error=true. Used to replace the generic "exit code 1"
      # ProcessError with a ResultError carrying what the CLI already
      # reported. Mirrors the TypeScript SDK's `lastErrorResultText`
      # (Query.ts), but keeps the whole payload rather than just the text.
      @last_error_result = nil
      @first_result_condition = Async::Condition.new
      @task = nil
      @child_tasks = []
      @initialized = false
      @closed = false
      @initialization_result = nil
      @transcript_mirror_batcher = nil

      # Cross-thread close marshaling (see #close). Thread::Queue is the one
      # primitive that is both fiber-scheduler-aware on the reactor side and
      # thread-safe on the caller side (push -> scheduler#unblock).
      @close_requests = ::Thread::Queue.new
      @close_watcher = nil
      @owning_scheduler = nil
      # First-caller-wins guard for close_now (see there).
      @close_mutex = Mutex.new
      @close_started = false
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
      # false is meaningful (rebuild the prompt every request), so send it
      # explicitly; only nil (unset) is omitted.
      request[:systemPromptSnapshot] = @system_prompt_snapshot unless @system_prompt_snapshot.nil?
      # 'all' and omitted are equivalent at the wire level (no filter), so
      # only send the field when it's an explicit list (mirrors Python).
      request[:skills] = @skills if @skills.is_a?(Array)
      # Off is the CLI default, so only send the field when enabled — an
      # older CLI then never sees an unknown key on the common path.
      request[:forwardSubagentText] = true if @forward_subagent_text
      # Unset (nil) omits the key; true/false are forwarded verbatim. Not a live toggle: CLI
      # 2.1.278 only acts on a truthy value, so false is schema-valid but
      # equivalent to omitting the key.
      request[:agentProgressSummaries] = @agent_progress_summaries unless @agent_progress_summaries.nil?

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
      unless parent
        raise CLIConnectionError,
              'Query#start must be called inside an Async{} block (e.g. wrap Client#connect in Async{...})'
      end

      @owning_scheduler = Fiber.scheduler
      # Async child fibers do not inherit OTel's fiber-local current context.
      @task = parent.async(&FiberBoundary.capture_otel_context { read_messages })
      # Reactor-side agent for #close calls arriving from foreign threads
      # (FiberBoundary callbacks, plain user threads): Async::Task#stop needs
      # the owning thread's Fiber.scheduler, so the off-thread caller hands the
      # whole close over and waits. Transient: must never keep the reactor
      # alive, and is stopped automatically when the parent task finishes.
      # One-shot: after serving a close it is done; a reactor-side close wakes
      # it via @close_requests.close (pop -> nil) so it exits without serving.
      @close_watcher = parent.async(transient: true, &FiberBoundary.capture_otel_context do
        if (reply = @close_requests.pop)
          begin
            close
          ensure
            reply << true
          end
        end
      end)
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
    def spawn_task(&)
      parent = Async::Task.current?
      raise CLIConnectionError, 'Query#spawn_task must be called inside an Async{} block' unless parent

      task = parent.async(&FiberBoundary.capture_otel_context(&))
      @child_tasks << task
      task
    end

    # Install the transcript-mirror batcher fed by `transcript_mirror` frames
    # (Client mode with a session_store). nil disables mirroring.
    def set_transcript_mirror_batcher(batcher)
      @transcript_mirror_batcher = batcher
    end

    # True when the mirror dropped at least one batch (store copy incomplete).
    # Meaningful after #close, which runs the final flush. Consulted by the
    # resume-from-store teardown to decide whether the materialized temp dir
    # holds the only copy of some turns and must be preserved.
    def mirror_batches_dropped?
      !!@transcript_mirror_batcher&.batches_dropped?
    end

    # Synthesize a `mirror_error` system message and put it on the SDK message
    # stream so consumers learn a mirror batch was dropped (timeouts
    # immediately, other failures after up to three attempts).
    # Non-blocking: the message queue is unbounded, so unlike the
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
          handler_task = Async::Task.current.async(&FiberBoundary.capture_otel_context do
            begin
              handle_control_request(message)
            ensure
              # Identity-guarded: if the CLI ever reused an in-flight request
              # id, the later handler owns the slot and must stay cancellable.
              if request_id && @inflight_control_request_tasks[request_id].equal?(Async::Task.current)
                @inflight_control_request_tasks.delete(request_id)
              end
            end
          end)
          # A handler that never suspends (MCP metadata, unsupported-subtype
          # error path) already ran to completion inside the async{} above —
          # its ensure-delete fired before this insert, so registering it here
          # would leak a finished task in the map forever.
          @inflight_control_request_tasks[request_id] = handler_task if request_id && !handler_task.finished?
        when 'control_cancel_request'
          request_id = message[:request_id] || message[:requestId]
          @callback_request_signals[request_id]&.cancel
          task = request_id ? @inflight_control_request_tasks[request_id] : nil
          task&.stop
          next
        when 'transcript_mirror'
          # session_store mirror frame — fed to the batcher, never surfaced to
          # consumers. camelCase on the wire; transport symbolizes keys.
          @transcript_mirror_batcher&.enqueue(message[:filePath] || message[:file_path], message[:entries] || [])
          next
        else
          # Track task lifecycle frames so results can tell "one turn ended"
          # apart from "the run is done" (Python #1088/#1103).
          track_task_lifecycle(message) if message[:type] == 'system'

          if message[:type] == 'result'
            # Flush the mirror before signaling/yielding the result so a
            # consumer observing the result sees an up-to-date store for the turn.
            flush_transcript_mirror
            # A result with tasks still in flight ends one turn, not the run:
            # the tasks may still need hook/SDK-MCP control responses over
            # stdin, and closing it now silently disables hooks and fails
            # SDK-MCP calls with "Stream closed". Each deferring task's
            # completion wakes the parent for a follow-up turn, so a later
            # result arrives with no tasks in flight and closes stdin then.
            if @inflight_tasks.empty? && !@first_result_received
              @first_result_received = true
              @first_result_condition.signal
            end
            if message[:is_error]
              @last_error_result = message
            else
              @last_error_result = nil
            end
          elsif !(msg_type == 'system' && message[:subtype] == 'session_state_changed')
            # Anything other than the post-turn session_state_changed marker
            # means the conversation moved on; a ProcessError now is a fresh
            # crash, not the expected exit from a prior error result. Mirrors
            # the Python/TypeScript SDK reset logic.
            @last_error_result = nil
          end
          # Regular SDK messages go to the queue
          @message_queue.enqueue(message)
        end
      end
    rescue StandardError => e
      # When the CLI emits a result with is_error=true (e.g. error_max_turns,
      # error_during_execution, an API failure, a StructuredOutput error) it
      # then exits non-zero on purpose, for shell-script consumers. The
      # trailing ProcessError carries no information beyond "exit code 1" —
      # replace it with a ResultError carrying what the CLI already reported
      # so the exception is actionable *and* typed. Mirrors the Python SDK
      # (_read_messages) and the TypeScript SDK (Query.ts readMessages).
      error = if e.is_a?(ProcessError) && @last_error_result
                ResultError.new("Claude Code returned an error result: #{ResultError.error_text(@last_error_result)}",
                                data: @last_error_result, exit_code: e.exit_code, stderr: e.stderr,
                                original_error: e)
              else
                e
              end

      # Put error in queue so iterators can handle it
      @message_queue.enqueue({ type: 'error', error: error })
    ensure
      # EOF is terminal for control requests even when the message stream
      # ends successfully. Serialize terminal publication with registration:
      # every sender is either in this snapshot or rejected before writing.
      # Preserve enriched ResultError from the rescue path (Python #1198).
      waiters = @request_counter_mutex.synchronize do
        @control_stream_error = error || CLIConnectionError.new('Control stream ended')
        @pending_control_responses.dup
      end
      waiters.each do |request_id, condition|
        @pending_control_results[request_id] ||= @control_stream_error
        condition.signal
      end
      # A callback can no longer be answered after EOF, transport failure,
      # or reactor cancellation. Wake cooperative worker-thread callbacks too.
      @callback_request_signals.dup.each_value(&:cancel)
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

    # Track in-flight tasks from `system` task lifecycle frames.
    #
    # `task_started` marks a task in flight; `task_notification` or a
    # `task_updated` patch with a terminal status clears it. Terminal
    # completion can arrive as either frame (not every terminal task emits a
    # notification), so both are handled; Set deletion keeps the pair
    # idempotent.
    #
    # This is a mitigation, not a complete answer to Python #1088. An empty
    # set means "nothing we know of is running", which is not the same as
    # "the run is over": a task that settles *before* the turn's result frame
    # leaves the set empty at that result, so stdin closes even though the
    # completion may still wake the parent for a continuation turn. What this
    # does fix is the common ordering, where the task outlives the turn that
    # spawned it.
    #
    # Only delegated agent work is tracked (DEFERRING_TASK_TYPES). A
    # background *shell* is also reported through these frames, but it may
    # never reach a terminal status, and the CLI in stream-json mode only
    # exits on stdin EOF — tracking one would withhold the close forever.
    #
    # `background_tasks_changed` is deliberately not consumed, in either
    # direction: its payload is the live *background* set, while a subagent
    # is registered in the foreground and only flips to backgrounded later
    # without a second task_started, so narrowing against the snapshot would
    # drop an agent that goes on to outlive its turn, and widening from it
    # could admit an id no later frame ever clears (observer agents suppress
    # both their start and terminal frames).
    def track_task_lifecycle(message)
      task_id = message[:task_id]
      return if task_id.nil? || task_id.to_s.empty?

      case message[:subtype]
      when 'task_started'
        @inflight_tasks.add(task_id) if DEFERRING_TASK_TYPES.include?(message[:task_type])
      when 'task_notification'
        @inflight_tasks.delete(task_id)
      when 'task_updated'
        patch = message[:patch]
        status = patch.is_a?(Hash) ? patch[:status] : nil
        @inflight_tasks.delete(task_id) if TERMINAL_TASK_STATUSES.include?(status)
      end
    end

    # Whether the CLI may still send control requests that need a reply.
    #
    # SDK MCP servers, hooks and the can_use_tool permission callback are all
    # served over the control protocol: the CLI writes a control_request to
    # stdout and blocks until the SDK writes the matching control_response to
    # stdin. Closing stdin while any of these is configured makes every later
    # request fail CLI-side with "Stream closed". Mirrors the TypeScript
    # SDK's hasBidirectionalNeeds, de-prefixed per Ruby naming (Python #1204).
    #
    # can_use_tool is tested for truthiness, not for nil: ClaudeAgentSDK
    # .configure_can_use_tool treats a falsey callback as "no callback"
    # (`can_use_tool: enabled ? cb : false` is a real config shape), and the
    # two must agree — otherwise `false` would skip the stdio routing while
    # still holding stdin open for a reply that can never be asked for.
    def bidirectional_needs?
      !@sdk_mcp_servers.empty? || !@hooks.empty? || !!@can_use_tool
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
        response_data = handle_permission_request(request_data, request_id: request_id)
      when 'hook_callback'
        response_data = handle_hook_callback(request_data, request_id: request_id)
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
      responded = true
    rescue Async::Stop
      # Cancellation requested; respond with an error so the CLI can unblock.
      send_control_error(request_id, 'Cancelled')
    rescue SystemExit, SignalException => e
      # exit / Interrupt / a signal raised while a user callback ran
      # (FiberBoundary.invoke_callback re-raises it here, on the reactor) —
      # or a real signal landing on this fiber. Never swallowed: answer the
      # request the way an ordinary callback failure is answered, so the CLI
      # is not left waiting, then let it terminate the process as Ruby
      # normally would. The transport flushes every write.
      respond_to_process_exit(request_id, request_data, e) unless responded
      raise
    rescue StandardError => e
      send_control_error(request_id, e.message)
    end

    # The response an ordinary exception from the callback would have
    # produced, with the process-exit exception named by class: an error
    # control response for hooks / can_use_tool; for SDK MCP requests an
    # in-band isError result (tools/call) or a JSON-RPC internal error
    # (resources/read, prompts/get), inside a successful control response.
    def respond_to_process_exit(request_id, request_data, error)
      message = FiberBoundary.process_exit_message(error)
      mcp_message = request_data[:message] if request_data.is_a?(Hash) && request_data[:subtype] == 'mcp_message'
      return send_control_error(request_id, message) unless mcp_message.is_a?(Hash)

      mcp_response = { jsonrpc: '2.0', id: mcp_message[:id] }
      if mcp_message[:method] == 'tools/call'
        mcp_response[:result] = { content: [{ type: 'text', text: message }], isError: true }
      else
        mcp_response[:error] = { code: -32_603, message: message }
      end
      writeln(JSON.generate({
                              type: 'control_response',
                              response: {
                                subtype: 'success', request_id: request_id, requestId: request_id,
                                response: { mcp_response: mcp_response }
                              }
                            }))
    rescue CLIConnectionError
      nil # the CLI is already gone; nothing is waiting for the answer
    end

    def send_control_error(request_id, message)
      error_response = {
        type: 'control_response',
        response: {
          subtype: 'error',
          request_id: request_id,
          requestId: request_id,
          error: message
        }
      }
      writeln(JSON.generate(error_response))
    rescue CLIConnectionError
      # EOF/close can invalidate a callback after the peer has gone away.
      # Only this best-effort reply is discarded; read errors still reach
      # the message queue through read_messages.
      nil
    end

    def handle_permission_request(request_data, request_id: nil)
      raise 'canUseTool callback is not provided' unless @can_use_tool

      signal = CancellationSignal.new
      @callback_request_signals[request_id] = signal if request_id
      original_input = request_data[:input]

      # Field order mirrors Python _internal/query.py's can_use_tool branch.
      # Suggestions are hydrated into PermissionUpdate (Python #920) through
      # the lenient .wrap, so fields a newer CLI adds never trip the
      # strict-attribute warning meant for user-built updates. A nil (or
      # false) entry becomes an empty PermissionUpdate, as PermissionUpdate.new
      # made it before; any other non-Hash entry raises here, on the reactor,
      # and becomes an error control_response — same observable behavior as
      # Python.
      context = ToolPermissionContext.new(
        signal: signal,
        request_id: request_id,
        suggestions: (request_data[:permission_suggestions] || []).map { |s| PermissionUpdate.wrap(s || {}) },
        tool_use_id: request_data[:tool_use_id],
        agent_id: request_data[:agent_id],
        blocked_path: request_data[:blocked_path],
        decision_reason: request_data[:decision_reason],
        title: request_data[:title],
        display_name: request_data[:display_name],
        description: request_data[:description]
      )

      # User-supplied permission callback runs on a plain thread by default,
      # so AR/PG calls inside it aren't intercepted by the Fiber scheduler;
      # with callback_scheduling: :inline it runs in place on this control-
      # request task, where control_cancel_request (task.stop) can actually
      # cancel it at suspension points. exit / Interrupt from the callback
      # re-raise here after the hop; handle_control_request answers the
      # request before letting them propagate (FiberBoundary.invoke_callback).
      response = FiberBoundary.invoke_callback(scheduling: @callback_scheduling, wrapper: @callback_wrapper) do
        @can_use_tool.call(request_data[:tool_name], request_data[:input], context)
      end
      # A worker may return a decision after the read loop invalidated the
      # request. Never turn that late decision into an allow response.
      raise Async::Stop if signal.cancelled?

      # Convert PermissionResult to expected format
      case response
      when PermissionResultAllow
        result = {
          behavior: 'allow',
          updatedInput: response.updated_input || original_input
        }
        result[:updatedPermissions] = response.updated_permissions.map(&:to_h) if response.updated_permissions
        result
      when PermissionResultDeny
        result = { behavior: 'deny', message: response.message }
        result[:interrupt] = response.interrupt if response.interrupt
        result
      else
        raise "Tool permission callback must return PermissionResult, got #{response.class}"
      end
      completed = true
      result
    ensure
      signal&.cancel unless completed
      untrack_callback_signal(request_id, signal)
    end

    def handle_hook_callback(request_data, request_id: nil)
      callback_id = request_data[:callback_id]
      callback = @hook_callbacks[callback_id]
      raise "No hook callback found for ID: #{callback_id}" unless callback

      signal = CancellationSignal.new
      @callback_request_signals[request_id] = signal if request_id

      # Parse input data into typed HookInput object
      input_data = request_data[:input] || {}
      hook_input = parse_hook_input(input_data)

      # Create typed HookContext
      context = HookContext.new(signal: signal, request_id: request_id)

      # Hop off the Fiber scheduler before invoking user hook code (default
      # :thread mode). With a timeout, the Async-side with_timeout wraps the
      # hop; if it fires, .value returns early with an exception and the
      # worker thread is left to finish on its own (best-effort abandonment).
      # In :inline mode the callback runs in place, so with_timeout becomes
      # genuine cooperative cancellation: the hook is interrupted at its next
      # suspension point and its ensure blocks run (Python parity — anyio
      # cancels the coroutine). A CPU-stuck inline hook cannot be timed out.
      # All three variants go through FiberBoundary.invoke_callback, so exit
      # / Interrupt from the hook reach handle_control_request, which answers
      # the request before letting them propagate.
      unless @hook_callback_timeouts[callback_id]
        hook_output = FiberBoundary.invoke_callback(scheduling: @callback_scheduling, wrapper: @callback_wrapper) do
          callback.call(hook_input, request_data[:tool_use_id], context)
        end
      end

      if (timeout = @hook_callback_timeouts[callback_id])
        hook_output =
          if @callback_scheduling == :inline
            # The timeout exception is raised INSIDE user code here, and
            # Async::TimeoutError is a StandardError — a hook's ordinary
            # `rescue StandardError` would swallow the cancellation and
            # convert the expired hook into a success (or keep running past
            # the deadline). FiberBoundary.with_cooperative_timeout injects
            # a non-StandardError cancellation instead (fresh subclass per
            # scope — the nested-scope rationale lives on the helper),
            # translated back once control leaves user code so the outward
            # contract (Async::TimeoutError) is unchanged. The wrapper
            # composes INSIDE the timeout scope, and the cancellation
            # passes through it un-swallowed (InlineCancellation is not a
            # StandardError, so a wrapper's ordinary rescue can't eat it).
            FiberBoundary.with_cooperative_timeout(
              Async::Task.current, timeout,
              on_timeout: -> { Async::TimeoutError.new('execution expired') }
            ) do
              FiberBoundary.invoke_callback(scheduling: :inline, wrapper: @callback_wrapper) do
                callback.call(hook_input, request_data[:tool_use_id], context)
              end
            end
          else
            Async::Task.current.with_timeout(timeout) do
              FiberBoundary.invoke_callback(wrapper: @callback_wrapper) do
                callback.call(hook_input, request_data[:tool_use_id], context)
              end
            end
          end
      end

      # A thread callback may finish after EOF/close invalidated its request.
      raise Async::Stop if signal.cancelled?

      # Convert Ruby-safe field names to CLI-expected names
      result = convert_hook_output_for_cli(hook_output)
      completed = true
      result
    ensure
      signal&.cancel unless completed
      untrack_callback_signal(request_id, signal)
    end

    # Identity-guarded for the same reason as the in-flight task map: a handler
    # only untracks its own signal, never a later request that reused its id —
    # otherwise EOF/close could no longer invalidate that later request.
    def untrack_callback_signal(request_id, signal)
      return unless request_id && @callback_request_signals[request_id].equal?(signal)

      @callback_request_signals.delete(request_id)
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
          background_tasks: fetch.call(:background_tasks),
          session_crons: fetch.call(:session_crons),
          **base_args
        )
      when 'SubagentStop'
        SubagentStopHookInput.new(
          stop_hook_active: fetch.call(:stop_hook_active),
          agent_id: fetch.call(:agent_id),
          agent_transcript_path: fetch.call(:agent_transcript_path),
          agent_type: fetch.call(:agent_type),
          last_assistant_message: fetch.call(:last_assistant_message),
          background_tasks: fetch.call(:background_tasks),
          session_crons: fetch.call(:session_crons),
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
      return hook_output.to_h if hook_output.respond_to?(:to_h) && !hook_output.is_a?(Hash)

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

      # Reactor callers wait on an Async::Condition; worker-thread callers
      # on a ThreadWaiter. Register atomically with the terminal-state check
      # so EOF cannot strand a sender that missed the final broadcast.
      waiter = task ? Async::Condition.new : ThreadWaiter.new
      request_id = @request_counter_mutex.synchronize do
        raise @control_stream_error if @control_stream_error

        @request_counter += 1
        id = "req_#{@request_counter}_#{SecureRandom.hex(4)}"
        @pending_control_responses[id] = waiter
        id
      end

      control_request = {
        type: 'control_request',
        request_id: request_id,
        requestId: request_id,
        request: request
      }

      await_control_response(request_id, waiter, task, timeout_seconds, request[:subtype]) do
        writeln(JSON.generate(control_request))
      end
      result = @pending_control_results[request_id]
      raise result if result.is_a?(Exception)

      result&.[](:response) || {}
    ensure
      # Registration, serialization, write and wait share one cleanup scope.
      # In particular, failed or cancelled writes never retain a waiter.
      @pending_control_responses.delete(request_id)
      @pending_control_results.delete(request_id)
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
    # The yielded send runs inside the same deadline as the response wait.
    def await_control_response(request_id, waiter, task, timeout_seconds, subtype)
      expired = -> { ControlRequestTimeoutError.new("Control request timeout: #{subtype}") }
      if task
        # A non-StandardError deadline escapes the transport's write rescue;
        # only this deadline is translated, not an outer task's cancellation.
        FiberBoundary.with_cooperative_timeout(task, timeout_seconds, on_timeout: expired) do
          yield
          waiter.wait until @pending_control_results.key?(request_id)
        end
      else
        # Only schedulerless callers use stdlib Timeout. A fresh, private
        # non-StandardError deadline bypasses transport write rescues without
        # relabeling a transport's own Timeout::Error or an outer deadline.
        # Interrupt the caller rather than abandoning a still-writing worker.
        cancellation = Class.new(Exception) # rubocop:disable Lint/InheritException -- cancellation must bypass transport rescues
        begin
          Timeout.timeout(timeout_seconds, cancellation) do
            yield
            waiter.wait(nil) until @pending_control_results.key?(request_id)
          end
        rescue cancellation
          raise expired.call
        end
      end
    end

    def handle_sdk_mcp_request(server_name, message)
      # Carry this session's scheduling mode and callback wrapper across the
      # dispatch into the (possibly session-shared) SdkMcpServer via fiber
      # storage — set on the dispatching fiber, read back by the server's
      # handlers at invoke time (see
      # SdkMcpServer#effective_callback_scheduling / _wrapper). Fiber
      # storage is per-fiber, so concurrent sessions cannot see each
      # other's value even across suspension points. The value is a
      # closable CallbackDispatchScope, closed + restored in the ensure below:
      # fibers/threads created during the dispatch inherit the same scope
      # OBJECT (storage inheritance copies the hash, shares references), so
      # closing it invalidates the mode for every inheritor at once — a
      # child task that outlives the dispatch cannot carry the session mode
      # into later direct server calls, and nothing stays stamped on
      # long-lived fibers.
      previous_dispatch = Fiber[FiberBoundary::DISPATCH_KEY]
      dispatch_scope = FiberBoundary::CallbackDispatchScope.new(@callback_scheduling, @callback_wrapper)
      Fiber[FiberBoundary::DISPATCH_KEY] = dispatch_scope

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
    ensure
      dispatch_scope&.close
      Fiber[FiberBoundary::DISPATCH_KEY] = previous_dispatch
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
      # initialize, resources/* and prompts/* stay on the SDK paths: the
      # gem's tools/list injects "$schema" and drops `required: []` (and
      # would advertise the empty fallback schema where the SDK advertises
      # the user's own), and its initialize negotiates newer protocol
      # versions and advertises prompts/resources/logging even for a
      # tools-only server. Annotations/_meta do survive the gem path.
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

    # Background in-flight foreground tasks (Bash commands and subagents) — the
    # control-request equivalent of pressing Ctrl+B in the terminal.
    # @param tool_use_id [String, nil] The spawning tool_use block's id (not a
    #   task_id or agent_id). nil is the explicit all-tasks form: it backgrounds
    #   every foreground task
    # @return [Hash] Targeted: `{ backgrounded: true }`, or `{ backgrounded:
    #   false }` — a definitive miss (no matching foreground task). All-tasks:
    #   `{}`, which says nothing about whether any task existed
    # @raise [ArgumentError] if tool_use_id is neither nil nor a non-empty String
    def background_tasks(tool_use_id: nil)
      request = { subtype: 'background_tasks' }
      request[:tool_use_id] = background_selector(tool_use_id) unless tool_use_id.nil?
      send_control_request(request)
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

    # Wait for a run-ending result before closing stdin when hooks, SDK MCP
    # servers or a can_use_tool callback may still need to exchange control
    # messages with the CLI.
    # The control protocol requires stdin to stay open for the entire turn
    # (hook replies, can_use_tool replies and SDK MCP tool results are all
    # written to stdin), so no timeout is applied — closing stdin mid-turn
    # silently broke hooks/MCP on turns longer than the old 60s bound
    # (mirrors Python SDK commit c3d96cb). A result frame ends one turn, not
    # necessarily the run: while background tasks are in flight the result
    # branch withholds the signal (Python #1088/#1103), and each deferring
    # task's completion wakes the parent for a follow-up turn that ends in
    # another result. The condition is guaranteed to be signaled: by the
    # result branch in read_messages once no tasks are in flight, or by its
    # ensure block when the process exits early.
    #
    # Known limitation (same as Python's): the condition is one-shot and is
    # not aware of prompt messages still queued CLI-side, so an Enumerator
    # prompt yielding several user messages (several turns) releases the hold
    # at the first turn boundary with no tracked tasks; control requests from
    # later turns can then find stdin closed. Single-message and String
    # prompts — the common one-shot shapes — are fully covered.
    def wait_for_result_and_end_input
      @first_result_condition.wait if !@first_result_received && bidirectional_needs?
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

      # NOT Kernel#loop: it rescues StopIteration, so a user block leaking one
      # (e.g. calling .next on an exhausted Enumerator) would silently end
      # reception — ResultMessage dropped, the query reported as complete, and
      # on_error never fired. `while` propagates it like any other error.
      while true # rubocop:disable Style/InfiniteLoop
        message = @message_queue.dequeue
        break if message[:type] == 'end'
        raise message[:error] if message[:type] == 'error'

        block.call(message)
      end
    end

    # Close the query and transport.
    #
    # Callable from any thread. Async::Task#stop needs the reactor's
    # Fiber.scheduler (per-thread), which foreign callers — FiberBoundary
    # workers running a tool handler / hook that calls client.disconnect, or
    # plain user threads — don't have; stopping from one raised NoMethodError
    # and left the read/child tasks running. Such callers hand the close to
    # the reactor-side watcher (spawned in #start) and wait for it to finish,
    # so close semantics are identical regardless of the calling thread.
    def close
      if @close_watcher&.alive? && !Fiber.scheduler.equal?(@owning_scheduler)
        marshal_close_to_reactor
      else
        # Same scheduler (reactor-side caller, including the watcher itself),
        # or no live watcher: when the reactor is gone its task fibers are
        # dead, so stopping them no longer touches Fiber.scheduler.
        close_now
      end
    end

    private

    # The selector actually sent for a targeted background_tasks request.
    #
    # The CLI normalizes "" to "background ALL foreground tasks", so a selector
    # built from a missing id (`id.to_s`) would release every blocking call.
    # Validate the value that goes on the wire, not the caller's object: a
    # private plain-String copy cannot be emptied by another thread between this
    # check and serialization (send_control_request can park on a mutex first),
    # and a String subclass cannot answer `empty?` or `to_json` for it. Never
    # normalize a bad selector to nil, and never strip — a whitespace-only id is
    # still a targeted selector CLI-side, so stripping would widen the request.
    def background_selector(tool_use_id)
      selector = String.new(tool_use_id) if String === tool_use_id # rubocop:disable Style/CaseEquality
      return selector unless selector.nil? || selector.empty?

      raise ArgumentError,
            "tool_use_id must be a non-empty String (got #{tool_use_id.inspect}); " \
            'pass nil explicitly to background all foreground tasks'
    end

    def close_now
      # First caller wins: a reactor-side close racing a watcher-served
      # foreign close (or a repeated disconnect) must not re-run teardown
      # against half-torn-down state — transport.close can suspend mid-reap,
      # and a second pass would race it. Later callers return immediately;
      # the SDK's outer teardown ensures (query() / Client#disconnect) close
      # the transport independently, so nothing is left dangling even if the
      # first pass failed partway.
      first_caller = @close_mutex.synchronize do
        if @close_started
          false
        else
          @close_started = true
        end
      end
      return unless first_caller

      @closed = true
      # Snapshot for the off-reactor fallback, like the response waiters below.
      @callback_request_signals.dup.each_value(&:cancel)
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
      # A close can be called from inside one of the tasks it stops:
      #   - an inline callback (callback_scheduling: :inline) runs on a
      #     control-request handler task that is a CHILD of the read task,
      #     so the read task's unwind (`stopped!` -> `stop_children`)
      #     cascades straight back into this fiber as Async::Stop from
      #     inside `@task.stop` (issue #81);
      #   - a streaming-input enumerator is iterated ON the reactor inside
      #     a spawn_task child tracked in @child_tasks, so
      #     `@child_tasks.each(&:stop)` stops the CURRENT task — a direct
      #     raise (Async::Task#stop on `current?`), no cascade needed.
      # Either way the Stop used to unwind close_now before the transport
      # and @close_requests were closed. `defer_stop` makes both the
      # cascade and the self-stop set a flag instead of raising
      # (Async::Task#stop checks the deferral before the current?/deliver
      # branch), so the whole teardown section runs to completion; the
      # deferred stop is then raised on exit of the block, after the
      # invariant "close returned/raised => transport closed, waiters
      # released, close requests closed" already holds. The caller's task
      # still ends — it belongs to a stopped tree — so its Client#disconnect
      # surfaces as Async::Stop (Python parity: a hook that awaits
      # disconnect() gets CancelledError). Applied ONLY inside the trees of
      # the tasks being stopped: the reactor-side caller (Client#disconnect
      # from the connect task, the close watcher) and foreign threads keep
      # the plain path, unchanged.
      #
      # The deferred Stop SUPERSEDES anything the teardown raises: async
      # raises it from defer_stop's ensure with an explicit `cause:`, so a
      # transport #close error would vanish from the chain entirely. Warn
      # before it is lost. (An inline hook's cooperative timeout landing
      # while the teardown is suspended is superseded the same way; harmless,
      # the handler is ending anyway.)
      if (caller_task = task_inside_stopped_trees)
        caller_task.defer_stop do
          stop_tasks_and_close_transport
        rescue StandardError => e
          warn "Claude SDK: close from inside a stopping task failed during teardown: #{e.class}: #{e.message}"
          raise
        end
      else
        stop_tasks_and_close_transport
      end
    end

    # The teardown section that must run to completion once the read and
    # child tasks are being stopped — see close_now for why a caller inside
    # one of their trees wraps it in defer_stop.
    def stop_tasks_and_close_transport
      # Stop tracked child tasks (e.g. stream_input) before the read task and
      # transport so a parked input stream can never keep the reactor alive
      # (mirrors Python close() cancelling _child_tasks).
      begin
        @child_tasks.each(&:stop)
        @child_tasks.clear
        @task&.stop
      rescue NoMethodError, FiberError => e
        # Schedulerless fallback close (the watcher died unserved) racing
        # reactor teardown: a task fiber can still be unwinding, and stopping
        # it needs the owning thread's Fiber.scheduler. The dying reactor
        # stops its own tasks; the transport close below (plain IO + kill)
        # still runs. On the reactor itself this is a real bug — re-raise.
        raise unless Fiber.scheduler.nil?

        warn "Claude SDK: skipped stopping tasks during off-reactor close: #{e.message}"
      end
      begin
        @transport.close
      ensure
        # Release a still-parked close watcher: pop returns nil and it exits
        # without serving. Any foreign-thread close arriving after this point
        # falls back to a direct close (safe — the fibers are now dead).
        # In the ensure because transport.close can suspend (process reap)
        # and a deadline delivered there — e.g. an inline hook's cooperative
        # timeout, which defer_stop does not cover — must not strand the
        # watcher; this close has no suspension point of its own.
        @close_requests.close
      end
    end

    # The current Async task when it is one of the tasks close_now stops —
    # the read task or a tracked child task (stream_input) — or a descendant
    # of one (a control-request handler running an inline callback); nil
    # otherwise, including on a foreign thread (no task) and for the close
    # watcher / connect task, which are siblings of those tasks.
    def task_inside_stopped_trees
      task = Async::Task.current?
      return nil unless task

      roots = [@task, *@child_tasks].compact
      return nil if roots.empty?

      node = task
      while node
        return task if roots.any? { |root| root.equal?(node) }

        node = node.parent
      end
      nil
    end

    # Hand the close to the reactor and wait for completion. Polls watcher
    # liveness instead of waiting forever: if the reactor shuts down
    # concurrently (the transient watcher is stopped without serving the
    # request), no reply will ever arrive — fall back to a direct close,
    # which is safe once the reactor's fibers are dead.
    def marshal_close_to_reactor
      reply = ::Thread::Queue.new
      @close_requests << reply
      loop do
        return if reply.pop(timeout: 0.1)
        break unless @close_watcher&.alive?
      end
      close_now
    rescue ClosedQueueError
      # The push raced a reactor-side close_now that closed @close_requests.
      close_now
    end
  end
end
