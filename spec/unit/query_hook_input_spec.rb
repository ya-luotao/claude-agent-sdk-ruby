# frozen_string_literal: true

require 'spec_helper'

# What a hook callback is handed, for every hook event: the typed input the
# SDK builds from a `hook_callback` control request, checked reader by
# reader. A field mapped from the wrong key, or dropped, used to pass the
# whole suite for 19 of the 27 events.
#
# One row per event in ClaudeAgentSDK::HOOK_EVENTS. An event without a row,
# and a reader its row gives no value to, both fail here — so the table has
# to be extended when an event or a reader is added.
RSpec.describe ClaudeAgentSDK::Query do
  describe 'the typed input of a hook_callback request' do
    # The event's own fields, by the names the CLI uses on the wire, with the
    # JSON type each one has there. The fields every event carries are in
    # #base_fields.
    fields = {
      'PreToolUse' => { tool_name: :string, tool_input: :object, tool_use_id: :string,
                        agent_id: :string, agent_type: :string },
      'PostToolUse' => { tool_name: :string, tool_input: :object, tool_response: :object, tool_use_id: :string,
                         agent_id: :string, agent_type: :string, duration_ms: :integer },
      'PostToolUseFailure' => { tool_name: :string, tool_input: :object, tool_use_id: :string, error: :string,
                                is_interrupt: :boolean, agent_id: :string, agent_type: :string,
                                duration_ms: :integer },
      'PostToolBatch' => { tool_calls: :objects },
      'Notification' => { message: :string, title: :string, notification_type: :string },
      'UserPromptSubmit' => { prompt: :string, session_title: :string, source: :string },
      'UserPromptExpansion' => { expansion_type: :string, command_name: :string, command_args: :string,
                                 command_source: :string, prompt: :string },
      'SessionStart' => { source: :string, agent_type: :string, model: :string, session_title: :string,
                          seconds_since_last_response: :integer, prompt_cache_likely_expired: :boolean,
                          context_tokens: :integer, estimated_cache_write_usd: :number },
      'SessionEnd' => { reason: :string },
      'Stop' => { stop_hook_active: :boolean, last_assistant_message: :string, background_tasks: :objects,
                  session_crons: :objects },
      'StopFailure' => { error: :string, error_details: :string, last_assistant_message: :string },
      'SubagentStart' => { agent_id: :string, agent_type: :string },
      'SubagentStop' => { stop_hook_active: :boolean, agent_id: :string, agent_transcript_path: :string,
                          agent_type: :string, last_assistant_message: :string, background_tasks: :objects,
                          session_crons: :objects },
      'PreCompact' => { trigger: :string, custom_instructions: :string },
      'PostCompact' => { trigger: :string, compact_summary: :string },
      'PreModelSwitch' => { from_model: :string, to_model: :string, requested_model: :string, source: :string,
                            context_tokens: :integer, prompt_cache_warm: :boolean,
                            estimated_cache_write_usd: :number },
      'PostModelSwitch' => { from_model: :string, to_model: :string, requested_model: :string, source: :string,
                             context_tokens: :integer, prompt_cache_warm: :boolean,
                             estimated_cache_write_usd: :number },
      'PermissionRequest' => { tool_name: :string, tool_input: :object, permission_suggestions: :objects,
                               agent_id: :string, agent_type: :string },
      'PermissionDenied' => { tool_name: :string, tool_input: :object, tool_use_id: :string, reason: :string,
                              agent_id: :string, agent_type: :string },
      'Setup' => { trigger: :string },
      'TeammateIdle' => { teammate_name: :string, team_name: :string },
      'TaskCreated' => { task_id: :string, task_subject: :string, task_description: :string,
                         teammate_name: :string, team_name: :string },
      'TaskCompleted' => { task_id: :string, task_subject: :string, task_description: :string,
                           teammate_name: :string, team_name: :string },
      'Elicitation' => { mcp_server_name: :string, message: :string, mode: :string, url: :string,
                         elicitation_id: :string, requested_schema: :object },
      'ElicitationResult' => { mcp_server_name: :string, elicitation_id: :string, mode: :string, action: :string,
                               content: :object },
      'ConfigChange' => { source: :string, file_path: :string },
      'WorktreeCreate' => { name: :string },
      'WorktreeRemove' => { worktree_path: :string },
      'InstructionsLoaded' => { file_path: :string, memory_type: :string, load_reason: :string, globs: :strings,
                                trigger_file_path: :string, parent_file_path: :string },
      'CwdChanged' => { old_cwd: :string, new_cwd: :string },
      'FileChanged' => { file_path: :string, event: :string },
      'DirectoryAdded' => { directory: :string, source: :string },
      'MessageDisplay' => { turn_id: :string, message_id: :string, index: :integer, final: :boolean,
                            delta: :string }
    }.freeze

    # A value of the field's JSON type that names the field, so no two fields
    # of a frame carry the same one and a field read from the wrong key shows.
    def sentinel(event, field, type)
      marker = "#{field} of #{event}"
      case type
      when :string then marker
      when :strings then [marker]
      when :object then { marker: marker }
      when :objects then [{ marker: marker }]
      when :integer then "#{field}#{event}".sum # a number of its own per field
      when :number then "#{field}#{event}".sum + 0.25
      when :boolean then true # the inputs default it to false or nil
      else raise ArgumentError, "unknown wire type #{type.inspect} for #{marker}"
      end
    end

    # What every hook input carries. scratchpad_dir is on the frames CLI
    # 2.1.286 sends; the typed inputs have no reader for it, so it is only
    # in #raw_input.
    def base_fields(event)
      { session_id: "session_id of #{event}", transcript_path: "transcript_path of #{event}",
        cwd: "cwd of #{event}", scratchpad_dir: "scratchpad_dir of #{event}", prompt_id: "prompt_id of #{event}",
        permission_mode: "permission_mode of #{event}", effort: { level: "effort of #{event}" },
        hook_event_name: event }
    end

    # Registers one hook for +event+, sends it one hook_callback request the
    # way the CLI does and returns what the callback was called with, plus
    # the SDK's reply.
    def dispatch_hook(event, input)
      calls = []
      hook = lambda do |hook_input, tool_use_id, context|
        calls << { input: hook_input, tool_use_id: tool_use_id, context: context }
        {}
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        hooks: { event => [ClaudeAgentSDK::HookMatcher.new(hooks: [hook])] }
      )
      reply = ScriptedCLI.session(options) do |cli|
        cli.request({ subtype: 'hook_callback', callback_id: cli.hook_callback_ids(event).fetch(0),
                      tool_use_id: "request tool_use_id of #{event}", input: input },
                    request_id: "request_id of #{event}")
      end
      [calls, reply]
    end

    it 'has a row for every event in HOOK_EVENTS, and no other' do
      expect(fields.keys).to match_array(ClaudeAgentSDK::HOOK_EVENTS)
    end

    ClaudeAgentSDK::HOOK_EVENTS.each do |event|
      it "hands a #{event} hook every field of the frame through its typed input" do
        own = fields.fetch(event) { raise "no row for #{event}: add its wire fields to the table above" }
        input = base_fields(event).merge(own.to_h { |field, type| [field, sentinel(event, field, type)] })
        input_class = ClaudeAgentSDK.const_get("#{event}HookInput")

        calls, reply = dispatch_hook(event, input)

        expect(calls.length).to eq(1)
        hook_input = calls.first[:input]
        expect(hook_input).to be_an_instance_of(input_class)
        # Every reader the class declares, not only the ones the row names: a
        # reader without a value in the frame is a row that fell behind.
        expect(hook_input.raw_input).to eq(input)
        (input_class.attribute_names - ['raw_input']).each do |reader|
          expected = input.fetch(reader.to_sym) do
            raise "#{input_class} has a reader ##{reader} the #{event} row gives no value: add the wire field"
          end
          actual = hook_input.public_send(reader)
          expect(actual).to eq(expected), "#{input_class}##{reader}: expected #{expected.inspect}, got #{actual.inspect}"
        end
        # ...and no field in the row the class cannot read, which would
        # leave that column of the table unchecked.
        expect(input_class.attribute_names).to include(*own.keys.map(&:to_s))

        expect(calls.first[:tool_use_id]).to eq("request tool_use_id of #{event}")
        expect(calls.first[:context]).to be_a(ClaudeAgentSDK::HookContext)
        expect(calls.first[:context].request_id).to eq("request_id of #{event}")
        expect(reply).to include('subtype' => 'success', 'request_id' => "request_id of #{event}")
      end
    end

    it 'hands an event this SDK does not model over as an UnknownHookInput with the whole frame' do
      input = base_fields('FutureEvent').merge(future_field: { nested: [1, 2] })

      calls, = dispatch_hook('FutureEvent', input)

      hook_input = calls.first[:input]
      expect(hook_input).to be_an_instance_of(ClaudeAgentSDK::UnknownHookInput)
      expect(hook_input.hook_event_name).to eq('FutureEvent')
      expect(hook_input.prompt_id).to eq('prompt_id of FutureEvent')
      expect(hook_input.effort).to eq(level: 'effort of FutureEvent')
      expect(hook_input.raw_input).to eq(input)
    end
  end
end
