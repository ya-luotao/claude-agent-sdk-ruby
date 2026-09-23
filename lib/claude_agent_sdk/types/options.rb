# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
  # Type constants for setting sources
  SETTING_SOURCES = %w[user project local].freeze

  # Effort levels for `ClaudeAgentOptions#effort`. The CLI (Claude Code 2.1.111+)
  # accepts these values; the set of *supported* levels is model-dependent
  # (e.g. `xhigh` arrived with Opus 4.7 and falls back to `high` on
  # Opus 4.6 / Sonnet 4.6). An Integer is also accepted and forwarded verbatim.
  EFFORT_LEVELS = %w[low medium high xhigh max].freeze

  # Type constants for SDK beta features
  # Available beta features that can be enabled via the betas option
  SDK_BETAS = %w[context-1m-2025-08-07].freeze

  # Claude Agent Options for configuring queries
  class ClaudeAgentOptions < Type
    # `env` routinely carries credentials (ANTHROPIC_API_KEY, ...).
    inspect_filtered :env

    attr_accessor :allowed_tools, :system_prompt, :mcp_servers, :permission_mode,
                  :resume, :resume_session_at, :session_id, :max_turns, :disallowed_tools,
                  :model, :permission_prompt_tool_name, :cwd, :cli_path, :settings,
                  :add_dirs, :env, :extra_args, :max_buffer_size, :stderr,
                  :can_use_tool, :hooks, :user,
                  :agents, :setting_sources, :skills,
                  :output_format, :max_budget_usd, :max_thinking_tokens,
                  :fallback_model, :advisor_model, :plugins, :debug_stderr,
                  :betas, :tools, :sandbox,
                  :thinking, :effort, :observers, :task_budget,
                  :session_store, :session_store_flush, :load_timeout_ms
    attr_reader :bare, :fork_session, :enable_file_checkpointing,
                :include_partial_messages, :continue_conversation,
                :include_hook_events, :strict_mcp_config,
                :callback_scheduling, :callback_wrapper

    # With {#resume_session_at}: the UUID of the user prompt whose turn this
    # truncating resume intends to discard.
    #
    # When set, the CLI validates at load time that every transcript entry
    # after the `resume_session_at` point is attributable to that turn, and
    # refuses the resume otherwise — e.g. when the discarded range contains a
    # queued user message or task notification the session absorbed mid-turn
    # that the caller had not yet observed. Leave unset to keep the
    # unvalidated truncation behavior.
    #
    # **Choosing the fork point.** Set `resume_session_at` to the *last*
    # transcript entry of the turn you are keeping — whatever its type — and
    # `resume_drops_turn` to the prompt UUID of the turn immediately after it
    # (e.g. the next `SessionMessage` of `type == "user"` from
    # {ClaudeAgentSDK.get_session_messages}, or the `uuid` you supplied on a
    # streamed user message). Note that with structured output
    # ({#output_format}) or end-turn MCP tools a kept turn ends on entries
    # *after* its last assistant message, so forking at the assistant UUID is
    # refused by design.
    #
    # **On refusal.** The CLI reports an `error_during_execution` result whose
    # message starts with `Resume rejected by --resume-drops-turn:` — match on
    # that text. Treat it as deterministic: clear the pending fork target and
    # resume plainly rather than retrying the same request.
    #
    # Forwarded whenever it is not `nil`. An empty string reaches the CLI and
    # is rejected there as a malformed declaration rather than being dropped by
    # the SDK, which would silently disarm the guard you believe is armed. The
    # SDK does not validate the option combination (`resume` /
    # `resume_session_at`); like the TypeScript and Python SDKs that is the
    # CLI's call.
    #
    # @return [String, nil]
    # @see #resume_session_at
    attr_accessor :resume_drops_turn

    def initialize(attributes = {})
      self.fork_session = false
      self.continue_conversation = false
      self.include_partial_messages = false
      self.enable_file_checkpointing = false
      self.include_hook_events = false
      self.strict_mcp_config = false
      self.forward_subagent_text = false

      super(merge_with_defaults(attributes || {}))

      # Non-nil defaults for options that need them.
      self.env                 ||= {}
      self.extra_args          ||= {}
      self.mcp_servers         ||= {}
      self.add_dirs            ||= []
      self.observers           ||= []
      self.allowed_tools       ||= []
      self.disallowed_tools    ||= []
      self.session_store_flush ||= 'batched'
      # 0 is a valid (immediate) timeout, so only fill in the default for nil.
      self.load_timeout_ms = 60_000 if load_timeout_ms.nil?
      self.callback_scheduling = :thread if callback_scheduling.nil?
    end

    def dup_with(**changes)
      new_options = self.dup
      # A shallow #dup shares nested containers and typed option values, so
      # mutating a derived copy (e.g. `variant.allowed_tools << 'Bash'` or
      # `variant.sandbox.enabled = false`) would bleed into the base and every
      # sibling — including the security-relevant allow/deny lists and sandbox
      # rules. Deep-dup Hash/Array containers and option value types (Type#
      # dup_for_options, including those nested inside containers such as
      # agents[:x]); every other leaf (procs, SDK MCP server instances, store
      # adapters) keeps its identity.
      new_options.instance_variables.each do |ivar|
        new_options.instance_variable_set(ivar, Type.deep_dup_for_options(new_options.instance_variable_get(ivar)))
      end
      changes.each { |key, value| new_options[key] = value }
      new_options
    end

    def bare?
      !!bare
    end

    def bare=(value)
      @bare = coerce_boolean(value)
    end

    def fork_session?
      !!fork_session
    end

    def fork_session=(value)
      @fork_session = coerce_boolean(value)
    end

    def enable_file_checkpointing?
      !!enable_file_checkpointing
    end

    def enable_file_checkpointing=(value)
      @enable_file_checkpointing = coerce_boolean(value)
    end

    def include_partial_messages?
      !!include_partial_messages
    end

    def include_partial_messages=(value)
      @include_partial_messages = coerce_boolean(value)
    end

    def continue_conversation?
      !!continue_conversation
    end

    def continue_conversation=(value)
      @continue_conversation = coerce_boolean(value)
    end

    def include_hook_events?
      !!include_hook_events
    end

    def include_hook_events=(value)
      @include_hook_events = coerce_boolean(value)
    end

    def strict_mcp_config?
      !!strict_mcp_config
    end

    def strict_mcp_config=(value)
      @strict_mcp_config = coerce_boolean(value)
    end

    # Forward subagent text and thinking blocks as messages in the stream.
    # Defaults to `false`.
    #
    # By default only `tool_use` / `tool_result` blocks from subagents
    # (spawned via the Agent tool) are emitted, as {AssistantMessage} /
    # {UserMessage} objects whose `parent_tool_use_id` is the spawning Agent
    # `tool_use` id — enough for a progress heartbeat. When true, the
    # subagent's text and thinking blocks are forwarded the same way, so
    # consumers can render the full nested transcript. Matches the TypeScript
    # SDK's `forwardSubagentText`.
    #
    # Sent as the `forwardSubagentText` initialize capability rather than a CLI
    # flag, and only when enabled, so an older CLI never sees an unknown key on
    # the common path. Both {ClaudeAgentSDK.query} and {Client} run the control
    # protocol, so the option applies to either entry point.
    #
    # Assigning coerces to a Boolean; {#forward_subagent_text?} is the
    # predicate form.
    #
    # @return [Boolean]
    attr_reader :forward_subagent_text

    # @return [Boolean] {#forward_subagent_text}, as a strict Boolean.
    def forward_subagent_text?
      !!forward_subagent_text
    end

    # @see #forward_subagent_text
    def forward_subagent_text=(value)
      @forward_subagent_text = coerce_boolean(value)
    end

    # Request model-generated progress summaries for subagent (`local_agent`)
    # tasks. `true` *requests* generation: while the CLI has it enabled, a
    # subagent's {TaskProgressMessage#summary} **may** carry a one-line status.
    # `summary` stays optional on the wire even then — not every progress
    # frame has one — so read it nil-safely. `false` / `nil` do not enable
    # generation; they do not promise that `summary` is absent (a process that
    # already enabled summaries keeps them, and a backgrounded `mcp_task`
    # reports its own status there regardless of this option). Matches the
    # CLI's `agentProgressSummaries` initialize field.
    #
    # Defaults to `nil` (unset): the key is omitted from the `initialize`
    # control request. `true` and `false` are forwarded verbatim. This is an
    # enable switch, not a live toggle: CLI 2.1.278 only acts on a truthy
    # value, so `false` is schema-valid but equivalent to leaving the option
    # unset — it does not switch summaries off on a process that already
    # enabled them. Both {ClaudeAgentSDK.query} and {Client} run the control
    # protocol, so the option applies to either entry point.
    #
    # Assigning coerces to a Boolean and keeps `nil` as `nil`.
    #
    # @return [Boolean, nil]
    attr_reader :agent_progress_summaries

    # @see #agent_progress_summaries
    def agent_progress_summaries=(value)
      @agent_progress_summaries = coerce_boolean(value)
    end

    CALLBACK_SCHEDULING_MODES = %i[thread inline].freeze

    # Where user callbacks (hooks, can_use_tool, SDK MCP handlers, message
    # blocks, observers) run when the SDK is hosted inside an Async reactor:
    #   :thread (default) — each callback hops to a plain thread, so
    #     thread-keyed libraries (ActiveRecord, pg, ...) behave as usual.
    #   :inline — callbacks run in place on the reactor fiber. Only for
    #     hosts that are fiber-isolated end to end (e.g. solid_queue fiber
    #     workers with IsolatedExecutionState.isolation_level = :fiber).
    #     Scheduler-opaque blocking (CPU-bound work, GVL-holding C
    #     extensions) then stalls the whole reactor — wrap GVL-releasing
    #     blocking and Ruby CPU work in ClaudeAgentSDK.offload { }; work
    #     that holds the GVL throughout needs a subprocess.
    # Named after the mechanism, not a safety claim: whether inline is safe
    # depends on the host satisfying the fiber-isolation precondition.
    def callback_scheduling=(value)
      if value.nil?
        @callback_scheduling = nil
        return
      end

      mode = value.respond_to?(:to_sym) ? value.to_sym : value
      unless CALLBACK_SCHEDULING_MODES.include?(mode)
        raise ArgumentError,
              "callback_scheduling must be one of #{CALLBACK_SCHEDULING_MODES.map(&:inspect).join(', ')} " \
              "(got #{value.inspect})"
      end

      @callback_scheduling = mode
    end

    # Middleware wrapped around EVERY user-callback dispatch (message
    # blocks, observers, hooks, permission callbacks, SDK MCP handlers).
    # A callable receiving a zero-arg invocation; it MUST call it and
    # return its value:
    #
    #   callback_wrapper: ->(invocation) { MyApm.trace('agent.callback') { invocation.call } }
    #
    # The wrapper runs on the same execution context as the callback —
    # inside the worker thread in :thread mode, in place on the reactor
    # fiber in :inline mode. Exceptions propagate through it unchanged; it
    # must not swallow them. Default nil (no wrapping).
    #
    # Rails apps: use ClaudeAgentSDK::Railtie.callback_wrapper, which runs
    # callbacks in the Rails executor (AR connections check back in when the
    # callback ends). A bare `Rails.application.executor.wrap` deadlocks
    # under development code reloading in :thread mode.
    def callback_wrapper=(value)
      unless value.nil? || value.respond_to?(:call)
        raise ArgumentError, "callback_wrapper must be a callable or nil (got #{value.inspect})"
      end

      @callback_wrapper = value
    end

    private

    # Strict key validation: unlike other Type subclasses (which silently drop
    # unknown keys for forward-compat with newer CLI output), ClaudeAgentOptions
    # is a developer-facing config object — typos should fail loudly.
    def assign_attribute(name, value)
      setter = :"#{normalize_name(name)}="
      raise ArgumentError, "unknown ClaudeAgentOptions option: #{name.inspect}" unless respond_to?(setter)

      public_send(setter, value)
    end

    # Merge caller-provided attributes with configured defaults.
    # Only keys the caller explicitly passed are treated as overrides;
    # method-signature defaults ([], {}, false) are NOT present unless the caller wrote them.
    #
    # Both sides are keyed by the option they name, not by their literal
    # spelling: Type accepts symbol/string and snake_case/camelCase names, so a
    # caller's `'permissionMode' => nil` must still inherit a configured
    # `permission_mode:` (and a Hash must still merge into it) rather than
    # riding along as a second entry that overwrites the default on assignment.
    def merge_with_defaults(attributes)
      return attributes unless defined?(ClaudeAgentSDK) && ClaudeAgentSDK.respond_to?(:default_options)

      defaults = ClaudeAgentSDK.default_options
      return attributes unless defaults.any?

      # Start from configured defaults. Container values, typed option
      # values (SandboxSettings, SystemPromptPreset, AgentDefinition, ...)
      # and mutable Strings are recursively copied (Type.deep_dup_for_options)
      # so per-instance mutation (options.allowed_tools << 'Bash',
      # options.sandbox.enabled = false) can never corrupt the global
      # defaults or reach another session; other leaves (frozen Strings,
      # Procs, SdkMcpServer instances, store adapters) intentionally keep
      # identity. The stored defaults are a frozen snapshot
      # (Configuration#default_options=), and the copy is what makes each
      # session's containers and values mutable again — its Strings stay the
      # snapshot's frozen ones, so `options.model << 'x'` fails loudly rather
      # than reaching other sessions; reassign instead.
      result = {}
      defaults.each { |key, value| result[option_key(key)] = Type.deep_dup_for_options(value) }
      attributes.each do |key, value|
        key = option_key(key)
        default_val = result[key]
        result[key] = if value.nil?
                        default_val # nil means "no preference" — keep the configured default
                      elsif default_val.is_a?(Hash) && value.is_a?(Hash)
                        default_val.merge(value)
                      else
                        value
                      end
      end
      result
    end

    # The canonical Symbol for a known option, whatever its spelling. An
    # unknown name is returned untouched so assign_attribute's strict check
    # reports the typo exactly as the developer wrote it.
    def option_key(name)
      normalized = normalize_name(name)
      respond_to?(:"#{normalized}=") ? normalized.to_sym : name
    end
  end
end
