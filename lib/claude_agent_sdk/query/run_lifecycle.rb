# frozen_string_literal: true

require 'async/condition'

module ClaudeAgentSDK
  class Query
    # When stdin may close: one run's end, decided from the CLI's frames and one
    # timer (the ceiling). Reactor-only, like every caller: no mutex, and never
    # reached from a FiberBoundary thread or from Query#close_now. An event may
    # hand execution to another fiber mid-call, at RunEnd#end!'s signal, the
    # sleeper's async, a handle's #stop and #wait. So the order is the contract:
    # #end_run marks the run ended BEFORE it signals or stops the sleeper (a
    # message written in that gap gets a run of its own); a ceiling that wakes
    # checks its generation, detaches, then acts, and re-arms instead of ending
    # while the SDK still answers a control request. The sleeper is a child of
    # the read task and every exit path clears it (#reader_gone, #stdin_closing).
    #
    # @api private
    class RunLifecycle
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

      # Frame types that mark a main-thread turn under way (when they carry no
      # parent_tool_use_id), and the states that do not re-arm the ceiling.
      TURN_FRAME_TYPES = %w[assistant stream_event].freeze
      NON_RUNNING_SESSION_STATES = %w[idle requires_action].freeze

      # One run's end, set at most once (the Python SDK's per-run anyio.Event).
      # A waiter holds the object it started waiting on, so a run that ends and
      # is then reopened (#reopen_run swaps in a fresh RunEnd) still releases the
      # waiters the ended run woke, while later waits wait for the new run.
      # Reactor-only, like every caller.
      class RunEnd
        def initialize
          @ended = false
          @condition = Async::Condition.new
        end

        def ended?
          @ended
        end

        def end!
          return if @ended

          @ended = true
          @condition.signal
        end

        def wait
          @condition.wait until @ended
        end
      end

      # The CLI's latest session_state_changed state, or nil while it sends
      # none (a CLI too old to honor CLAUDE_CODE_SDK_READS_SESSION_STATE). A
      # CLI that reports state stays "running" while a background agent is
      # live or its completion is still to be handled, and reports "idle" once
      # no further turn is owed.
      attr_reader :session_state

      # +ceiling_ms+ bounds the wait between turns (0 = never armed; see #arm).
      # +sleeper+ is called as `sleeper.call(seconds) { ... }`: it runs the block
      # once +seconds+ have passed and returns a handle that responds to #stop
      # (Query#sleep_on_read_task in production). The three predicates read
      # Query's facts when they are called and must not suspend.
      def initialize(ceiling_ms:, sleeper:, bidirectional_needs:, closed:, control_requests_in_flight:)
        @ceiling_ms = ceiling_ms
        @sleeper = sleeper
        @bidirectional_needs = bidirectional_needs
        @closed = closed
        @control_requests_in_flight = control_requests_in_flight
        # Ends when the run is over, so the stdin-closing waiter can wake (Python
        # #1088, #1190/#1279). Work the CLI takes up after the run ended swaps in
        # a fresh one (#reopen_run).
        @run_end = RunEnd.new
        @result_received = false
        @session_state = nil
        # Ends the run if no new turn starts within the ceiling after a result
        # (#arm). The generation tells a sleeper that woke after it was cleared
        # or re-armed to stand down; it only ever grows.
        @ceiling_handle = nil
        @ceiling_generation = 0
        # A main-thread turn is under way (its assistant/stream_event frames
        # have started and its result has not arrived): the ceiling counts only
        # the wait between turns, so it is not armed meanwhile.
        @turn_in_progress = false
        # Set once stdin is closed or the reader is gone: the run then stays
        # ended, since nothing can wait on a reopened one.
        @final = false
        # Task IDs of started-but-not-finished deferring tasks. A result frame
        # only ends one turn, not the run: a background task keeps running past
        # it and still needs stdin for hook/SDK-MCP control responses (Python
        # #1088/#1103), so a result that arrives while this set is non-empty
        # must not close stdin.
        @inflight_tasks = Set.new
      end

      # One frame the read loop did not route elsewhere (anything but control
      # and transcript_mirror frames), frames marked sdk_host_only included;
      # for a result, after the mirror flush.
      def frame(message)
        type = message[:type]
        if type == 'system'
          on_system(message)
        elsif type == 'result'
          on_result
        elsif TURN_FRAME_TYPES.include?(type) && message[:parent_tool_use_id].nil?
          on_main_thread_turn
        end
      end

      # A user message was serialized and is about to be written. It owes a run
      # of its own, result included: an earlier one having ended does not end it.
      def message_will_write
        reopen_run
        @result_received = false
        clear
      end

      # Wait for the end of the run that is current now, when the CLI may still
      # send control requests that need a reply; return at once otherwise.
      def wait
        @run_end.wait if @bidirectional_needs.call
      end

      # Stdin is about to close after a wait: no run can be reopened any more.
      def stdin_closing
        @final = true
        clear
      end

      # Stdin is about to close with nothing written: final, but an armed
      # sleeper is left for the read task's stop and the run is not ended
      # (the #1226 trade-off; see Query#stream_input).
      def empty_input
        @final = true
      end

      # The read loop is over: wake the stdin-closing waiter so it does not
      # stall on early exit; with the reader gone the run stays ended. Also
      # stops a pending sleeper, which would otherwise keep the reactor alive.
      def reader_gone
        @final = true
        end_run
      end

      def ended?
        @run_end.ended?
      end

      def final?
        @final
      end

      def ceiling_armed?
        !@ceiling_handle.nil?
      end

      def inflight?(task_id)
        @inflight_tasks.include?(task_id)
      end

      private

      # Track task lifecycle frames so results can tell "one turn ended" apart
      # from "the run is done" (Python #1088/#1103), then the session state.
      def on_system(message)
        had_tasks_in_flight = !@inflight_tasks.empty?
        track_task_lifecycle(message)
        # The ceiling left the last tracked agent alone; the wait between
        # turns starts over now that it settled.
        rearm_between_turns if had_tasks_in_flight && @inflight_tasks.empty?
        on_session_state(message[:state]) if message[:subtype] == 'session_state_changed'
      end

      # A main-thread turn is under way, so the ceiling stops (it counts only
      # the wait between turns, as the CLI's does) and the run reopens even if
      # the ceiling ended it while no state changed.
      def on_main_thread_turn
        @turn_in_progress = true
        reopen_run
        clear
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

      # A result ends a turn, not necessarily the run: a background agent that
      # finished just before it still wakes the session for another turn, whose
      # hook, permission and SDK MCP requests need stdin (Python #1190/#1279). A
      # CLI that reports session state stays "running" while such a turn is
      # owed, so wait for "idle" (some hosts send it just before the result).
      # Without state events the result is all there is to go on.
      def on_result
        @result_received = true
        @turn_in_progress = false
        if @session_state.nil? || @session_state == 'idle' || !@bidirectional_needs.call
          maybe_end_run
        elsif @session_state != 'requires_action'
          # While the SDK is still answering a request the ceiling waits for
          # the "running" that follows.
          arm
        end
      end

      # Track the CLI's session_state_changed state (Python #1279).
      def on_session_state(state)
        @session_state = state
        if state == 'idle'
          maybe_end_run if @result_received
          return
        end
        # Work the CLI took up after the run ended (a finished background task
        # woke it) reopens the run until the next "idle".
        reopen_run
        if state == 'requires_action'
          # The host is answering a request; stdin must outlast it.
          clear
        else
          rearm_between_turns
        end
      end

      # End the run unless a tracked background task is still in flight: such
      # a task may still need hook/SDK-MCP control responses over stdin
      # (Python #1088), and its completion wakes the parent for a follow-up
      # turn whose result (or "idle") ends the run then. A CLI that reports
      # session state never reports "idle" with an agent still live, so this
      # matters for CLIs that report "idle" at every turn end or not at all.
      def maybe_end_run
        end_run if @inflight_tasks.empty?
      end

      # The run is over: wake the stdin-closing waiter. Idempotent.
      #
      # The run is marked ended BEFORE the ceiling is cleared: stopping the
      # sleeper yields to whatever else is ready, and a Query#stream_input task
      # that writes its next message in that gap must find the run already
      # ended, so that #reopen_run gives the message a run of its own. Cleared
      # first, the message joined the run that was about to end, and stdin
      # closed before the message's own run had produced a frame.
      def end_run
        @run_end.end!
        clear
      end

      # Reopen an ended run for work that started after it ended. A waiter the
      # ended run already woke still closes stdin; this makes a later wait
      # (Query#stream_input's, once its prompts are all written) wait for the
      # new work too. Once stdin is closed, or the reader is gone, the run
      # stays ended.
      def reopen_run
        @run_end = RunEnd.new if @run_end.ended? && !@final
      end

      # End the run anyway once the ceiling passes with no new turn. The CLI's
      # own background-wait ceiling only counts once stdin is closed, so without
      # this, work that never finishes would hold "running", and stdin, open
      # forever. It counts only the wait between turns: restarted at each result
      # and whenever the CLI reports "running" again, cleared by main-thread
      # turn activity and by "requires_action", never armed mid-turn.
      #
      # Every exit path clears the sleeper (#end_run from #reader_gone,
      # #stdin_closing), so a pending one can never keep the enclosing reactor
      # alive; the production sleeper is a child of the read task besides
      # (Query#sleep_on_read_task).
      def arm
        clear
        # A frame read while close is under way (the read loop flushes the
        # mirror before a result gets here) must not leave a sleeper behind
        # either.
        return if @ceiling_ms <= 0 || @run_end.ended? || @final || @closed.call ||
                  @turn_in_progress || !@bidirectional_needs.call

        generation = @ceiling_generation
        seconds = [@ceiling_ms, MAX_RUN_END_CEILING_MS].min / 1000.0
        @ceiling_handle = @sleeper.call(seconds) { ceiling_passed(generation) }
      end

      # Restart the ceiling if the run is between turns, past a result, with
      # the CLI still reporting work ("running").
      def rearm_between_turns
        return unless @result_received
        return if @session_state.nil? || NON_RUNNING_SESSION_STATES.include?(@session_state)

        arm
      end

      def ceiling_passed(generation)
        # Cleared or re-armed while this sleeper was already waking up.
        return unless generation == @ceiling_generation

        # Detach before ending the run: #end_run clears the ceiling, and
        # clearing it must not stop the task running this very method.
        @ceiling_handle = nil
        # A tracked background agent still running may still need stdin for its
        # hook, permission and SDK MCP requests (Python #1088), so it is not cut
        # off; the ceiling starts over once it settles (#on_system).
        return unless @inflight_tasks.empty?

        # A control request the SDK is still answering (a slow hook or SDK MCP
        # tool) must be able to write its reply, so the clock starts over rather
        # than closing stdin under it. Ruby-only guard: Python relies on the CLI
        # reporting requires_action for every such request.
        return arm if @control_requests_in_flight.call

        end_run
      end

      def clear
        @ceiling_generation += 1
        handle = @ceiling_handle
        @ceiling_handle = nil
        handle&.stop
      end
    end
  end
end
