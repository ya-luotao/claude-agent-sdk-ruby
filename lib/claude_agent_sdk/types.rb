# frozen_string_literal: true

module ClaudeAgentSDK
  # Type constants for permission modes
  PERMISSION_MODES = %w[default acceptEdits plan bypassPermissions dontAsk auto].freeze

  # Type constants for setting sources
  SETTING_SOURCES = %w[user project local].freeze

  # Effort levels for `ClaudeAgentOptions#effort`. The CLI (Claude Code 2.1.111+)
  # accepts these values; the set of *supported* levels is model-dependent
  # (e.g. `xhigh` arrived with Opus 4.7 and falls back to `high` on
  # Opus 4.6 / Sonnet 4.6). An Integer is also accepted and forwarded verbatim.
  EFFORT_LEVELS = %w[low medium high xhigh max].freeze

  # Type constants for permission update destinations
  PERMISSION_UPDATE_DESTINATIONS = %w[userSettings projectSettings localSettings session].freeze

  # Type constants for permission behaviors
  PERMISSION_BEHAVIORS = %w[allow deny ask].freeze

  # Type constants for hook events
  HOOK_EVENTS = %w[
    PreToolUse
    PostToolUse
    PostToolUseFailure
    Notification
    UserPromptSubmit
    SessionStart
    SessionEnd
    Stop
    StopFailure
    SubagentStart
    SubagentStop
    PreCompact
    PostCompact
    PermissionRequest
    PermissionDenied
    Setup
    TeammateIdle
    TaskCreated
    TaskCompleted
    Elicitation
    ElicitationResult
    ConfigChange
    WorktreeCreate
    WorktreeRemove
    InstructionsLoaded
    CwdChanged
    FileChanged
  ].freeze

  # Type constants for assistant message errors
  ASSISTANT_MESSAGE_ERRORS = %w[authentication_failed billing_error rate_limit invalid_request server_error max_output_tokens unknown].freeze

  # Type constants for SDK beta features
  # Available beta features that can be enabled via the betas option
  SDK_BETAS = %w[context-1m-2025-08-07].freeze

  # Base class for all types.
  class Type
    def self.wrap(object)
      return object if object.is_a?(self)
      return nil if object.nil?

      new(object)
    end

    def self.from_hash(hash)
      return unless hash.is_a?(Hash)

      new(hash)
    end

    def initialize(attributes = {})
      assign_attributes(attributes) if attributes
      super()
    end

    def [](name)
      read_attribute(name)
    end

    def []=(name, value)
      assign_attribute(name, value)
    end

    # Subclasses should override this to return a hash representation of the object.
    def to_h
      {}
    end

    # The copy hook used wherever ClaudeAgentOptions are copied (dup_with and
    # the configured-defaults merge). Identity by default: most Type instances
    # are messages or callback payloads that never live inside options, and a
    # user-supplied object that does (an observer, a store adapter) must stay
    # the same object. Option VALUE types include OptionValue to opt in to
    # copying, so a per-session change to e.g. sandbox rules can never reach
    # another session or the configured defaults.
    def dup_for_options
      self
    end

    # Mixed into the mutable value types that ClaudeAgentOptions holds
    # (SandboxSettings, SystemPromptPreset, AgentDefinition, ...). The copy
    # recurses into the value's own state with Type.deep_dup_for_options, so
    # nested containers and nested value types (SandboxSettings#network) are
    # copied too while identity leaves (McpSdkServerConfig#instance, the
    # callables in HookMatcher#hooks) stay shared. #dup never copies frozen
    # state, so a copy of a frozen value (the configured-defaults snapshot) is
    # mutable.
    module OptionValue
      def dup_for_options
        copy = dup
        copy.instance_variables.each do |ivar|
          copy.instance_variable_set(ivar, Type.deep_dup_for_options(copy.instance_variable_get(ivar)))
        end
        copy
      end
    end

    # Recurse into Hash/Array containers and option value types, and copy
    # mutable (unfrozen) Strings — a caller-built prompt, model or
    # allowed_tools entry is as much shared state as an Array, and `str <<
    # 'x'` on one copy would otherwise change every other. A frozen String
    # (any literal under frozen_string_literal) is immutable and keeps
    # identity. Every other leaf keeps object identity (observer factories,
    # callbacks, SDK MCP server instances must not be duped). Rebuild
    # containers via dup.clear (never Hash#to_h / Array#map) to preserve
    # container SUBCLASSES: to_h flattens e.g. Rails'
    # HashWithIndifferentAccess into a plain Hash, silently breaking symbol
    # lookups on the copy (config[:type] == 'sdk' → nil). Hash keys: Ruby
    # already stores a dup'd, frozen copy of an unfrozen plain String key, but
    # not of a String SUBCLASS key, so those are copied (and frozen, as keys
    # should be) here. A compare_by_identity Hash is left keyed by the
    # caller's objects: copying a key would break the caller's own lookups.
    def self.deep_dup_for_options(value)
      case value
      when Hash
        copy = value.dup.clear
        value.each { |k, v| copy[option_hash_key(k, value)] = deep_dup_for_options(v) }
        copy
      when Array
        copy = value.dup.clear
        value.each { |v| copy << deep_dup_for_options(v) }
        copy
      when Type then value.dup_for_options
      when String then value.frozen? ? value : value.dup # #dup keeps subclass and encoding
      else value
      end
    end

    def self.option_hash_key(key, hash)
      return key unless key.is_a?(String) && !key.frozen? && !hash.compare_by_identity?

      key.dup.freeze
    end
    private_class_method :option_hash_key

    # Bounded, human-oriented #inspect listing the non-nil instance variables
    # in definition order:
    #
    #   #<ClaudeAgentSDK::ResultMessage subtype="success" num_turns=3 ...>
    #
    # Messages carry whole transcripts, tool payloads and usage maps, so the
    # output is bounded rather than faithful: long Strings are truncated,
    # long Arrays/Hashes abbreviated, and nesting past INSPECT_MAX_DEPTH (or
    # a reference cycle) collapses to a placeholder. Other objects keep their
    # own #inspect (truncated) unless they only have Kernel#inspect, which
    # dumps every ivar recursively — those (SDK MCP server instances, store
    # adapters, observers) show as `#<ClassName>`. For display only: nothing
    # sent to the CLI goes through #inspect or #to_s (wire output uses #to_h).
    def inspect
      inspect_with(0, {}.compare_by_identity)
    end

    # Object#to_s ignores instance variables, so `puts message` would print
    # only a class name and an address. Types with a natural textual form
    # (UserMessage, AssistantMessage, TextBlock, ResultMessage, SystemMessage)
    # override this.
    def to_s
      inspect
    end

    # Declares attributes that carry credentials (env vars, auth headers).
    # Objects get logged, so #inspect shows them filtered; #to_h and
    # everything sent to the CLI are unaffected. Inherited by subclasses.
    def self.inspect_filtered(*names)
      @inspect_filtered_attributes = (inspect_filtered_attributes + names.map(&:to_s)).uniq.freeze
    end

    def self.inspect_filtered_attributes
      @inspect_filtered_attributes || (superclass <= Type ? superclass.inspect_filtered_attributes : [].freeze)
    end

    INSPECT_MAX_STRING = 80
    INSPECT_MAX_ITEMS = 5
    INSPECT_MAX_DEPTH = 2
    private_constant :INSPECT_MAX_STRING, :INSPECT_MAX_ITEMS, :INSPECT_MAX_DEPTH

    protected

    # `seen` holds the Types/containers on the current rendering path (not
    # every one rendered so far), so a shared-but-acyclic value still renders
    # in full wherever it appears.
    def inspect_with(depth, seen)
      return "#<#{inspect_class_name} …>" if depth > INSPECT_MAX_DEPTH || seen.key?(self)

      seen[self] = true
      begin
        attributes = inspect_attributes.map do |name, value|
          " #{name}=#{inspect_bounded(value, depth + 1, seen)}"
        end
        "#<#{inspect_class_name}#{attributes.join}>"
      ensure
        seen.delete(self)
      end
    end

    private

    # [name, value] pairs rendered by #inspect. Subclasses override to hide
    # redundant state or redact secrets — never by mutating the object.
    def inspect_attributes
      filtered = self.class.inspect_filtered_attributes
      instance_variables.filter_map do |ivar|
        value = instance_variable_get(ivar)
        next if value.nil?

        name = ivar.to_s.delete_prefix('@')
        [name, filtered.include?(name) ? inspect_filter(value) : value]
      end
    end

    # A credential-bearing Hash keeps its keys (useful when debugging which
    # variables are set) with every value replaced; anything else is replaced
    # outright. Builds a new Hash; the object itself is never touched.
    def inspect_filter(value)
      value.respond_to?(:each_key) ? value.each_key.to_h { |key| [key, '[FILTERED]'] } : '[FILTERED]'
    end

    def inspect_class_name
      self.class.name || self.class.inspect
    end

    def inspect_bounded(value, depth, seen)
      case value
      when Type then value.inspect_with(depth, seen)
      when String then inspect_truncated(value)
      when Array then inspect_container(value, '[', ']', depth, seen) { |item| inspect_bounded(item, depth + 1, seen) }
      when Hash
        inspect_container(value, '{', '}', depth, seen) do |key, item|
          "#{inspect_hash_key(key, depth + 1, seen)}#{inspect_bounded(item, depth + 1, seen)}"
        end
      when Proc, Method then value.inspect
      else inspect_leaf(value)
      end
    end

    def inspect_container(value, open, close, depth, seen, &render)
      return "#{open}#{close}" if value.empty?
      return "#{open}…(#{value.size})#{close}" if depth > INSPECT_MAX_DEPTH || seen.key?(value)

      seen[value] = true
      begin
        parts = value.first(INSPECT_MAX_ITEMS).map(&render)
        parts << "…(+#{value.size - INSPECT_MAX_ITEMS} more)" if value.size > INSPECT_MAX_ITEMS
        "#{open}#{parts.join(', ')}#{close}"
      ensure
        seen.delete(value)
      end
    end

    # Rendered by hand rather than via Hash#inspect, whose format differs
    # between Ruby 3.3 (`{:a=>1}`) and 3.4 (`{a: 1}`).
    def inspect_hash_key(key, depth, seen)
      return "#{key.name}: " if key.is_a?(Symbol) && key.inspect.match?(/\A:\w+[?!]?\z/)

      "#{inspect_bounded(key, depth, seen)} => "
    end

    def inspect_truncated(string)
      return string.inspect if string.length <= INSPECT_MAX_STRING

      "#{string[0, INSPECT_MAX_STRING].inspect}…(+#{string.length - INSPECT_MAX_STRING} chars)"
    end

    # Printing must never raise (it runs inside loggers and `puts`), so an
    # object whose #inspect raises, or a BasicObject without one, falls back
    # to a placeholder.
    def inspect_leaf(value)
      return "#<#{value.class}>" if kernel_inspect_only?(value)

      rendered = value.inspect
      return rendered if rendered.length <= INSPECT_MAX_STRING

      "#{rendered[0, INSPECT_MAX_STRING]}…(+#{rendered.length - INSPECT_MAX_STRING} chars)"
    rescue StandardError
      begin
        "#<#{value.class}>"
      rescue StandardError
        '#<?>'
      end
    end

    def kernel_inspect_only?(value)
      Kernel.instance_method(:method).bind_call(value, :inspect).owner == Kernel
    rescue TypeError # not a Kernel object: BasicObject, Delegator
      false
    end

    # Allow camelCase attribute access
    def method_missing(method_name, ...)
      normalized = normalize_name(method_name)

      if normalized != method_name.to_s && respond_to?(normalized)
        public_send(normalized, ...)
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      normalized = normalize_name(method_name)
      (normalized != method_name.to_s && respond_to?(normalized)) || super
    end

    def assign_attributes(attributes)
      raise ArgumentError, "When assigning attributes, you must pass a hash as an argument, #{attributes.inspect} passed." unless attributes.respond_to?(:each_pair)

      return if attributes.empty?

      attributes.each_pair { |name, value| assign_attribute(name, value) }
    end

    def assign_attribute(name, value)
      setter = :"#{normalize_name(name)}="
      public_send(setter, value) if respond_to?(setter)
    end

    def read_attribute(name)
      getter = normalize_name(name)
      public_send(getter) if respond_to?(getter)
    end

    def normalize_name(name)
      name = name.to_s.dup
      name.gsub!(/(?<=[A-Z])(?=[A-Z][a-z])|(?<=[a-z\d])(?=[A-Z])/, "_")
      name.tr!("-", "_")
      name.downcase!
      name
    end

    FALSE_VALUES = [
      false, 0,
      "0", :'0',
      "f", :f,
      "F", :F,
      "false", :false, # rubocop:disable Lint/BooleanSymbol
      "FALSE", :FALSE,
      "off", :off,
      "OFF", :OFF
    ].to_set.freeze

    private_constant :FALSE_VALUES

    def coerce_boolean(value)
      return if value.nil?

      if value == ""
        nil
      else
        !FALSE_VALUES.include?(value)
      end
    end
  end

  # Content Blocks

  # Text content block
  class TextBlock < Type
    attr_accessor :text

    def to_s
      text.to_s
    end
  end

  # Thinking content block
  class ThinkingBlock < Type
    attr_accessor :thinking, :signature
  end

  # Tool use content block
  class ToolUseBlock < Type
    attr_accessor :id, :name, :input
  end

  # Tool result content block
  class ToolResultBlock < Type
    attr_accessor :tool_use_id, :content, :is_error
  end

  # Server-side tool use (CLI's built-in tools that execute server-side
  # rather than as MCP tools — advisor, web_search, code_execution, etc.).
  # Mirrors Python's `ServerToolUseBlock`.
  class ServerToolUseBlock < Type
    attr_accessor :id, :name, :input
  end

  # Result of a server-side tool execution. Mirrors Python's
  # `ServerToolResultBlock`.
  class ServerToolResultBlock < Type
    attr_accessor :tool_use_id, :content, :is_error
  end

  # Generic content block for types the SDK doesn't explicitly handle (e.g., "document", "image").
  # Preserves the raw hash data for forward compatibility with newer CLI versions.
  class UnknownBlock < Type
    attr_accessor :type, :data
  end

  # Deferred tool use, emitted on `ResultMessage` when a PreToolUse hook
  # returned `permissionDecision: "defer"`. The session can be resumed later
  # to execute the deferred call. Mirrors Python's `DeferredToolUse`.
  class DeferredToolUse < Type
    attr_accessor :id, :name, :input
  end

  # Message Types

  # User message
  class UserMessage < Type
    attr_accessor :content, :uuid, :parent_tool_use_id, :tool_use_result

    # Provenance of this message — where the turn came from.
    #
    # In streaming-input mode a single connection interleaves the turns you
    # send with turns the session injects on its own (background-task
    # notifications, fired scheduled-task prompts, MCP channel messages,
    # messages relayed from peer sessions, ...). `origin` tells them apart —
    # see {ResultMessage#origin} for deciding whether a result answers *your*
    # prompt.
    #
    # **Key form — read this before indexing into it.** A plain Hash, passed
    # through from the CLI untouched: the SDK does not model it, whitelist its
    # keys, or rewrite them, so kinds and fields newer CLI versions add stay
    # visible. Keys therefore follow the transport's JSON parsing, which uses
    # `symbolize_names: true` — they are **Symbols with the wire spelling
    # preserved**, so camelCase keys stay camelCase and you index with
    # `origin[:kind]`, `origin[:fromSession]`, `origin[:senderTaskId]`,
    # `origin[:verifiedPeerPid]`. This is unlike the snake_case attributes
    # elsewhere in this SDK, and unlike the Python SDK's string keys: a
    # `origin["kind"]` or `origin[:from_session]` lookup silently returns nil
    # and makes every attributed turn look unattributed. Only `:kind` is
    # guaranteed present; the rest depend on it.
    #
    # `nil` means the CLI did not attribute the message — that is the normal
    # case for prompts you send through {ClaudeAgentSDK.query} / {Client#query},
    # unless the host stamps `origin: { kind: 'human' }` on the message Hash
    # itself (only the `human` kind is honored from an SDK host). Populated on
    # injected turns (task notifications, channel/peer messages, ...) and on
    # user messages the CLI replays; tool-result messages never carry it.
    #
    # Known `:kind` values — documentation, not validation; treat anything
    # unrecognized as "not human":
    #
    # - `'human'` — a turn submitted by the SDK host
    # - `'channel'` — arrived on an MCP channel; `:server` names the MCP server
    # - `'peer'` — relayed from a peer session. `:from` (sender address,
    #   sender-asserted — for reply routing or display, never as proof of
    #   identity), `:name` (display name, already normalized by the CLI),
    #   `:fromSession` (the sender's host-openable session id, a navigation
    #   target only), `:senderTaskId` (task id of the in-process background
    #   subagent that sent it; absent for cross-session peers), `:body`
    #   (decoded message body with the peer envelope stripped, byte-exact with
    #   what the model saw — render this instead of re-parsing the message
    #   text), `:verifiedPeerPid` (kernel-verified pid of the process that
    #   connected to this session's local messaging socket — the *connecting*
    #   process, which for relayed traffic is the relay; absent when
    #   unverifiable)
    # - `'task-notification'` — a background task's delivery. `:subkind` is
    #   `'scheduled-trigger'` (the fired prompt of a scheduled task) or
    #   `'peer-send-message'` (a message sent from another of the user's
    #   sessions); absent for ordinary background-task notifications
    # - `'coordinator'`, `'unclassified'`, `'observer'` (`:from` /
    #   `:senderTaskId` as for `peer`), `'auto-continuation'`,
    #   `'observer-activity'`
    #
    # @return [Hash{Symbol => Object}, nil]
    # @see ResultMessage#origin
    attr_accessor :origin

    # Concatenated text of this message. Handles both String content
    # (plain-text user prompt) and Array-of-blocks content (typed content).
    # Returns "" when there is no text.
    def text
      case content
      when String then content
      when Array then content.grep(TextBlock).map(&:text).join("\n\n")
      else ''
      end
    end

    alias to_s text
  end

  # Assistant message with content blocks
  class AssistantMessage < Type
    attr_accessor :content, :model, :parent_tool_use_id, :error, :usage,
                  :message_id, :stop_reason, :session_id, :uuid

    # Concatenated text across every TextBlock in this message's content.
    # Returns "" when the message has no text (e.g., a pure tool_use turn).
    def text
      Array(content).grep(TextBlock).map(&:text).join("\n\n")
    end

    alias to_s text
  end

  # System message with metadata.
  # When constructed from a raw CLI hash, the whole hash is stored in `#data`
  # unless the caller explicitly provides a `:data` entry.
  class SystemMessage < Type
    attr_accessor :subtype, :data

    def initialize(attributes = {})
      super
      @data ||= attributes if attributes.is_a?(Hash)
    end

    def to_s
      subtype.nil? ? '[system]' : "[system: #{subtype}]"
    end

    private

    # A typed subclass (InitMessage, TaskStartedMessage, ...) already exposes
    # the fields of its raw frame as attributes; repeating @data would double
    # the output. A bare SystemMessage (unrecognized subtype) keeps it, since
    # @data is the only place its payload lives.
    def inspect_attributes
      return super if instance_of?(SystemMessage)

      super.reject { |pair| pair.first == 'data' }
    end
  end

  # Init system message (emitted at session start and after /clear)
  class InitMessage < SystemMessage
    attr_accessor :uuid, :session_id, :agents, :api_key_source, :betas,
                  :claude_code_version, :cwd, :tools, :mcp_servers, :model,
                  :permission_mode, :slash_commands, :output_style, :skills, :plugins,
                  :fast_mode_state # "off", "cooldown", or "on"
  end

  # Compact boundary system message (emitted after context compaction completes)
  class CompactBoundaryMessage < SystemMessage
    attr_accessor :uuid, :session_id
    attr_reader :compact_metadata

    def compact_metadata=(value)
      @compact_metadata = value.is_a?(Hash) ? CompactMetadata.new(value) : value
    end
  end

  # Metadata about a compaction event
  class CompactMetadata < Type
    attr_accessor :pre_tokens, :post_tokens, :trigger, :custom_instructions, :preserved_segment
  end

  # Status system message (compacting status, permission mode changes)
  class StatusMessage < SystemMessage
    attr_accessor :uuid, :session_id, :status, :permission_mode
  end

  # API retry system message
  class APIRetryMessage < SystemMessage
    attr_accessor :uuid, :session_id, :attempt, :max_retries, :retry_delay_ms, :error_status, :error
  end

  # Local command output system message
  class LocalCommandOutputMessage < SystemMessage
    attr_accessor :uuid, :session_id, :content
  end

  # Emitted when a session_store mirror batch fails terminally and is
  # dropped — timeouts immediately (never retried), other failures after up
  # to three attempts. The local-disk transcript is still durable; this is
  # the consumer's only signal that the external store missed a batch
  # (at-most-once delivery).
  class MirrorErrorMessage < SystemMessage
    attr_accessor :uuid, :session_id, :error, :key
  end

  # Hook started system message
  class HookStartedMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event
  end

  # Hook progress system message
  class HookProgressMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event, :stdout, :stderr, :output
  end

  # Hook response system message
  class HookResponseMessage < SystemMessage
    attr_accessor :uuid, :session_id, :hook_id, :hook_name, :hook_event,
                  :output, :stdout, :stderr, :exit_code,
                  :outcome # "success", "error", or "cancelled"
  end

  # Session state changed system message
  class SessionStateChangedMessage < SystemMessage
    attr_accessor :uuid, :session_id,
                  :state # "idle", "running", or "requires_action"
  end

  # Files persisted system message
  class FilesPersistedMessage < SystemMessage
    attr_accessor :uuid, :session_id, :files, :failed, :processed_at
  end

  # Elicitation complete system message
  class ElicitationCompleteMessage < SystemMessage
    attr_accessor :uuid, :session_id, :mcp_server_name, :elicitation_id
  end

  # Task lifecycle notification statuses
  TASK_NOTIFICATION_STATUSES = %w[completed failed stopped].freeze

  # Possible status values reported inside a `task_updated` patch.
  # pending/running/paused are non-terminal; completed/failed/killed are
  # terminal. Note: task_updated reports the raw "killed"; the CLI maps that to
  # "stopped" only when it emits a task_notification.
  TASK_UPDATED_STATUSES = %w[pending running paused completed failed killed].freeze

  # Task statuses that mean the task has finished and should be cleared from any
  # "active task" tracking. Spans both lifecycle vocabularies: task_notification
  # reports "stopped" (the CLI's mapped form of a killed task) while task_updated
  # reports the raw "killed". Treat the status of a TaskNotificationMessage and a
  # TaskUpdatedMessage the same way.
  TERMINAL_TASK_STATUSES = %w[completed failed stopped killed].freeze

  # Typed usage data for task progress and notifications
  class TaskUsage < Type
    attr_accessor :total_tokens, :tool_uses, :duration_ms

    def initialize(attributes = {})
      super
      @total_tokens ||= 0
      @tool_uses    ||= 0
      @duration_ms  ||= 0
    end
  end

  # Task started system message (subagent/background task started)
  class TaskStartedMessage < SystemMessage
    attr_accessor :task_id, :description, :uuid, :session_id, :tool_use_id, :task_type,
                  :workflow_name, :prompt,
                  :subagent_type # Subagent type, for Task/Agent tool subagents; nil otherwise

    # Whether the task was registered in the background (`true`) or in the
    # foreground with the spawning tool call blocking on it (`false`). `nil`
    # means the CLI did not say (the field is optional, and only set for
    # `local_agent` and `local_bash` tasks) — so test `== false`, never
    # falsiness, to detect a foreground/blocking task. A resumed subagent is
    # always registered in the background. A later move to the background does
    # not re-emit task_started; it arrives as {TaskUpdatedMessage#is_backgrounded}.
    #
    # @return [Boolean, nil]
    attr_accessor :is_backgrounded

    # Nesting depth of a spawned subagent (`local_agent`) task: 1 for a
    # top-level spawn, N+1 when spawned from inside a depth-N agent. `nil` on
    # other task types and on CLIs that do not report it.
    #
    # @return [Integer, nil]
    attr_accessor :spawn_depth

    # Display flags, passed through for the host to act on — the SDK never
    # filters frames or computes activity from them. Both are optional
    # Booleans: `nil` when absent, an explicit `false` preserved.
    #
    # - `skip_transcript`: an ambient/housekeeping task. Hide it from the
    #   inline transcript; it may still appear in a tasks panel.
    # - `ambient`: true for tasks that are not activity — every
    #   `skip_transcript` task, plus every live-update watcher (requested or
    #   auto-started). Exclude these from activity indicators.
    #
    # @return [Boolean, nil]
    attr_accessor :skip_transcript, :ambient
  end

  # Task progress system message (periodic update from a running task).
  #
  # `summary` is an optional one-line status for the task's row — `nil` on any
  # frame that lacks one. For a `local_agent` task it is the model-generated
  # progress summary, which the CLI produces only while generation is enabled
  # (see {ClaudeAgentOptions#agent_progress_summaries}); for a backgrounded
  # `mcp_task` it is the MCP server's own status message and needs no option.
  class TaskProgressMessage < SystemMessage
    attr_accessor :task_id, :description, :usage, :uuid, :session_id, :tool_use_id, :last_tool_name, :summary,
                  :subagent_type # Subagent type, for Task/Agent tool subagents; nil otherwise
  end

  # Task notification system message (task completed/failed/stopped).
  #
  # Note: not every terminal task emits this message. Background tasks may
  # instead report completion only via a TaskUpdatedMessage whose patch["status"]
  # is terminal (see TERMINAL_TASK_STATUSES). Consumers tracking active task IDs
  # should clear them on a terminal status from *either* message.
  class TaskNotificationMessage < SystemMessage
    attr_accessor :task_id, :status, :output_file, :summary, :uuid, :session_id, :tool_use_id, :usage

    # Machine-readable cause, set only when the task did not end through an
    # ordinary completion, failure, or stop. The one known value is
    # `'worker_restart'` (the worker process restarted and the resumed process
    # found the task orphaned; always with status `'stopped'`). Documentation,
    # not validation: newer CLIs may add values.
    #
    # @return [String, nil]
    attr_accessor :reason

    # For a backgrounded MCP task (`task_type: 'mcp_task'`) that completed: the
    # `resource_link` content blocks of its final result — the files it
    # returned by reference. A backgrounded task's tool_result is placeholder
    # text, so this is where a host learns which files the call produced; join
    # to the originating call via `tool_use_id`. `nil` when the result had
    # none or the task is any other type.
    #
    # Passed through from the CLI untouched, so each element is a Hash whose
    # keys are **Symbols with the wire spelling preserved**: `:uri` and `:name`
    # (Strings, always present), and optionally `:title`, `:description`,
    # `:mimeType` (camelCase — a `:mime_type` lookup returns nil), `:size` (a
    # Number, not necessarily an Integer), `:annotations` (a Hash of arbitrary
    # values). Elements carry no `type: 'resource_link'` discriminator. The CLI
    # describes its own output as at most 50 links / 64 KiB serialized; that is
    # a producer-side note, and the SDK neither enforces nor truncates.
    #
    # @return [Array<Hash{Symbol => Object}>, nil]
    attr_accessor :resource_links

    # Display flags with the same meaning as on {TaskStartedMessage}:
    # `skip_transcript` (hide from the inline transcript) and `ambient` (not
    # activity — exclude from activity indicators). Optional Booleans: `nil`
    # when absent, an explicit `false` preserved. The SDK does not act on them.
    #
    # @return [Boolean, nil]
    attr_accessor :skip_transcript, :ambient
  end

  # Task updated system message (background task lifecycle state change).
  #
  # The CLI emits system/task_updated events as a task moves through its
  # lifecycle. `patch` carries the changed fields (e.g. status, end_time); when
  # patch["status"] is terminal (see TERMINAL_TASK_STATUSES) the task has
  # finished. A background task's terminal state can arrive *only* as a
  # TaskUpdatedMessage with no accompanying TaskNotificationMessage — e.g. a task
  # stopped via TaskStop reports status "killed" here and the matching
  # notification is sometimes suppressed. Consumers tracking active task IDs
  # should clear them on a terminal status from *either* message.
  #
  # Parsed defensively in the constructor — a lifecycle event must never raise:
  # `status` is derived from patch["status"] (not a top-level field); a non-Hash
  # or absent patch falls back to {}; and `task_id` defaults to "" (never nil,
  # matching the Python SDK) so consumers can rely on it always being a String.
  # The full patch is preserved on `#patch` for callers that need more than the
  # derived readers.
  #
  # A patch carries only the fields that changed, so every derived reader is
  # `nil` when its field is absent. That matters most for `is_backgrounded`:
  # `true` means the task just moved to the background (e.g. after
  # {Client#background_tasks}), while `nil` means "this patch does not mention
  # it" — not "foreground". Merge patches into your own task map rather than
  # reading any single one as the task's full state.
  class TaskUpdatedMessage < SystemMessage
    attr_accessor :task_id, :patch, :status, :uuid, :session_id,
                  :description,     # patch[:description] — String, nil when unchanged
                  :error,           # patch[:error] — String, nil when unchanged
                  :end_time,        # patch[:end_time] — Integer (epoch ms), nil when unchanged
                  :total_paused_ms, # patch[:total_paused_ms] — Integer, nil when unchanged
                  :is_backgrounded  # patch[:is_backgrounded] — true/false, nil when unchanged

    def initialize(attributes = {})
      super
      @task_id ||= ''
      @patch = {} unless @patch.is_a?(Hash)
      @status = patch_value(:status)
      @description = patch_value(:description)
      @error = patch_value(:error)
      @end_time = patch_value(:end_time)
      @total_paused_ms = patch_value(:total_paused_ms)
      @is_backgrounded = patch_value(:is_backgrounded)
    end

    private

    # The parser always hands over a symbol-keyed patch; a hand-built message
    # may use string keys. `fetch` with a block (not `||`) keeps an explicit
    # `false` from falling through to the string-key lookup's nil.
    def patch_value(key)
      @patch.fetch(key) { @patch[key.to_s] }
    end
  end

  # Background tasks changed system message: the full set of live background
  # tasks, emitted whenever membership changes (start, completion, kill, a
  # foreground agent being backgrounded) or an entry's `ambient` flag flips.
  #
  # A **level** signal with **REPLACE semantics** — `tasks` is every live
  # background task after the change, so swap your set for each payload rather
  # than pairing task_started / task_notification edges; a missed edge then
  # cannot wedge a stale "running" indicator. Per the CLI's contract:
  #
  # - Ordering relative to the edge frames for the same transition is
  #   unspecified, and the payload carries ids only — do not correlate it
  #   with the edge stream.
  # - The level is per-process: nothing is emitted at startup, so reset to the
  #   empty set whenever the session's CLI process (re)starts.
  # - `tasks: []` is an authoritative empty snapshot for that process, not a
  #   missing value.
  # - A repeated `initialize` on an already-running process is answered with a
  #   snapshot of the current set (even an empty one) right behind its success
  #   response; older CLIs send nothing there. This SDK initializes once per
  #   connection, so that only matters to custom transports that reconnect.
  # - It covers *background* tasks only. A foreground subagent (the spawning
  #   tool call still blocking) is not listed until it is backgrounded.
  #
  # `tasks` is passed through untouched: an Array of symbol-keyed Hashes
  # `{ task_id:, task_type:, description:, ambient: }`. `:ambient` is optional;
  # true marks tasks that are not activity (housekeeping, live-update
  # watchers), which hosts should exclude from activity indicators.
  #
  # The SDK itself deliberately does not consume this frame for its own
  # stdin-close bookkeeping; it is typed purely for consumers.
  class BackgroundTasksChangedMessage < SystemMessage
    attr_accessor :tasks, :uuid, :session_id
  end

  # Permission denied system message: a tool call was auto-denied without an
  # interactive permission prompt (auto-mode classifier, dontAsk mode,
  # headless-agent auto-deny, a deny rule, or — with no can_use_tool callback —
  # an "ask" decision that nobody can answer). The "ask" path with a callback
  # surfaces through can_use_tool instead.
  #
  # **Best-effort advisory, not a complete denial feed**:
  # {ResultMessage#permission_denials} is the authoritative record. In rare
  # races a booked denial has no frame, or a frame has no booked denial — so do
  # not derive counts or permission state from this stream. Not covered at all:
  # PreToolUse hook denies, deny-rule overrides of a hook's allow/ask decision,
  # Read/Edit/Write calls refused by a path-scoped deny rule (all resolve before
  # the permission check), and the MCP `--permission-prompt-tool` surface.
  #
  # `agent_id` is a subagent id for host-side routing; it is NOT a permission
  # `request_id`, and this message is not a pending permission request.
  # `decision_reason_type` is an open String (the values below are examples,
  # not an enum). The CLI's `decision_reason_code` is marked internal and is
  # left to `#data` with no stability promise.
  class PermissionDeniedMessage < SystemMessage
    attr_accessor :uuid, :session_id, :tool_name, :tool_use_id,
                  :agent_id,             # Subagent ID when the denied call originated inside a subagent; nil otherwise
                  :decision_reason_type, # Open String, e.g. "classifier", "asyncAgent", "mode", "rule"; nil when not reported
                  :decision_reason,      # Human-readable reason from the deciding component; nil when not reported
                  :message               # The rejection message returned to the model in the tool_result
  end

  # Result message with cost and usage information
  class ResultMessage < Type
    # model_usage maps model name => per-model usage Hash, passed through
    # verbatim from the CLI's modelUsage field, so its keys are camelCase
    # (matches the TypeScript/Python SDKs' ModelUsage shape): inputTokens,
    # outputTokens, cacheReadInputTokens, cacheCreationInputTokens,
    # webSearchRequests, costUSD, contextWindow, maxOutputTokens, plus
    # optional canonicalModel (canonical id used for the pricing lookup —
    # may differ from the raw model-string key for provider-specific
    # ids/aliases) and provider ('firstParty', 'bedrock', 'vertex', ...).
    #
    # terminal_reason says why the query loop ended ("completed",
    # "max_turns", "aborted_streaming", ...). "aborted_streaming" /
    # "aborted_tools" mean the turn was cancelled via Client#interrupt (an
    # interrupt control request). nil when the CLI did not report one
    # (older CLI versions, or a result that bypassed the query loop such
    # as a local slash command).
    attr_accessor :subtype, :duration_ms, :duration_api_ms, :is_error,
                  :num_turns, :session_id, :stop_reason, :total_cost_usd, :usage,
                  :result, :structured_output,
                  :model_usage,        # Hash of { model_name => usage_data }, see above
                  :permission_denials, # Array of { tool_name:, tool_use_id:, tool_input: }
                  :errors,             # Array of error strings (present on error subtypes)
                  :uuid,
                  :fast_mode_state,    # "off", "cooldown", or "on"
                  :api_error_status,   # Integer HTTP status (429, 500, 529) on api_error subtype (CLI 2.1.110+)
                  :terminal_reason     # why the query loop ended, see above

    attr_reader :deferred_tool_use     # DeferredToolUse, populated when a PreToolUse hook deferred

    def deferred_tool_use=(value)
      @deferred_tool_use = value.is_a?(Hash) ? DeferredToolUse.from_hash(value) : value
    end

    # Provenance of the user message that triggered this turn — `nil` when the
    # CLI did not attribute it. Lets a streaming-input consumer distinguish the
    # result of its own prompt from the result of a turn the session injected
    # on its own:
    #
    #     if result.origin.nil? || result.origin[:kind] == 'human'
    #       # a turn this application submitted
    #     elsif result.origin[:kind] == 'task-notification'
    #       # follow-up turn driven by a background task
    #     end
    #
    # **Key form.** A plain Hash passed through from the CLI untouched, so its
    # keys are **Symbols with the wire spelling preserved** — camelCase stays
    # camelCase (`origin[:kind]`, `origin[:fromSession]`,
    # `origin[:verifiedPeerPid]`), unlike the snake_case attributes elsewhere
    # in this SDK and unlike the Python SDK's string keys. Indexing with
    # `origin["kind"]` silently returns nil and makes every attributed turn
    # look unattributed.
    #
    # See {UserMessage#origin} for the full list of known `:kind` values and
    # their per-kind keys.
    #
    # @return [Hash{Symbol => Object}, nil]
    # @see UserMessage#origin
    attr_accessor :origin

    # One human-readable line, e.g. `[result: success, 3 turns, 4.2s, $0.0120]`
    # (parts the CLI did not report are left out). An error result appends its
    # `errors`. Use #inspect for every field.
    def to_s
      parts = [subtype].compact
      parts << "#{num_turns} #{num_turns == 1 ? 'turn' : 'turns'}" unless num_turns.nil?
      parts << format('%.1fs', duration_ms / 1000.0) if duration_ms.is_a?(Numeric)
      parts << format('$%.4f', total_cost_usd) if total_cost_usd.is_a?(Numeric)
      line = parts.empty? ? '[result]' : "[result: #{parts.join(', ')}]"
      line += " - #{Array(errors).join('; ')}" if is_error && !Array(errors).empty?
      line
    end
  end

  # Stream event for partial message updates
  class StreamEvent < Type
    attr_accessor :uuid, :session_id, :event, :parent_tool_use_id
  end

  # Tool progress message (type: 'tool_progress')
  class ToolProgressMessage < Type
    attr_accessor :uuid, :session_id, :tool_use_id, :tool_name, :parent_tool_use_id,
                  :elapsed_time_seconds, :task_id
  end

  # Auth status message (type: 'auth_status')
  class AuthStatusMessage < Type
    attr_accessor :uuid, :session_id, :is_authenticating, :output, :error
  end

  # Tool use summary message (type: 'tool_use_summary')
  class ToolUseSummaryMessage < Type
    attr_accessor :uuid, :session_id, :summary, :preceding_tool_use_ids
  end

  # Prompt suggestion message (type: 'prompt_suggestion')
  class PromptSuggestionMessage < Type
    attr_accessor :uuid, :session_id, :suggestion
  end

  # Type constants for rate limit statuses
  RATE_LIMIT_STATUSES = %w[allowed allowed_warning rejected].freeze

  # Type constants for rate limit types
  RATE_LIMIT_TYPES = %w[five_hour seven_day seven_day_opus seven_day_sonnet overage].freeze

  # Rate limit info with typed fields
  class RateLimitInfo < Type
    attr_accessor :status, :resets_at, :rate_limit_type, :utilization,
                  :overage_status, :overage_resets_at, :overage_disabled_reason, :raw

    def initialize(attributes = {})
      super
      @raw ||= {}
    end
  end

  # Rate limit event emitted when rate limit info changes
  class RateLimitEvent < Type
    attr_accessor :uuid, :session_id, :raw_data
    attr_reader :rate_limit_info

    def initialize(attributes = {})
      super
      @rate_limit_info ||= RateLimitInfo.new
    end

    def rate_limit_info=(value)
      @rate_limit_info = value.is_a?(Hash) ? RateLimitInfo.new(value.merge(raw: value)) : value
    end

    # Backward-compatible accessor returning the full raw event payload
    def data
      @raw_data || {}
    end
  end

  # Emitted when the session's conversation is replaced without ending the
  # connection — e.g. after `/clear` or any other flow that discards the
  # transcript mid-session (type: 'conversation_reset').
  #
  # In streaming-input mode a single connection carries many user turns, and a
  # reset clears the conversation history *and* zeroes the running totals
  # reported on subsequent {ResultMessage} objects (e.g. `total_cost_usd`). If
  # you accumulate those totals across a long-lived session, snapshot them when
  # this message arrives.
  #
  # @!attribute [rw] new_conversation_id
  #   Opaque identifier for the fresh conversation, for UIs to key an empty
  #   transcript on (and to discard any cached session title). This is *not*
  #   the `session_id` of subsequent messages — read that from the next
  #   message.
  #   @return [String]
  # @!attribute [rw] uuid
  #   Unique ID of this message.
  #   @return [String]
  # @!attribute [rw] session_id
  #   ID of the session that was reset (the outgoing session; messages after
  #   the reset carry a new `session_id`).
  #   @return [String]
  class ConversationResetMessage < Type
    attr_accessor :new_conversation_id, :uuid, :session_id
  end

  # Thinking configuration types
  #
  # `display` controls how thinking content appears in responses. Valid values
  # are `"summarized"` (plaintext summary) and `"omitted"` (empty thinking
  # field, signature only). Defaults are model-dependent: Opus 4.6/Sonnet 4.6
  # default to `"summarized"`; Opus 4.7 and every later model default to
  # `"omitted"`. Pass `display: "summarized"` explicitly on those to get
  # visible thinking text. Not supported with `ThinkingConfigDisabled`.
  THINKING_DISPLAY_VALUES = %w[summarized omitted].freeze

  # Adaptive thinking: the model decides when and how much to think
  # (sent as `--thinking adaptive`, no budget); control depth with `effort`.
  class ThinkingConfigAdaptive < Type
    include Type::OptionValue

    attr_reader :type, :display

    def initialize(attributes = {})
      super
      @type = 'adaptive'
    end

    def display=(value)
      @display = validate_display(value)
    end

    private

    def validate_display(value)
      return nil if value.nil?
      return value if THINKING_DISPLAY_VALUES.include?(value.to_s)

      raise ArgumentError,
            "invalid thinking display #{value.inspect}; expected one of #{THINKING_DISPLAY_VALUES.inspect}"
    end
  end

  # Enabled thinking: uses a user-specified budget
  class ThinkingConfigEnabled < Type
    include Type::OptionValue

    attr_accessor :budget_tokens
    attr_reader :type, :display

    def initialize(attributes = {})
      super
      @type = 'enabled'
    end

    def display=(value)
      @display = validate_display(value)
    end

    private

    def validate_display(value)
      return nil if value.nil?
      return value if THINKING_DISPLAY_VALUES.include?(value.to_s)

      raise ArgumentError,
            "invalid thinking display #{value.inspect}; expected one of #{THINKING_DISPLAY_VALUES.inspect}"
    end
  end

  # Disabled thinking: sets thinking tokens to 0
  class ThinkingConfigDisabled < Type
    include Type::OptionValue

    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'disabled'
    end
  end

  # Agent definition configuration
  class AgentDefinition < Type
    include Type::OptionValue

    attr_accessor :description, :prompt, :tools, :disallowed_tools, :model, :skills, :memory, :mcp_servers,
                  :initial_prompt, :max_turns, :background, :effort, :permission_mode
  end

  # Permission rule value
  class PermissionRuleValue < Type
    attr_accessor :tool_name, :rule_content
  end

  # Permission update configuration
  class PermissionUpdate < Type
    attr_accessor :type, :behavior, :mode, :directories, :destination
    attr_reader :rules

    # Wire-format parity with Python PermissionUpdate.from_dict (#920): the CLI
    # sends rules as camelCase hashes ({toolName:, ruleContent:}); hydrate them
    # into PermissionRuleValue (Type#assign_attribute normalizes the camelCase
    # keys). Already-typed PermissionRuleValue entries pass through unchanged.
    def rules=(value)
      @rules = value&.map { |rule| rule.is_a?(Hash) ? PermissionRuleValue.new(rule) : rule }
    end

    def to_h
      result = { type: @type }
      result[:destination] = @destination if @destination

      case @type
      when 'addRules', 'replaceRules', 'removeRules'
        if @rules
          result[:rules] = @rules.map do |rule|
            {
              toolName: rule.tool_name,
              ruleContent: rule.rule_content
            }
          end
        end
        result[:behavior] = @behavior if @behavior
      when 'setMode'
        result[:mode] = @mode if @mode
      when 'addDirectories', 'removeDirectories'
        result[:directories] = @directories if @directories
      end

      result
    end
  end

  # Tool permission context delivered to `can_use_tool` callbacks.
  # CLI 2.1.110+ began populating the four pre-formatted display fields
  # (`title`, `display_name`, `description`, `blocked_path`,
  # `decision_reason`) so the SDK consumer can render the same prompt UI
  # the CLI would have shown. Older fields (`signal`, `suggestions`,
  # `tool_use_id`, `agent_id`) remain unchanged.
  # `signal` is a CancellationSignal on dispatched callbacks; `request_id`
  # identifies this permission request (distinct from the tool invocation).
  class ToolPermissionContext < Type
    attr_accessor :signal, :request_id, :suggestions, :tool_use_id, :agent_id,
                  :title, :display_name, :description,
                  :blocked_path, :decision_reason

    def initialize(attributes = {})
      super
      @suggestions ||= []
    end
  end

  # Permission results
  class PermissionResultAllow < Type
    attr_accessor :updated_input, :updated_permissions
    attr_reader :behavior

    def initialize(attributes = {})
      super
      @behavior = 'allow'
    end
  end

  class PermissionResultDeny < Type
    attr_accessor :message, :interrupt
    attr_reader :behavior

    def initialize(attributes = {})
      super
      @behavior = 'deny'
      @message ||= ''
      @interrupt = false if @interrupt.nil?
    end
  end

  # Hook matcher configuration
  class HookMatcher < Type
    include Type::OptionValue

    attr_accessor :matcher, :hooks, :timeout

    def initialize(attributes = {})
      super
      @hooks ||= []
    end
  end

  # Hook context passed to hook callbacks. Dispatched hooks receive the control
  # request ID and a CancellationSignal (including on HookMatcher timeout).
  class HookContext < Type
    attr_accessor :signal, :request_id
  end

  # Base hook input with common fields
  class BaseHookInput < Type
    attr_accessor :session_id, :transcript_path, :cwd, :permission_mode
    attr_reader :hook_event_name
  end

  # PreToolUse hook input
  class PreToolUseHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_use_id, :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PreToolUse'
    end
  end

  # PostToolUse hook input
  class PostToolUseHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_response, :tool_use_id, :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUse'
    end
  end

  # UserPromptSubmit hook input
  class UserPromptSubmitHookInput < BaseHookInput
    attr_accessor :prompt

    def initialize(attributes = {})
      super
      @hook_event_name = 'UserPromptSubmit'
    end
  end

  # Stop hook input
  # Snapshot arrays are passed through unchanged. nil means unavailable;
  # [] means the CLI provided an empty snapshot. They cover the parent
  # session's background work, NOT all foreground and background agents.
  class StopHookInput < BaseHookInput
    attr_accessor :stop_hook_active, :last_assistant_message, :background_tasks, :session_crons

    def initialize(attributes = {})
      super
      @hook_event_name = 'Stop'
      @stop_hook_active = false if @stop_hook_active.nil?
    end
  end

  # SubagentStop hook input
  class SubagentStopHookInput < BaseHookInput
    attr_accessor :stop_hook_active, :agent_id, :agent_transcript_path, :agent_type,
                  :last_assistant_message, :background_tasks, :session_crons

    def initialize(attributes = {})
      super
      @hook_event_name = 'SubagentStop'
      @stop_hook_active = false if @stop_hook_active.nil?
    end
  end

  # PostToolUseFailure hook input
  class PostToolUseFailureHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_use_id, :error, :is_interrupt,
                  :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUseFailure'
    end
  end

  # Notification hook input
  class NotificationHookInput < BaseHookInput
    attr_accessor :message, :title, :notification_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'Notification'
    end
  end

  # SubagentStart hook input
  class SubagentStartHookInput < BaseHookInput
    attr_accessor :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'SubagentStart'
    end
  end

  # PermissionRequest hook input
  class PermissionRequestHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :permission_suggestions, :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PermissionRequest'
    end
  end

  # PreCompact hook input
  class PreCompactHookInput < BaseHookInput
    attr_accessor :trigger, :custom_instructions

    def initialize(attributes = {})
      super
      @hook_event_name = 'PreCompact'
    end
  end

  # SessionStart hook input
  class SessionStartHookInput < BaseHookInput
    attr_accessor :source, :agent_type, :model

    def initialize(attributes = {})
      super
      @hook_event_name = 'SessionStart'
    end
  end

  # SessionEnd hook input
  class SessionEndHookInput < BaseHookInput
    attr_accessor :reason

    def initialize(attributes = {})
      super
      @hook_event_name = 'SessionEnd'
    end
  end

  # Setup hook input
  class SetupHookInput < BaseHookInput
    attr_accessor :trigger

    def initialize(attributes = {})
      super
      @hook_event_name = 'Setup'
    end
  end

  # TeammateIdle hook input
  class TeammateIdleHookInput < BaseHookInput
    attr_accessor :teammate_name, :team_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'TeammateIdle'
    end
  end

  # TaskCompleted hook input
  class TaskCompletedHookInput < BaseHookInput
    attr_accessor :task_id, :task_subject, :task_description, :teammate_name, :team_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'TaskCompleted'
    end
  end

  # ConfigChange hook input
  class ConfigChangeHookInput < BaseHookInput
    attr_accessor :source, :file_path

    def initialize(attributes = {})
      super
      @hook_event_name = 'ConfigChange'
    end
  end

  # WorktreeCreate hook input
  class WorktreeCreateHookInput < BaseHookInput
    attr_accessor :name

    def initialize(attributes = {})
      super
      @hook_event_name = 'WorktreeCreate'
    end
  end

  # WorktreeRemove hook input
  class WorktreeRemoveHookInput < BaseHookInput
    attr_accessor :worktree_path

    def initialize(attributes = {})
      super
      @hook_event_name = 'WorktreeRemove'
    end
  end

  # StopFailure hook input
  class StopFailureHookInput < BaseHookInput
    attr_accessor :error, :error_details, :last_assistant_message

    def initialize(attributes = {})
      super
      @hook_event_name = 'StopFailure'
    end
  end

  # PostCompact hook input
  class PostCompactHookInput < BaseHookInput
    attr_accessor :trigger, :compact_summary

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostCompact'
    end
  end

  # PermissionDenied hook input
  class PermissionDeniedHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_use_id, :reason, :agent_id, :agent_type

    def initialize(attributes = {})
      super
      @hook_event_name = 'PermissionDenied'
    end
  end

  # TaskCreated hook input
  class TaskCreatedHookInput < BaseHookInput
    attr_accessor :task_id, :task_subject, :task_description, :teammate_name, :team_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'TaskCreated'
    end
  end

  # Elicitation hook input
  class ElicitationHookInput < BaseHookInput
    attr_accessor :mcp_server_name, :message, :mode, :url,
                  :elicitation_id, :requested_schema

    def initialize(attributes = {})
      super
      @hook_event_name = 'Elicitation'
    end
  end

  # ElicitationResult hook input
  class ElicitationResultHookInput < BaseHookInput
    attr_accessor :mcp_server_name, :elicitation_id, :mode, :action, :content

    def initialize(attributes = {})
      super
      @hook_event_name = 'ElicitationResult'
    end
  end

  # InstructionsLoaded hook input
  class InstructionsLoadedHookInput < BaseHookInput
    attr_accessor :file_path, :memory_type, :load_reason, :globs, :trigger_file_path

    def initialize(attributes = {})
      super
      @hook_event_name = 'InstructionsLoaded'
    end
  end

  # CwdChanged hook input
  class CwdChangedHookInput < BaseHookInput
    attr_accessor :old_cwd, :new_cwd

    def initialize(attributes = {})
      super
      @hook_event_name = 'CwdChanged'
    end
  end

  # FileChanged hook input
  class FileChangedHookInput < BaseHookInput
    attr_accessor :file_path, :event

    def initialize(attributes = {})
      super
      @hook_event_name = 'FileChanged'
    end
  end

  # Fallback for hook events the SDK does not yet model. Carries the wire
  # event name and the complete raw payload so no fields are lost (Python
  # passes hook input through as a raw dict, so unknown events lose
  # nothing there).
  class UnknownHookInput < BaseHookInput
    attr_accessor :raw_input

    def initialize(attributes = {})
      super
      # Direct assignment: BaseHookInput exposes hook_event_name as
      # attr_reader only, and Type#assign_attribute silently drops keys
      # without public setters.
      @hook_event_name = attributes[:hook_event_name] || attributes['hook_event_name']
    end
  end

  # Setup hook specific output
  class SetupHookSpecificOutput < Type
    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'Setup'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PreToolUse hook specific output
  class PreToolUseHookSpecificOutput < Type
    attr_accessor :permission_decision, :permission_decision_reason,
                  :updated_input, :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PreToolUse'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:permissionDecision] = @permission_decision if @permission_decision
      result[:permissionDecisionReason] = @permission_decision_reason if @permission_decision_reason
      result[:updatedInput] = @updated_input if @updated_input
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PostToolUse hook specific output.
  #
  # `updated_tool_output` (CLI 2.1.110+) replaces the tool's output entirely
  # — works for any tool, MCP or built-in. `updated_mcp_tool_output` is the
  # legacy MCP-only field that pre-dates the unified one; the CLI still
  # honors it, so both are emitted when set. Mirrors Python's
  # `PostToolUseHookSpecificOutput`.
  class PostToolUseHookSpecificOutput < Type
    attr_accessor :additional_context, :updated_mcp_tool_output, :updated_tool_output
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUse'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result[:updatedToolOutput] = @updated_tool_output unless @updated_tool_output.nil?
      result[:updatedMCPToolOutput] = @updated_mcp_tool_output if @updated_mcp_tool_output
      result
    end
  end

  # PostToolUseFailure hook specific output
  class PostToolUseFailureHookSpecificOutput < Type
    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUseFailure'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # UserPromptSubmit hook specific output
  class UserPromptSubmitHookSpecificOutput < Type
    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'UserPromptSubmit'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # Notification hook specific output
  class NotificationHookSpecificOutput < Type
    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'Notification'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # SubagentStart hook specific output
  class SubagentStartHookSpecificOutput < Type
    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'SubagentStart'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PermissionRequest hook specific output
  class PermissionRequestHookSpecificOutput < Type
    attr_accessor :decision
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PermissionRequest'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:decision] = @decision if @decision
      result
    end
  end

  # SessionStart hook specific output
  class SessionStartHookSpecificOutput < Type
    attr_accessor :additional_context
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'SessionStart'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:additionalContext] = @additional_context if @additional_context
      result
    end
  end

  # PermissionDenied hook specific output
  class PermissionDeniedHookSpecificOutput < Type
    attr_accessor :retry
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'PermissionDenied'
      @retry = false if @retry.nil?
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:retry] = @retry unless @retry.nil?
      result
    end
  end

  # CwdChanged hook specific output
  class CwdChangedHookSpecificOutput < Type
    attr_accessor :watch_paths
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'CwdChanged'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:watchPaths] = @watch_paths if @watch_paths
      result
    end
  end

  # FileChanged hook specific output
  class FileChangedHookSpecificOutput < Type
    attr_accessor :watch_paths
    attr_reader :hook_event_name

    def initialize(attributes = {})
      super
      @hook_event_name = 'FileChanged'
    end

    def to_h
      result = { hookEventName: @hook_event_name }
      result[:watchPaths] = @watch_paths if @watch_paths
      result
    end
  end

  # Async hook JSON output
  class AsyncHookJSONOutput < Type
    attr_accessor :async, :async_timeout

    def initialize(attributes = {})
      super
      @async = true if @async.nil?
    end

    def to_h
      result = { async: @async }
      result[:asyncTimeout] = @async_timeout if @async_timeout
      result
    end
  end

  # Sync hook JSON output
  class SyncHookJSONOutput < Type
    attr_accessor :continue, :suppress_output, :stop_reason, :decision,
                  :system_message, :reason, :hook_specific_output

    def initialize(attributes = {})
      super
      @continue = true if @continue.nil?
      @suppress_output = false if @suppress_output.nil?
    end

    def to_h
      result = { continue: @continue }
      result[:suppressOutput] = @suppress_output if @suppress_output
      result[:stopReason] = @stop_reason if @stop_reason
      result[:decision] = @decision if @decision
      result[:systemMessage] = @system_message if @system_message
      result[:reason] = @reason if @reason
      result[:hookSpecificOutput] = @hook_specific_output.to_h if @hook_specific_output
      result
    end
  end

  # MCP status response types

  # MCP server connection status values
  MCP_SERVER_CONNECTION_STATUSES = %w[connected failed needs-auth pending disabled].freeze

  # MCP server info (name and version)
  class McpServerInfo < Type
    attr_accessor :name, :version
  end

  # MCP tool annotation hints
  class McpToolAnnotations < Type
    attr_accessor :read_only, :destructive, :open_world

    # Backwards-compatible parse; returns nil for nil input.
    def self.parse(data)
      from_hash(data)
    end
  end

  # MCP tool info (name, description, annotations)
  class McpToolInfo < Type
    attr_accessor :name, :description
    attr_reader :annotations

    def annotations=(value)
      @annotations = value.is_a?(Hash) ? McpToolAnnotations.new(value) : value
    end

    # Backwards-compatible parse; returns nil for nil input.
    def self.parse(data)
      from_hash(data)
    end
  end

  # Output-only serializable version of McpSdkServerConfig (without live instance)
  # Returned in MCP status responses
  class McpSdkServerConfigStatus < Type
    attr_accessor :name
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'sdk'
    end

    def to_h
      { type: @type, name: @name }
    end
  end

  # Claude.ai proxy MCP server config
  # Output-only type that appears in status responses for servers proxied through Claude.ai
  class McpClaudeAIProxyServerConfig < Type
    attr_accessor :url, :id
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'claudeai-proxy'
    end

    def to_h
      { type: @type, url: @url, id: @id }
    end
  end

  # Status of a single MCP server connection
  class McpServerStatus < Type
    attr_accessor :name, :status, :error, :scope
    attr_reader :server_info, :config, :tools

    def server_info=(value)
      @server_info = value.is_a?(Hash) ? McpServerInfo.new(value) : value
    end

    def tools=(value)
      @tools = if value.is_a?(Array)
                 value.map { |t| t.is_a?(Hash) ? McpToolInfo.new(t) : t }
               else
                 value
               end
    end

    def config=(value)
      @config = self.class.parse_config(value) || value
    end

    # Backwards-compatible parse; normalizes camelCase `serverInfo` and
    # polymorphically builds the nested `config`.
    def self.parse(data)
      from_hash(data)
    end

    def self.parse_config(config)
      return nil unless config.is_a?(Hash) && config[:type]

      case config[:type]
      when 'claudeai-proxy'
        McpClaudeAIProxyServerConfig.new(url: config[:url], id: config[:id])
      when 'sdk'
        McpSdkServerConfigStatus.new(name: config[:name])
      else
        config
      end
    end
  end

  # Response from get_mcp_status containing all server statuses
  class McpStatusResponse < Type
    attr_reader :mcp_servers

    def mcp_servers=(value)
      @mcp_servers = if value.is_a?(Array)
                       value.map { |s| s.is_a?(Hash) ? McpServerStatus.new(s) : s }
                     else
                       value
                     end
    end

    # Backwards-compatible parse; returns nil for nil input.
    def self.parse(data)
      from_hash(data)
    end
  end

  # MCP Server configurations
  class McpStdioServerConfig < Type
    include Type::OptionValue

    attr_accessor :command, :args, :env
    attr_reader :type

    inspect_filtered :env

    def initialize(attributes = {})
      super
      @type = 'stdio'
    end

    def to_h
      result = { type: @type, command: @command }
      result[:args] = @args if @args
      result[:env] = @env if @env
      result
    end
  end

  class McpSSEServerConfig < Type
    include Type::OptionValue

    attr_accessor :url, :headers
    attr_reader :type

    inspect_filtered :headers

    def initialize(attributes = {})
      super
      @type = 'sse'
    end

    def to_h
      result = { type: @type, url: @url }
      result[:headers] = @headers if @headers
      result
    end
  end

  class McpHttpServerConfig < Type
    include Type::OptionValue

    attr_accessor :url, :headers
    attr_reader :type

    inspect_filtered :headers

    def initialize(attributes = {})
      super
      @type = 'http'
    end

    def to_h
      result = { type: @type, url: @url }
      result[:headers] = @headers if @headers
      result
    end
  end

  class McpSdkServerConfig < Type
    include Type::OptionValue

    attr_accessor :name, :instance
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'sdk'
    end

    def to_h
      { type: @type, name: @name, instance: @instance }
    end
  end

  # SDK Plugin configuration
  class SdkPluginConfig < Type
    include Type::OptionValue

    attr_accessor :path
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'local'
    end

    def to_h
      { type: @type, path: @path }
    end
  end

  # Sandbox network configuration
  class SandboxNetworkConfig < Type
    include Type::OptionValue

    attr_accessor :allowed_domains, :denied_domains, :allow_managed_domains_only,
                  :allow_unix_sockets, :allow_all_unix_sockets, :allow_local_binding,
                  :allow_mach_lookup, :http_proxy_port, :socks_proxy_port

    def to_h
      result = {}
      result[:allowedDomains] = @allowed_domains if @allowed_domains
      result[:deniedDomains] = @denied_domains if @denied_domains
      result[:allowManagedDomainsOnly] = @allow_managed_domains_only unless @allow_managed_domains_only.nil?
      result[:allowUnixSockets] = @allow_unix_sockets unless @allow_unix_sockets.nil?
      result[:allowAllUnixSockets] = @allow_all_unix_sockets unless @allow_all_unix_sockets.nil?
      result[:allowLocalBinding] = @allow_local_binding unless @allow_local_binding.nil?
      result[:allowMachLookup] = @allow_mach_lookup if @allow_mach_lookup
      result[:httpProxyPort] = @http_proxy_port if @http_proxy_port
      result[:socksProxyPort] = @socks_proxy_port if @socks_proxy_port
      result
    end
  end

  # Sandbox filesystem configuration
  class SandboxFilesystemConfig < Type
    include Type::OptionValue

    attr_accessor :allow_write, :deny_write, :deny_read, :allow_read, :allow_managed_read_paths_only

    def to_h
      result = {}
      result[:allowWrite] = @allow_write if @allow_write
      result[:denyWrite] = @deny_write if @deny_write
      result[:denyRead] = @deny_read if @deny_read
      result[:allowRead] = @allow_read if @allow_read
      result[:allowManagedReadPathsOnly] = @allow_managed_read_paths_only unless @allow_managed_read_paths_only.nil?
      result
    end
  end

  # Sandbox settings for isolated command execution
  class SandboxSettings < Type
    include Type::OptionValue

    attr_accessor :enabled, :fail_if_unavailable, :auto_allow_bash_if_sandboxed,
                  :excluded_commands, :allow_unsandboxed_commands, :network, :filesystem,
                  :ignore_violations, :enable_weaker_nested_sandbox,
                  :enable_weaker_network_isolation, :ripgrep

    def to_h
      result = {}
      result[:enabled] = @enabled unless @enabled.nil?
      result[:failIfUnavailable] = @fail_if_unavailable unless @fail_if_unavailable.nil?
      result[:autoAllowBashIfSandboxed] = @auto_allow_bash_if_sandboxed unless @auto_allow_bash_if_sandboxed.nil?
      result[:excludedCommands] = @excluded_commands if @excluded_commands
      result[:allowUnsandboxedCommands] = @allow_unsandboxed_commands unless @allow_unsandboxed_commands.nil?
      result[:network] = @network.is_a?(SandboxNetworkConfig) ? @network.to_h : @network if @network
      result[:filesystem] = @filesystem.is_a?(SandboxFilesystemConfig) ? @filesystem.to_h : @filesystem if @filesystem
      result[:ignoreViolations] = @ignore_violations if @ignore_violations
      result[:enableWeakerNestedSandbox] = @enable_weaker_nested_sandbox unless @enable_weaker_nested_sandbox.nil?
      result[:enableWeakerNetworkIsolation] = @enable_weaker_network_isolation unless @enable_weaker_network_isolation.nil?
      result[:ripgrep] = @ripgrep if @ripgrep
      result
    end
  end

  # Result of a session fork operation
  class ForkSessionResult < Type
    attr_accessor :session_id
  end

  # API-side task budget in tokens.
  # When set, the model is made aware of its remaining token budget so it can
  # pace tool use and wrap up before the limit.
  class TaskBudget < Type
    include Type::OptionValue

    attr_accessor :total

    def to_h
      { total: @total }
    end
  end

  # System prompt file configuration — loads system prompt from a file path
  class SystemPromptFile < Type
    include Type::OptionValue

    attr_accessor :path
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'file'
    end

    def to_h
      { type: @type, path: @path }
    end
  end

  # System prompt preset configuration.
  #
  # +snapshot+ controls whether the session keeps the system prompt it
  # recorded on its first request. When true, every later request (including
  # after resume) sends the recorded prompt, so a changed +append+ has no
  # effect until the session is compacted or a new session starts. When
  # false, the prompt is rebuilt on every request — useful while iterating on
  # +append+ text across calls that resume the same session. When nil
  # (omitted), the CLI treats it as true, except in bare mode (+--bare+),
  # where it acts as false. Sent on the control-protocol +initialize+ request
  # (never as a CLI flag); requires Claude Code CLI 2.1.257 or later, and
  # before 2.1.265 a session with an +append+ prompt recorded it only when
  # +snapshot+ was true. Older CLIs silently ignore it.
  class SystemPromptPreset < Type
    include Type::OptionValue

    attr_reader :type
    attr_accessor :preset, :append, :exclude_dynamic_sections, :snapshot

    def initialize(attributes = {})
      super
      @type = 'preset'
    end

    def to_h
      result = { type: @type, preset: @preset }
      result[:append] = @append if @append
      result[:exclude_dynamic_sections] = @exclude_dynamic_sections unless @exclude_dynamic_sections.nil?
      result[:snapshot] = @snapshot unless @snapshot.nil?
      result
    end
  end

  # Custom system prompt configuration — the object form of passing a String
  # as +system_prompt+. Reaches the CLI the same way a String does
  # (+--system-prompt <prompt>+); the object form exists so +snapshot+ can be
  # set alongside it (see SystemPromptPreset#snapshot for its semantics).
  class SystemPromptCustom < Type
    include Type::OptionValue

    attr_reader :type
    attr_accessor :prompt, :snapshot

    def initialize(attributes = {})
      super
      @type = 'custom'
    end

    def to_h
      result = { type: @type, prompt: @prompt }
      result[:snapshot] = @snapshot unless @snapshot.nil?
      result
    end
  end

  # Tools preset configuration
  class ToolsPreset < Type
    include Type::OptionValue

    attr_reader :type
    attr_accessor :preset

    def initialize(attributes = {})
      super
      @type = 'preset'
    end

    def to_h
      { type: @type, preset: @preset }
    end
  end

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
      raise ArgumentError, "callback_wrapper must be a callable or nil (got #{value.inspect})" unless value.nil? || value.respond_to?(:call)

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

  # SDK MCP Tool definition
  class SdkMcpTool < Type
    attr_accessor :name, :description, :input_schema, :handler, :annotations, :meta
  end

  # SDK MCP Resource definition
  class SdkMcpResource < Type
    attr_accessor :uri, :name, :description, :mime_type, :reader
  end

  # SDK MCP Prompt definition
  class SdkMcpPrompt < Type
    attr_accessor :name, :description, :arguments, :generator
  end
end
