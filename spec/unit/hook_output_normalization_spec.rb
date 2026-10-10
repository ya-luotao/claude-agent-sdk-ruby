# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'json'

# A hook callback may return a Hash instead of a typed output; the shipped
# signature says "a Hash (snake_case or camelCase keys)". The SDK used to
# rename five top-level keys, only when they were Symbols, and forward a
# nested hook_specific_output Hash untouched. A PreToolUse deny written in
# Ruby spelling therefore reached the CLI under keys it does not read, the
# object was ignored, and the tool ran.
#
# Every example asserts on the control_response frame the SDK writes for a
# hook_callback request, never on the private converter.
RSpec.describe 'hook output normalization' do
  # The hook_callback request CLI 2.1.286 writes for a PreToolUse hook
  # (recorded from a real session; only the home directory is shortened), as
  # the transport hands it to Query: parsed with Symbol keys. The reply is
  # built from the callback's return value alone, so the examples for other
  # events reuse this envelope with their own event name.
  def hook_callback_request(event)
    request = JSON.parse(<<~FRAME, symbolize_names: true)
      {"type":"control_request","request_id":"a0ae4d7c-684f-4cd2-a36a-e5e7f1e7e928","request":{"subtype":"hook_callback","callback_id":"hook_0","input":{"session_id":"097e32d1-723a-42b4-a59b-f816b0d9ac84","transcript_path":"/home/dev/.claude/projects/-work-app/097e32d1-723a-42b4-a59b-f816b0d9ac84.jsonl","cwd":"/work/app","scratchpad_dir":"/private/tmp/claude-501/-work-app/097e32d1-723a-42b4-a59b-f816b0d9ac84/scratchpad","prompt_id":"efe95091-ba7c-4f07-8d76-e376ef8f0c92","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Remove the build directory"},"tool_use_id":"toolu_01PsVteovwuBVRcCCBHw4EC7"},"tool_use_id":"toolu_01PsVteovwuBVRcCCBHw4EC7"}}
    FRAME
    request[:request][:input][:hook_event_name] = event
    request
  end

  # Answers the request with +output+ (what the hook callback returns) and
  # gives back the one line the SDK wrote to the CLI.
  def reply_line(output, event: 'PreToolUse')
    writes = []
    transport = instance_double(ClaudeAgentSDK::Transport)
    allow(transport).to receive(:write) { |data| writes << data }
    query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true)
    query.instance_variable_set(:@hook_callbacks, { 'hook_0' => ->(_input, _tool_use_id, _context) { output } })

    Async { query.send(:handle_control_request, hook_callback_request(event)) }.wait

    expect(writes.size).to eq(1)
    writes.first
  end

  # The hook output as the CLI reads it: the `response` object of a
  # successful control_response.
  def reply(output, **)
    frame = JSON.parse(reply_line(output, **))
    expect(frame['response']).to include('subtype' => 'success', 'request_id' => 'a0ae4d7c-684f-4cd2-a36a-e5e7f1e7e928')
    frame['response'].fetch('response')
  end

  # What JSON makes of a Ruby value (Symbol keys and values become Strings).
  def on_the_wire(value)
    JSON.parse(JSON.generate(value))
  end

  describe 'a PreToolUse deny' do
    typed = ClaudeAgentSDK::SyncHookJSONOutput.new(
      hook_specific_output: ClaudeAgentSDK::PreToolUseHookSpecificOutput.new(
        permission_decision: 'deny', permission_decision_reason: 'rm -rf is not allowed here'
      )
    )

    it 'reaches the CLI in wire spelling when the output is typed' do
      expect(JSON.parse(reply_line(typed))).to eq(
        'type' => 'control_response',
        'response' => {
          'subtype' => 'success',
          'request_id' => 'a0ae4d7c-684f-4cd2-a36a-e5e7f1e7e928',
          'requestId' => 'a0ae4d7c-684f-4cd2-a36a-e5e7f1e7e928',
          'response' => {
            'continue' => true,
            'hookSpecificOutput' => {
              'hookEventName' => 'PreToolUse',
              'permissionDecision' => 'deny',
              'permissionDecisionReason' => 'rm -rf is not allowed here'
            }
          }
        }
      )
    end

    {
      'snake_case Symbol keys, nested ones included' => {
        continue_: true,
        hook_specific_output: {
          hook_event_name: 'PreToolUse', permission_decision: 'deny',
          permission_decision_reason: 'rm -rf is not allowed here'
        }
      },
      'String keys at the top level and camelCase inside' => {
        'continue' => true,
        'hook_specific_output' => {
          hookEventName: 'PreToolUse', permissionDecision: 'deny',
          permissionDecisionReason: 'rm -rf is not allowed here'
        }
      },
      'a typed output that holds a snake_case Hash' => ClaudeAgentSDK::SyncHookJSONOutput.new(
        hook_specific_output: {
          hook_event_name: 'PreToolUse', permission_decision: 'deny',
          permission_decision_reason: 'rm -rf is not allowed here'
        }
      ),
      'snake_case String keys throughout' => {
        'continue_' => true,
        'hook_specific_output' => {
          'hook_event_name' => 'PreToolUse', 'permission_decision' => 'deny',
          'permission_decision_reason' => 'rm -rf is not allowed here'
        }
      },
      'camelCase Symbol keys (the documented form)' => {
        continue: true,
        hookSpecificOutput: {
          hookEventName: 'PreToolUse', permissionDecision: 'deny',
          permissionDecisionReason: 'rm -rf is not allowed here'
        }
      },
      'a Hash that holds a typed hook_specific_output' => {
        continue_: true,
        hook_specific_output: ClaudeAgentSDK::PreToolUseHookSpecificOutput.new(
          permission_decision: 'deny', permission_decision_reason: 'rm -rf is not allowed here'
        )
      }
    }.each do |form, output|
      it "writes the same control_response for #{form}" do
        expect(JSON.parse(reply_line(output))).to eq(JSON.parse(reply_line(typed)))
      end
    end
  end

  # Every field of every typed hook output class: attribute => [wire key,
  # value]. The wire keys are spelled out here, not derived from the SDK, so
  # a renamed key on either side fails the round trip below.
  specific_outputs = {
    'SetupHookSpecificOutput' => {
      hook_event_name: %w[hookEventName Setup],
      additional_context: ['additionalContext', 'Dependencies are installed.']
    },
    'PreToolUseHookSpecificOutput' => {
      hook_event_name: %w[hookEventName PreToolUse],
      permission_decision: %w[permissionDecision ask],
      permission_decision_reason: ['permissionDecisionReason', 'Touches the lockfile.'],
      updated_input: ['updatedInput', { command: 'bundle install --frozen', run_in_background: false }],
      additional_context: ['additionalContext', 'Gemfile.lock is under review.']
    },
    'PostToolUseHookSpecificOutput' => {
      hook_event_name: %w[hookEventName PostToolUse],
      additional_context: ['additionalContext', 'Secrets were redacted.'],
      updated_tool_output: ['updatedToolOutput', { stdout: '[redacted]', stderr: '', exit_code: 0 }],
      updated_mcp_tool_output: ['updatedMCPToolOutput',
                                { content: [{ type: 'text', text: '[redacted]' }], is_error: false }]
    },
    'PostToolUseFailureHookSpecificOutput' => {
      hook_event_name: %w[hookEventName PostToolUseFailure],
      additional_context: ['additionalContext', 'The registry is down; do not retry.']
    },
    'PostToolBatchHookSpecificOutput' => {
      hook_event_name: %w[hookEventName PostToolBatch],
      additional_context: ['additionalContext', 'Two of the three writes touched generated files.']
    },
    'UserPromptSubmitHookSpecificOutput' => {
      hook_event_name: %w[hookEventName UserPromptSubmit],
      additional_context: ['additionalContext', 'The user is on the staging cluster.'],
      session_title: ['sessionTitle', 'Staging rollout'],
      suppress_original_prompt: ['suppressOriginalPrompt', true]
    },
    'UserPromptExpansionHookSpecificOutput' => {
      hook_event_name: %w[hookEventName UserPromptExpansion],
      additional_context: ['additionalContext', '/deploy targets staging by default.'],
      suppress_original_prompt: ['suppressOriginalPrompt', false]
    },
    'NotificationHookSpecificOutput' => {
      hook_event_name: %w[hookEventName Notification],
      additional_context: ['additionalContext', 'Forwarded to the on-call channel.']
    },
    'SubagentStartHookSpecificOutput' => {
      hook_event_name: %w[hookEventName SubagentStart],
      additional_context: ['additionalContext', 'Only read from the replica.']
    },
    'PermissionRequestHookSpecificOutput' => {
      hook_event_name: %w[hookEventName PermissionRequest],
      decision: ['decision', { behavior: 'allow', updatedInput: { command: 'ls -la' } }]
    },
    'SessionStartHookSpecificOutput' => {
      hook_event_name: %w[hookEventName SessionStart],
      additional_context: ['additionalContext', 'Branch: main, clean tree.'],
      initial_user_message: ['initialUserMessage', 'Summarize the open pull requests.'],
      session_title: ['sessionTitle', 'PR triage'],
      watch_paths: ['watchPaths', %w[/work/app/Gemfile.lock]],
      reload_skills: ['reloadSkills', true]
    },
    'StopHookSpecificOutput' => {
      hook_event_name: %w[hookEventName Stop],
      additional_context: ['additionalContext', 'The changelog entry is still missing.']
    },
    'SubagentStopHookSpecificOutput' => {
      hook_event_name: %w[hookEventName SubagentStop],
      additional_context: ['additionalContext', 'Also list the files you skipped.']
    },
    'PreModelSwitchHookSpecificOutput' => {
      hook_event_name: %w[hookEventName PreModelSwitch],
      permission_decision: %w[permissionDecision deny],
      permission_decision_reason: ['permissionDecisionReason', 'The prompt cache is warm.']
    },
    'PostModelSwitchHookSpecificOutput' => {
      hook_event_name: %w[hookEventName PostModelSwitch],
      additional_context: ['additionalContext', 'Keep answers short from here on.']
    },
    'ElicitationHookSpecificOutput' => {
      hook_event_name: %w[hookEventName Elicitation],
      action: %w[action accept],
      content: ['content', { environment: 'staging', confirm: true }]
    },
    'ElicitationResultHookSpecificOutput' => {
      hook_event_name: %w[hookEventName ElicitationResult],
      action: %w[action decline],
      content: ['content', { reason: 'outside business hours' }]
    },
    'WorktreeCreateHookSpecificOutput' => {
      hook_event_name: %w[hookEventName WorktreeCreate],
      worktree_path: ['worktreePath', '/work/worktrees/fix-login']
    },
    'MessageDisplayHookSpecificOutput' => {
      hook_event_name: %w[hookEventName MessageDisplay],
      display_content: ['displayContent', 'Deploying to [redacted]...']
    },
    'PermissionDeniedHookSpecificOutput' => {
      hook_event_name: %w[hookEventName PermissionDenied],
      retry: ['retry', true]
    },
    'CwdChangedHookSpecificOutput' => {
      hook_event_name: %w[hookEventName CwdChanged],
      watch_paths: ['watchPaths', %w[/work/app/config /work/app/.env]]
    },
    'FileChangedHookSpecificOutput' => {
      hook_event_name: %w[hookEventName FileChanged],
      watch_paths: ['watchPaths', %w[/work/app/config/routes.rb]]
    }
  }.freeze

  top_level_outputs = {
    'SyncHookJSONOutput' => {
      continue: ['continue', false],
      suppress_output: ['suppressOutput', true],
      stop_reason: ['stopReason', 'The budget is exhausted.'],
      decision: %w[decision block],
      system_message: ['systemMessage', 'Stopped by the deploy freeze.'],
      reason: ['reason', 'The test suite is failing.'],
      hook_specific_output: ['hookSpecificOutput',
                             { hookEventName: 'PostToolUse', additionalContext: 'Lint failed.' }]
    },
    'AsyncHookJSONOutput' => {
      async: ['async', true],
      async_timeout: ['asyncTimeout', 5000]
    }
  }.freeze

  # The spellings a Hash may use for those fields.
  spellings = {
    'snake_case Symbol keys' => ->(fields) { fields.transform_values(&:last) },
    'snake_case String keys' => ->(fields) { fields.to_h { |name, (_wire, value)| [name.to_s, value] } },
    'camelCase Symbol keys' => ->(fields) { fields.to_h { |_name, (wire, value)| [wire.to_sym, value] } },
    'camelCase String keys' => ->(fields) { fields.to_h { |_name, (wire, value)| [wire, value] } }
  }.freeze
  attributes_of = spellings.fetch('snake_case Symbol keys')
  wire_form_of = spellings.fetch('camelCase String keys')

  describe 'every field of every typed hook output class' do
    output_classes = ClaudeAgentSDK.constants.grep(/Hook(?:SpecificOutput|JSONOutput)\z/).map(&:to_s)
    rows = specific_outputs.merge(top_level_outputs)

    it 'has a row for every class' do
      expect(rows.keys).to match_array(output_classes)
    end

    it 'has a field for every attribute' do
      expect(rows.transform_values { |fields| fields.keys.map(&:to_s).sort })
        .to eq(rows.to_h { |class_name, _fields| [class_name, ClaudeAgentSDK.const_get(class_name).attribute_names] })
    end

    specific_outputs.each do |class_name, fields|
      describe "ClaudeAgentSDK::#{class_name}" do
        let(:klass) { ClaudeAgentSDK.const_get(class_name) }
        let(:event) { fields.fetch(:hook_event_name).last }
        let(:expected) { { 'continue' => true, 'hookSpecificOutput' => on_the_wire(wire_form_of.call(fields)) } }

        # The forms the enclosing output may take around one nested value.
        def enclosing(nested)
          {
            'typed output' => ClaudeAgentSDK::SyncHookJSONOutput.new(hook_specific_output: nested),
            'snake_case Symbol keys' => { continue_: true, hook_specific_output: nested },
            'snake_case String keys' => { 'continue_' => true, 'hook_specific_output' => nested },
            'camelCase Symbol keys' => { continue: true, hookSpecificOutput: nested },
            'camelCase String keys' => { 'continue' => true, 'hookSpecificOutput' => nested }
          }
        end

        def replies_to(forms, event)
          forms.transform_values { |output| reply(output, event: event) }
        end

        it 'is written under its wire keys when typed' do
          forms = enclosing(klass.new(attributes_of.call(fields)))

          expect(replies_to(forms, event)).to eq(forms.transform_values { expected })
        end

        spellings.each do |spelling, hash_in|
          it "is written the same way from a Hash with #{spelling}" do
            forms = enclosing(hash_in.call(fields))

            expect(replies_to(forms, event)).to eq(forms.transform_values { expected })
          end
        end
      end
    end

    top_level_outputs.each do |class_name, fields|
      describe "ClaudeAgentSDK::#{class_name}" do
        let(:expected) { on_the_wire(wire_form_of.call(fields)) }

        it 'is written under its wire keys when typed' do
          expect(reply(ClaudeAgentSDK.const_get(class_name).new(attributes_of.call(fields)))).to eq(expected)
        end

        spellings.each do |spelling, hash_in|
          it "is written the same way from a Hash with #{spelling}" do
            expect(reply(hash_in.call(fields))).to eq(expected)
          end
        end
      end
    end
  end

  # The vocabulary is a hand-written table next to the typed classes. Walk
  # every class so the two cannot drift: a new attribute, or a renamed wire
  # key in a #to_h, fails here until the table follows.
  describe 'ClaudeAgentSDK::HookOutputKeys' do
    { 'TOP_LEVEL' => [top_level_outputs, %w[async_ continue_]],
      'HOOK_SPECIFIC' => [specific_outputs, []] }.each do |table_name, (rows, ruby_safe_spellings)|
      describe table_name do
        let(:table) { ClaudeAgentSDK::HookOutputKeys.const_get(table_name) }

        it 'gives every attribute of every typed output class the key its #to_h emits' do
          emitted = rows.to_h do |class_name, fields|
            [class_name, ClaudeAgentSDK.const_get(class_name).new(attributes_of.call(fields)).to_h.keys.map(&:to_s).sort]
          end
          mapped = rows.to_h do |class_name, _fields|
            names = ClaudeAgentSDK.const_get(class_name).attribute_names
            [class_name, names.map { |name| table.fetch(name, name) }.sort]
          end

          expect(mapped).to eq(emitted)
        end

        it 'lists nothing but those attributes and the Ruby-safe spellings of keywords' do
          attributes = rows.keys.flat_map { |class_name| ClaudeAgentSDK.const_get(class_name).attribute_names }

          expect(table.keys - attributes).to match_array(ruby_safe_spellings)
        end
      end
    end
  end

  describe 'a key outside the vocabulary' do
    it 'is sent as written, at the top level and inside hook_specific_output' do
      output = {
        hook_specific_output: {
          hook_event_name: 'PreToolUse',
          permission_decision: 'allow',
          sessionTitle: 'Nightly build',
          future_field: { inner_key: true },
          'x-vendor' => 1
        },
        futureField: { some_key: 1 },
        'future_field' => 'kept'
      }

      expect(reply(output)).to eq(
        'hookSpecificOutput' => {
          'hookEventName' => 'PreToolUse',
          'permissionDecision' => 'allow',
          'sessionTitle' => 'Nightly build',
          'future_field' => { 'inner_key' => true },
          'x-vendor' => 1
        },
        'futureField' => { 'some_key' => 1 },
        'future_field' => 'kept'
      )
    end

    it 'includes a name the SDK only knows at the other level' do
      output = {
        permission_decision: 'deny',
        hook_specific_output: { hook_event_name: 'PreToolUse', suppress_output: true, stop_reason: 'x' }
      }

      expect(reply(output)).to eq(
        'permission_decision' => 'deny',
        'hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'suppress_output' => true, 'stop_reason' => 'x' }
      )
    end
  end

  describe 'the value of a field' do
    # Tool input and tool output are the tool's own payloads: a key in there
    # that happens to be spelled like a hook field is not one.
    tool_payload = {
      file_path: '/work/app/config.rb', old_string: 'a', new_string: 'b',
      hook_event_name: 'kept', 'permission_decision' => 'kept', suppress_output: true,
      nested: { additional_context: 'kept', watch_paths: ['kept'] }
    }.freeze

    {
      'updated_input' => ['PreToolUse', :updated_input, 'updatedInput'],
      'updatedInput' => ['PreToolUse', :updatedInput, 'updatedInput'],
      'updated_tool_output' => %w[PostToolUse updated_tool_output updatedToolOutput],
      'updatedToolOutput' => %w[PostToolUse updatedToolOutput updatedToolOutput],
      'updated_mcp_tool_output' => ['PostToolUse', :updated_mcp_tool_output, 'updatedMCPToolOutput'],
      'updatedMCPToolOutput' => ['PostToolUse', :updatedMCPToolOutput, 'updatedMCPToolOutput']
    }.each do |spelling, (event, key, wire_key)|
      it "is not rewritten under #{spelling}" do
        output = { hook_specific_output: { hook_event_name: event, key => tool_payload } }

        expect(reply(output, event: event)).to eq(
          'hookSpecificOutput' => { 'hookEventName' => event, wire_key => on_the_wire(tool_payload) }
        )
      end
    end

    it 'is not rewritten for the decision of a PermissionRequest output' do
      decision = { behavior: 'allow', updated_input: { command: 'ls' }, 'updatedPermissions' => [{ rule_content: 'x' }] }
      output = { hook_specific_output: { hook_event_name: 'PermissionRequest', decision: decision } }

      expect(reply(output, event: 'PermissionRequest')).to eq(
        'hookSpecificOutput' => { 'hookEventName' => 'PermissionRequest', 'decision' => on_the_wire(decision) }
      )
    end
  end

  describe 'a Hash that spells one field both ways' do
    allow_then_deny = { hook_event_name: 'PreToolUse', permission_decision: 'allow', permissionDecision: 'deny' }
    deny_then_allow = { hookEventName: 'PreToolUse', permissionDecision: 'deny', permission_decision: 'allow' }
    denied = { 'hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'deny' } }

    it 'sends the camelCase spelling inside hook_specific_output, whichever comes first' do
      outputs = [allow_then_deny, deny_then_allow, allow_then_deny.transform_keys(&:to_s)]

      expect(outputs.map { |nested| reply({ hook_specific_output: nested }) }).to eq([denied] * 3)
    end

    it 'sends the camelCase spelling at the top level, whichever comes first' do
      allowed = { hookEventName: 'PreToolUse', permissionDecision: 'allow' }
      wins = { hookEventName: 'PreToolUse', permissionDecision: 'deny' }
      outputs = [
        { hook_specific_output: allowed, hookSpecificOutput: wins },
        { hookSpecificOutput: wins, hook_specific_output: allowed },
        { 'hook_specific_output' => allowed, 'hookSpecificOutput' => wins }
      ]

      expect(outputs.map { |output| reply(output) }).to eq([denied] * 3)
    end

    it 'sends continue rather than continue_, and async rather than async_' do
      outputs = [{ continue_: true, continue: false }, { continue: false, continue_: true },
                 { async_: false, 'async' => true }, { 'async' => true, async_: false }]

      expect(outputs.map { |output| reply(output) })
        .to eq([{ 'continue' => false }, { 'continue' => false }, { 'async' => true }, { 'async' => true }])
    end

    it 'writes the field once' do
      line = reply_line({ hook_specific_output: allow_then_deny, hookSpecificOutput: deny_then_allow })

      expect(line.scan('"hookSpecificOutput"').size).to eq(1)
      expect(line.scan('"permissionDecision"').size).to eq(1)
      expect(line).not_to include('hook_specific_output', 'permission_decision')
    end

    it 'takes the later one when a Symbol and a String spell the same key' do
      nested = { hookEventName: 'PreToolUse', permissionDecision: 'allow', 'permissionDecision' => 'deny' }
      line = reply_line({ hookSpecificOutput: nested })

      expect(JSON.parse(line).dig('response', 'response')).to eq(denied)
      expect(line.scan('"permissionDecision"').size).to eq(1)
    end
  end

  describe 'the Ruby-safe spellings of keywords' do
    it 'still stand for continue and async, as a Symbol or a String' do
      outputs = [{ continue_: false }, { 'continue_' => false }, { async_: true }, { 'async_' => true }]

      expect(outputs.map { |output| reply(output) })
        .to eq([{ 'continue' => false }, { 'continue' => false }, { 'async' => true }, { 'async' => true }])
    end
  end

  describe 'the Hash a callback returned' do
    it 'is left untouched, so a frozen constant can be returned on every call' do
      output = {
        continue_: true,
        hook_specific_output: { hook_event_name: 'PreToolUse', permission_decision: 'deny' }.freeze
      }.freeze
      denied = { 'continue' => true,
                 'hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'deny' } }

      expect([reply(output), reply(output)]).to eq([denied, denied])
      expect(output).to eq(
        continue_: true, hook_specific_output: { hook_event_name: 'PreToolUse', permission_decision: 'deny' }
      )
    end
  end

  describe 'a return value that is not a Hash' do
    it 'still answers {} for nil, true and a String' do
      expect([nil, true, 'deny'].map { |output| reply(output) }).to eq([{}, {}, {}])
    end

    it 'is normalized like a Hash when it responds to #to_h' do
      output = Struct.new(:continue_, :hook_specific_output)
                     .new(false, { hook_event_name: 'PreToolUse', permission_decision: 'deny' })

      expect(reply(output)).to eq(
        'continue' => false,
        'hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'deny' }
      )
    end
  end
end
