# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
  # Type constants for hook events
  HOOK_EVENTS = %w[
    PreToolUse
    PostToolUse
    PostToolUseFailure
    PostToolBatch
    Notification
    UserPromptSubmit
    UserPromptExpansion
    SessionStart
    SessionEnd
    Stop
    StopFailure
    SubagentStart
    SubagentStop
    PreCompact
    PostCompact
    PreModelSwitch
    PostModelSwitch
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
    DirectoryAdded
    MessageDisplay
  ].freeze

  # Hook matcher configuration
  class HookMatcher < Type
    include Type::OptionValue

    strict_attributes

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

  # Base hook input with common fields.
  #
  # `prompt_id` is the UUID of the user prompt being processed (the
  # `prompt.id` of the CLI's OpenTelemetry events; absent before the first
  # prompt). `effort` is the reasoning effort in effect for the turn, a Hash
  # such as `{ level: "high" }`, sent on models that support effort.
  # `raw_input` is the payload exactly as the CLI sent it (Symbol keys), so a
  # field this SDK does not model yet can still be read.
  class BaseHookInput < Type
    attr_accessor :session_id, :transcript_path, :cwd, :permission_mode,
                  :prompt_id, :effort, :raw_input
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

  # PostToolUse hook input. `duration_ms` is the tool's execution time,
  # without permission prompts and hooks.
  class PostToolUseHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_response, :tool_use_id, :agent_id, :agent_type,
                  :duration_ms

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolUse'
    end
  end

  # UserPromptSubmit hook input
  class UserPromptSubmitHookInput < BaseHookInput
    attr_accessor :prompt, :session_title, :source

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

  # PostToolUseFailure hook input. `duration_ms` as on PostToolUseHookInput.
  class PostToolUseFailureHookInput < BaseHookInput
    attr_accessor :tool_name, :tool_input, :tool_use_id, :error, :is_interrupt,
                  :agent_id, :agent_type, :duration_ms

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

  # SessionStart hook input. On "resume" and "fork",
  # `seconds_since_last_response` is the time since the transcript's last
  # assistant response and `prompt_cache_likely_expired` says whether that
  # exceeds the prompt-cache TTL; `context_tokens` and
  # `estimated_cache_write_usd` size the prompt the next request re-sends.
  class SessionStartHookInput < BaseHookInput
    attr_accessor :source, :agent_type, :model, :session_title, :seconds_since_last_response,
                  :prompt_cache_likely_expired, :context_tokens, :estimated_cache_write_usd

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
    attr_accessor :file_path, :memory_type, :load_reason, :globs, :trigger_file_path, :parent_file_path

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

  # PostToolBatch hook input: fired once every tool call of a batch has
  # resolved, before the next model request. `tool_calls` is an Array of
  # `{ tool_name:, tool_input:, tool_use_id:, tool_response: }` Hashes.
  class PostToolBatchHookInput < BaseHookInput
    attr_accessor :tool_calls

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostToolBatch'
    end
  end

  # UserPromptExpansion hook input: a slash command or MCP prompt is about
  # to be expanded. `expansion_type` is "slash_command" or "mcp_prompt".
  class UserPromptExpansionHookInput < BaseHookInput
    attr_accessor :expansion_type, :command_name, :command_args, :command_source, :prompt

    def initialize(attributes = {})
      super
      @hook_event_name = 'UserPromptExpansion'
    end
  end

  # PreModelSwitch hook input. `requested_model` is what was asked for (an
  # alias, a full id, or nil for the default); `from_model` and `to_model`
  # are resolved ids. `context_tokens`, `prompt_cache_warm` and
  # `estimated_cache_write_usd` describe what switching costs.
  class PreModelSwitchHookInput < BaseHookInput
    attr_accessor :from_model, :to_model, :requested_model, :source,
                  :context_tokens, :prompt_cache_warm, :estimated_cache_write_usd

    def initialize(attributes = {})
      super
      @hook_event_name = 'PreModelSwitch'
    end
  end

  # PostModelSwitch hook input (the fields of PreModelSwitchHookInput)
  class PostModelSwitchHookInput < BaseHookInput
    attr_accessor :from_model, :to_model, :requested_model, :source,
                  :context_tokens, :prompt_cache_warm, :estimated_cache_write_usd

    def initialize(attributes = {})
      super
      @hook_event_name = 'PostModelSwitch'
    end
  end

  # DirectoryAdded hook input. `directory` is absolute; `source` is
  # "slash_command" (/add-dir) or "register_repo_root".
  class DirectoryAddedHookInput < BaseHookInput
    attr_accessor :directory, :source

    def initialize(attributes = {})
      super
      @hook_event_name = 'DirectoryAdded'
    end
  end

  # MessageDisplay hook input: one flush of an assistant message on its way
  # to the screen. `delta` holds the lines completed since the previous
  # flush; `index` counts flushes from 0 and `final` marks the last one.
  class MessageDisplayHookInput < BaseHookInput
    attr_accessor :turn_id, :message_id, :index, :final, :delta

    def initialize(attributes = {})
      super
      @hook_event_name = 'MessageDisplay'
    end
  end

  # Fallback for hook events the SDK does not yet model. Carries the wire
  # event name; the complete payload is in #raw_input, as on every hook
  # input, so no field is lost (Python passes hook input through as a raw
  # dict, so unknown events lose nothing there).
  class UnknownHookInput < BaseHookInput
    def initialize(attributes = {})
      super
      # Direct assignment: BaseHookInput exposes hook_event_name as
      # attr_reader only, and Type#assign_attribute silently drops keys
      # without public setters.
      @hook_event_name = attributes[:hook_event_name] || attributes['hook_event_name']
    end
  end

  # The spellings a hook callback's return value may use for a field of the
  # typed output classes below, mapped to the key the CLI reads. A Hash a
  # callback returns stands for the typed output with the same fields: its
  # keys may be Symbols or Strings, the attribute names (snake_case) or what
  # #to_h emits (camelCase), at the top level and inside hook_specific_output.
  #
  # Only names that differ from their wire key are listed. A key that is not
  # listed is sent as written, so a field of a newer CLI that the typed
  # classes do not model still gets through, in the CLI's own spelling.
  # spec/unit/hook_output_normalization_spec.rb walks every typed output
  # class and fails when an attribute and these tables disagree.
  #
  # @api private
  module HookOutputKeys
    # SyncHookJSONOutput and AsyncHookJSONOutput attributes, plus the
    # Ruby-safe spellings of the two keywords.
    TOP_LEVEL = {
      'continue_' => 'continue',
      'async_' => 'async',
      'suppress_output' => 'suppressOutput',
      'stop_reason' => 'stopReason',
      'system_message' => 'systemMessage',
      'hook_specific_output' => 'hookSpecificOutput',
      'async_timeout' => 'asyncTimeout'
    }.freeze

    # Attributes of the *HookSpecificOutput classes, which take their wire
    # keys from this table (HookSpecificOutputFields).
    HOOK_SPECIFIC = {
      'hook_event_name' => 'hookEventName',
      'permission_decision' => 'permissionDecision',
      'permission_decision_reason' => 'permissionDecisionReason',
      'updated_input' => 'updatedInput',
      'additional_context' => 'additionalContext',
      'updated_tool_output' => 'updatedToolOutput',
      'updated_mcp_tool_output' => 'updatedMCPToolOutput',
      'watch_paths' => 'watchPaths',
      'session_title' => 'sessionTitle',
      'suppress_original_prompt' => 'suppressOriginalPrompt',
      'initial_user_message' => 'initialUserMessage',
      'reload_skills' => 'reloadSkills',
      'worktree_path' => 'worktreePath',
      'display_content' => 'displayContent'
    }.freeze

    # The hook output Hash as the CLI reads it: String keys in wire
    # spelling, at the top level and one level down, inside
    # hookSpecificOutput. Values are never rewritten: updatedInput and the
    # tool outputs are the tool's own payloads, and a PermissionRequest
    # decision goes out as the caller wrote it.
    def self.normalize(output)
      normalized = rename(output, TOP_LEVEL)
      specific = normalized['hookSpecificOutput']
      normalized['hookSpecificOutput'] = rename(specific, HOOK_SPECIFIC) if specific.is_a?(Hash)
      normalized
    end

    # Every key ends up as one String, so a Symbol and a String spelling the
    # same field cannot both reach JSON.generate (json 3.x raises on that;
    # 2.x emits the key twice). When a Hash carries both spellings of one
    # field the wire spelling wins, whichever comes first; between two keys
    # in the same spelling the later one does.
    def self.rename(hash, table)
      renamed = {}
      wire_spelled = {}
      hash.each do |key, value|
        name = key.to_s
        wire = table.fetch(name, name)
        if wire == name
          wire_spelled[wire] = true
        elsif wire_spelled.key?(wire)
          next
        end
        renamed[wire] = value
      end
      renamed
    end
    private_class_method :rename
  end

  # Declares a *HookSpecificOutput class: the event it answers and its
  # fields. Each field is an attribute; #to_h writes hookEventName and every
  # field that is not nil, under the key HookOutputKeys::HOOK_SPECIFIC
  # gives it (the attribute name when the table has no entry).
  #
  # @api private
  module HookSpecificOutputFields
    def hook_specific_output(event, *fields)
      strict_attributes
      attr_accessor(*fields)
      attr_reader :hook_event_name

      wire_keys = fields.to_h { |field| [:"@#{field}", HookOutputKeys::HOOK_SPECIFIC.fetch(field.to_s, field.to_s).to_sym] }
      define_method(:initialize) do |attributes = {}|
        super(attributes)
        @hook_event_name = event
      end
      define_method(:to_h) do
        wire_keys.each_with_object({ hookEventName: @hook_event_name }) do |(ivar, key), result|
          value = instance_variable_get(ivar)
          result[key] = value unless value.nil?
        end
      end
    end
  end

  # Setup hook specific output
  class SetupHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'Setup', :additional_context
  end

  # PreToolUse hook specific output
  class PreToolUseHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'PreToolUse',
                         :permission_decision, :permission_decision_reason, :updated_input, :additional_context
  end

  # PostToolUse hook specific output.
  #
  # `updated_tool_output` (CLI 2.1.110+) replaces the tool's output entirely
  # — works for any tool, MCP or built-in. `updated_mcp_tool_output` is the
  # legacy MCP-only field that pre-dates the unified one; the CLI still
  # honors it, so both are emitted when set. Mirrors Python's
  # `PostToolUseHookSpecificOutput`.
  class PostToolUseHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'PostToolUse', :additional_context, :updated_tool_output, :updated_mcp_tool_output
  end

  # PostToolUseFailure hook specific output
  class PostToolUseFailureHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'PostToolUseFailure', :additional_context
  end

  # PostToolBatch hook specific output
  class PostToolBatchHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'PostToolBatch', :additional_context
  end

  # UserPromptSubmit hook specific output. `session_title` sets the session
  # title; `suppress_original_prompt` leaves the prompt out of the block
  # message when the hook's decision is "block".
  class UserPromptSubmitHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'UserPromptSubmit', :additional_context, :session_title, :suppress_original_prompt
  end

  # UserPromptExpansion hook specific output (`suppress_original_prompt` as
  # on UserPromptSubmitHookSpecificOutput)
  class UserPromptExpansionHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'UserPromptExpansion', :additional_context, :suppress_original_prompt
  end

  # Notification hook specific output
  class NotificationHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'Notification', :additional_context
  end

  # SubagentStart hook specific output
  class SubagentStartHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'SubagentStart', :additional_context
  end

  # Stop hook specific output. `additional_context` is feedback for the
  # model, not an error: the conversation continues so it can act on it.
  class StopHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'Stop', :additional_context
  end

  # SubagentStop hook specific output (`additional_context` as on
  # StopHookSpecificOutput, delivered to the subagent)
  class SubagentStopHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'SubagentStop', :additional_context
  end

  # PermissionRequest hook specific output
  class PermissionRequestHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'PermissionRequest', :decision
  end

  # SessionStart hook specific output. `initial_user_message` becomes the
  # session's first user message; `session_title` sets its title (ignored
  # when the session starts from "clear" or "compact"); `watch_paths` are
  # absolute paths to watch for FileChanged; `reload_skills` re-scans skill
  # and command directories once SessionStart hooks finish.
  class SessionStartHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'SessionStart',
                         :additional_context, :initial_user_message, :session_title, :watch_paths, :reload_skills
  end

  # PermissionDenied hook specific output. `retry: true` tells the model it
  # may retry the denied call (ignored for denials without a classifier
  # verdict); left nil, the key is not sent, which the CLI reads as false.
  class PermissionDeniedHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'PermissionDenied', :retry
  end

  # PreModelSwitch hook specific output. `permission_decision` "allow"
  # proceeds and "deny" cancels the switch; "ask" is a refusal outside an
  # interactive session.
  class PreModelSwitchHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'PreModelSwitch', :permission_decision, :permission_decision_reason
  end

  # PostModelSwitch hook specific output (`additional_context` reaches the
  # model with the next request the new model serves)
  class PostModelSwitchHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'PostModelSwitch', :additional_context
  end

  # Elicitation hook specific output: answers an MCP elicitation request.
  # `action` is "accept", "decline" or "cancel"; `content` holds the form
  # values to submit with "accept".
  class ElicitationHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'Elicitation', :action, :content
  end

  # ElicitationResult hook specific output: overrides the action or content
  # before the response reaches the MCP server.
  class ElicitationResultHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'ElicitationResult', :action, :content
  end

  # CwdChanged hook specific output (`watch_paths` replaces the dynamic
  # FileChanged watch list)
  class CwdChangedHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'CwdChanged', :watch_paths
  end

  # FileChanged hook specific output (`watch_paths` as on
  # CwdChangedHookSpecificOutput)
  class FileChangedHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'FileChanged', :watch_paths
  end

  # WorktreeCreate hook specific output (`worktree_path`: the absolute path
  # of the created worktree)
  class WorktreeCreateHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'WorktreeCreate', :worktree_path
  end

  # MessageDisplay hook specific output. `display_content` replaces the text
  # on screen only: the stored message and what the model sees are
  # unchanged. Left nil, the original is displayed.
  class MessageDisplayHookSpecificOutput < Type
    extend HookSpecificOutputFields

    hook_specific_output 'MessageDisplay', :display_content
  end

  # Async hook JSON output
  class AsyncHookJSONOutput < Type
    strict_attributes

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
    strict_attributes

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
end
