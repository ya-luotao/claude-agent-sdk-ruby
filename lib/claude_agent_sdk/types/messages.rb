# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
  # Type constants for assistant message errors
  ASSISTANT_MESSAGE_ERRORS = %w[authentication_failed billing_error rate_limit invalid_request server_error max_output_tokens unknown].freeze

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
end
