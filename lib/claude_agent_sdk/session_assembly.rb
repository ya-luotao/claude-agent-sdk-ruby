# frozen_string_literal: true

require_relative 'fiber_boundary'
require_relative 'message_parser'
require_relative 'query'
require_relative 'session_resume'
require_relative 'subprocess_cli_transport'

module ClaudeAgentSDK
  # The three things every dispatch of a session's user code needs — its
  # resolved observers, where callbacks run (callback_scheduling) and the
  # middleware around them (callback_wrapper) — bound once, so that no call
  # site threads them by hand. A context holder, nothing deeper: each method
  # is the module function it names, called with the triple.
  #
  # @api private
  class Dispatch
    # For what takes the pair as its own arguments (Query, the transcript
    # mirror batcher).
    attr_reader :scheduling, :wrapper

    def initialize(observers, scheduling:, wrapper:)
      @observers = observers
      @scheduling = scheduling
      @wrapper = wrapper
    end

    # The same scheduling and wrapper around other observers. Client captures
    # the pair when it is constructed and resolves its observers on each
    # connect.
    def with_observers(observers)
      self.class.new(observers, scheduling: @scheduling, wrapper: @wrapper)
    end

    # See ClaudeAgentSDK.notify_observers.
    def notify(method, *)
      ClaudeAgentSDK.notify_observers(@observers, method, *, scheduling: @scheduling, wrapper: @wrapper)
    end

    # See ClaudeAgentSDK.observing_prompt_stream.
    def observing_stream(prompt)
      ClaudeAgentSDK.observing_prompt_stream(prompt, @observers, scheduling: @scheduling, wrapper: @wrapper)
    end

    # See FiberBoundary.invoke_iteration.
    def invoke_iteration(block, message)
      FiberBoundary.invoke_iteration(block, message, scheduling: @scheduling, wrapper: @wrapper)
    end
  end

  # The resources of one session and what is done with them: acquiring the
  # transport, the Query on top of it and (for a store-backed resume) the
  # materialized config dir; writing prompts; delivering messages; disposing
  # of all three.
  #
  # This is implementation shared by the two entry points, ClaudeAgentSDK.query
  # and Client, not a lifecycle of its own. When to connect, what observers are
  # told, which error wins and whether stdin is closed after a prompt differ
  # between the two and stay with them; so nothing here notifies on_error or
  # on_close, and nothing here rescues.
  #
  # @api private
  class SessionAssembly
    # For #write_prompt: stamp with the verbatim_prompts value #connect captured.
    CAPTURED = :captured

    # The session's control-protocol handler: nil before #connect and after
    # #close_resources. The only state that is read from outside.
    attr_reader :query_handler

    # Acquires nothing. +transport_source+ says where the transport comes from:
    #
    #   { instance: transport }          one the caller built (query(transport:))
    #   { class: klass, args: kwargs }   one to construct as klass.new(options, **kwargs)
    #
    # +configured_options+ are the options after can_use_tool routing and
    # validation; #connect may replace them with a copy repointed at a
    # materialized resume.
    def initialize(configured_options, dispatch:, transport_source:)
      @options = configured_options
      @dispatch = dispatch
      @transport_source = transport_source
      @transport = nil
      @query_handler = nil
      @materialized = nil
      @verbatim_prompts = false
    end

    # Acquire, in order: the materialized resume (when it applies) and the
    # options repointed at it, the transport, its connection, the Query, the
    # transcript mirror (before the read loop starts, so that it sees every
    # transcript_mirror frame), the read loop, the handshake.
    #
    # Each resource is recorded before the next step that can fail and nothing
    # is rolled back here: whatever a step raises propagates, and the caller's
    # own rescue calls #close_resources.
    def connect
      @transport = acquire_transport
      @transport.connect

      # Read once, here: after the transport connected (its #connect may still
      # change the options it was given) and before the Query is built. The
      # Query stamps streamed prompts with this value, and #write_prompt /
      # #write_message stamp theirs with it too unless told otherwise, so one
      # session marks all of them alike.
      @verbatim_prompts = @options.verbatim_prompts?
      @query_handler = build_query_handler
      install_transcript_mirror

      @query_handler.start
      @query_handler.initialize_protocol
    end

    # Write a String prompt as one user message. The caller notifies
    # on_user_prompt first: the order is its own, and so is what may happen to
    # the options in between.
    #
    #   verbatim: CAPTURED       the value #connect captured (Client)
    #   verbatim: :current       read from the options the session runs on, now
    #                            (query(): after its on_user_prompt notification)
    #   verbatim: true / false   that value
    #
    # The options the session runs on are the repointed copy when a
    # store-backed resume was materialized, the configured ones otherwise.
    def write_prompt(prompt, session_id:, verbatim: CAPTURED)
      message = {
        type: 'user',
        message: { role: 'user', content: prompt },
        parent_tool_use_id: nil,
        session_id: session_id
      }
      writeln(Query.serialize_user_message(message, verbatim_value(verbatim)))
    end

    # Write one user message that already has its shape (a Hash, or a JSONL
    # String), stamped with the captured verbatim_prompts value. Serialized
    # first: a message that cannot be marked raises before anything is written.
    def write_message(message)
      writeln(Query.serialize_user_message(message, @verbatim_prompts))
    end

    # Stream an Enumerable prompt as the session's input, in the background.
    # The task is tracked on the Query, so closing it stops the stream;
    # Query#stream_input closes stdin once the stream is exhausted and its
    # last run is over, and swallows the stream's own errors with a warning.
    # Observers get on_user_prompt for each user message before it is written.
    def stream_prompt_in_background(prompt)
      handler = @query_handler
      observed = @dispatch.observing_stream(prompt)
      handler.spawn_task { handler.stream_input(observed) }
    end

    # Deliver the session's messages to +block+: parse each frame, notify
    # on_message, then invoke the block across the FiberBoundary. Returns the
    # value of the block's `break` when it broke. With until_result: true the
    # ResultMessage is the last message delivered.
    #
    # Loop control stays on this fiber, the one that dequeues: both breaks
    # happen here, never inside the hop (a `break` in a proc on another thread
    # raises LocalJumpError; Dispatch#invoke_iteration hands it back as a
    # Break). Errors propagate; notifying on_error is the caller's.
    def deliver(block, until_result: false)
      @query_handler.receive_messages do |data|
        message = MessageParser.parse(data)
        next unless message

        @dispatch.notify(:on_message, message)
        signal = @dispatch.invoke_iteration(block, message)
        break signal.value if signal.is_a?(FiberBoundary::Break)
        break if until_result && message.is_a?(ResultMessage)
      end
    end

    # Dispose of whatever #connect acquired, however far it got: close the
    # Query (which flushes the transcript mirror and closes the transport),
    # close the transport, decide what happens to the materialized resume dir.
    #
    #   always_close_transport: true    the transport is closed in an ensure of
    #                                   its own, also when closing the Query
    #                                   raised (Client)
    #   always_close_transport: false   the transport is closed only when no
    #                                   Query was built (query())
    #
    # Transport#close is idempotent, so the second close is harmless. The
    # nested ensures run every later step when an earlier one raises, and the
    # last error raised is the one that propagates.
    #
    # A block, when given, is called once both closes are behind and before
    # the materialized dir is dealt with — also when a close raised. From
    # there on nothing of the session can be used any more, while removing
    # the directory can still take a while (it retries, sleeping, when the
    # directory is busy) and lets other tasks run meanwhile: the caller marks
    # itself disconnected in the block, so that calls made in that window are
    # refused instead of reaching a session that is half gone.
    def close_resources(always_close_transport:)
      # Kept past the nil-out below: whether the mirror dropped batches is
      # final only after #close ran its last flush.
      handler = @query_handler
      begin
        handler&.close
      ensure
        @query_handler = nil
        begin
          @transport&.close if always_close_transport || handler.nil?
        ensure
          @transport = nil
          yield if block_given?
          dispose_of_materialized_resume(handler)
        end
      end
    end

    private

    # An injected transport was built before any repointing could reach it,
    # so nothing is materialized for it. A class is constructed after
    # materialization, with the repointed options.
    def acquire_transport
      return @transport_source.fetch(:instance) if @transport_source.key?(:instance)

      transport_class = @transport_source.fetch(:class)
      materialize_resume if @options.session_store && spawns_cli_locally?(transport_class)
      transport_class.new(@options, **@transport_source.fetch(:args))
    end

    # The materialized config dir and --resume reach a transport only through
    # the options it is constructed with, and mean something only to one that
    # spawns the CLI on this host with them: SubprocessCLITransport or a
    # subclass of it (ancestry, not identity). The source may be a duck-typed
    # factory rather than a Class.
    def spawns_cli_locally?(transport_class)
      transport_class.is_a?(Class) && transport_class <= SubprocessCLITransport
    end

    # Resume-from-store: load the session from the store into a temp
    # CLAUDE_CONFIG_DIR and repoint the options at it (env + --resume). The
    # directory is recorded before the repointing, so a failure there still
    # leaves it to #close_resources.
    def materialize_resume
      @materialized = SessionResume.materialize_resume_session(@options)
      @options = SessionResume.apply_materialized_options(@options, @materialized) if @materialized
    end

    # The one place a Query is built from options. Streaming mode with the
    # control protocol, always (as in the Python SDK): agents travel in the
    # initialize request rather than in CLI arguments, clear of ARG_MAX.
    def build_query_handler
      Query.new(
        transport: @transport,
        is_streaming_mode: true,
        can_use_tool: @options.can_use_tool,
        hooks: ClaudeAgentSDK.convert_hooks_to_internal_format(@options.hooks),
        sdk_mcp_servers: ClaudeAgentSDK.extract_sdk_mcp_servers(@options.mcp_servers),
        agents: @options.agents,
        exclude_dynamic_sections: ClaudeAgentSDK.extract_exclude_dynamic_sections(@options.system_prompt),
        system_prompt_snapshot: ClaudeAgentSDK.extract_system_prompt_snapshot(@options.system_prompt),
        skills: @options.skills,
        forward_subagent_text: @options.forward_subagent_text?,
        agent_progress_summaries: @options.agent_progress_summaries,
        callback_scheduling: @dispatch.scheduling,
        callback_wrapper: @dispatch.wrapper,
        verbatim_prompts: @verbatim_prompts,
        run_end_ceiling_ms: Query.run_end_ceiling_ms(@options.env)
      )
    end

    # Mirror transcripts to the session_store, if one is configured.
    def install_transcript_mirror
      return unless @options.session_store

      handler = @query_handler
      handler.set_transcript_mirror_batcher(
        SessionResume.build_mirror_batcher(
          store: @options.session_store,
          env: @options.env,
          on_error: ->(key, message) { handler.report_mirror_error(key, message) },
          eager: @options.session_store_flush.to_s == 'eager',
          callback_wrapper: @dispatch.wrapper
        )
      )
    end

    def verbatim_value(verbatim)
      case verbatim
      when CAPTURED then @verbatim_prompts
      when :current then @options.verbatim_prompts?
      else verbatim
      end
    end

    def writeln(string)
      @transport.write(string.end_with?("\n") ? string : "#{string}\n")
    end

    # The materialized resume dir holds a redacted .credentials.json copy, so
    # it is removed once the subprocess has exited — unless the mirror dropped
    # batches: the store copy is then incomplete and the dir holds the only
    # copy of the dropped turns, so it is preserved (scrubbed of credentials)
    # with a warning instead.
    def dispose_of_materialized_resume(handler)
      return unless @materialized

      handler&.mirror_batches_dropped? ? @materialized.preserve_transcripts : @materialized.cleanup
      @materialized = nil
    end
  end
end
