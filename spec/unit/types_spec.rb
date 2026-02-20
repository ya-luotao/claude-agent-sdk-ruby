# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK do
  describe 'Type Classes' do
    describe ClaudeAgentSDK::TextBlock do
      it 'stores text content' do
        block = described_class.new(text: 'Hello, world!')
        expect(block.text).to eq('Hello, world!')
      end
    end

    describe ClaudeAgentSDK::ThinkingBlock do
      it 'stores thinking content and signature' do
        block = described_class.new(thinking: 'Let me think...', signature: 'sig123')
        expect(block.thinking).to eq('Let me think...')
        expect(block.signature).to eq('sig123')
      end
    end

    describe ClaudeAgentSDK::ToolUseBlock do
      it 'stores tool use information' do
        block = described_class.new(id: 'tool_123', name: 'Read', input: { file_path: '/test' })
        expect(block.id).to eq('tool_123')
        expect(block.name).to eq('Read')
        expect(block.input).to eq({ file_path: '/test' })
      end
    end

    describe ClaudeAgentSDK::ToolResultBlock do
      it 'stores tool result' do
        block = described_class.new(tool_use_id: 'tool_123', content: 'Result', is_error: false)
        expect(block.tool_use_id).to eq('tool_123')
        expect(block.content).to eq('Result')
        expect(block.is_error).to eq(false)
      end
    end

    describe ClaudeAgentSDK::UserMessage do
      it 'stores user content as string' do
        msg = described_class.new(content: 'Hello')
        expect(msg.content).to eq('Hello')
      end

      it 'stores user content as blocks' do
        blocks = [ClaudeAgentSDK::TextBlock.new(text: 'Hello')]
        msg = described_class.new(content: blocks)
        expect(msg.content).to eq(blocks)
      end

      it 'optionally stores parent_tool_use_id' do
        msg = described_class.new(content: 'Hello', parent_tool_use_id: 'tool_123')
        expect(msg.parent_tool_use_id).to eq('tool_123')
      end

      it 'optionally stores uuid for rewind support' do
        msg = described_class.new(content: 'Hello', uuid: 'user_msg_abc123')
        expect(msg.uuid).to eq('user_msg_abc123')
      end

      it 'has nil uuid by default' do
        msg = described_class.new(content: 'Hello')
        expect(msg.uuid).to be_nil
      end
    end

    describe ClaudeAgentSDK::AssistantMessage do
      it 'stores assistant content' do
        blocks = [ClaudeAgentSDK::TextBlock.new(text: 'Hello')]
        msg = described_class.new(content: blocks, model: 'claude-sonnet-4')
        expect(msg.content).to eq(blocks)
        expect(msg.model).to eq('claude-sonnet-4')
      end

      it 'stores error field' do
        blocks = [ClaudeAgentSDK::TextBlock.new(text: 'Error')]
        msg = described_class.new(content: blocks, model: 'claude-sonnet-4', error: 'rate_limit')
        expect(msg.error).to eq('rate_limit')
      end

      it 'accepts all valid error types' do
        blocks = [ClaudeAgentSDK::TextBlock.new(text: 'Error')]
        %w[authentication_failed billing_error rate_limit invalid_request server_error unknown].each do |error_type|
          msg = described_class.new(content: blocks, model: 'claude-sonnet-4', error: error_type)
          expect(msg.error).to eq(error_type)
        end
      end
    end

    describe ClaudeAgentSDK::SystemMessage do
      it 'stores system message data' do
        msg = described_class.new(subtype: 'info', data: { message: 'Test' })
        expect(msg.subtype).to eq('info')
        expect(msg.data).to eq({ message: 'Test' })
      end
    end

    describe ClaudeAgentSDK::ResultMessage do
      it 'stores result information' do
        msg = described_class.new(
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'session_123',
          total_cost_usd: 0.01,
          usage: { input_tokens: 100 }
        )

        expect(msg.subtype).to eq('success')
        expect(msg.duration_ms).to eq(1000)
        expect(msg.is_error).to eq(false)
        expect(msg.total_cost_usd).to eq(0.01)
      end

      it 'stores structured_output' do
        msg = described_class.new(
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'session_123',
          structured_output: { name: 'John', age: 30 }
        )

        expect(msg.structured_output).to eq({ name: 'John', age: 30 })
      end
    end

    describe ClaudeAgentSDK::PermissionUpdate do
      it 'converts to hash format' do
        rule = ClaudeAgentSDK::PermissionRuleValue.new(tool_name: 'Bash', rule_content: 'echo')
        update = described_class.new(
          type: 'addRules',
          rules: [rule],
          behavior: 'allow',
          destination: 'session'
        )

        hash = update.to_h
        expect(hash[:type]).to eq('addRules')
        expect(hash[:behavior]).to eq('allow')
        expect(hash[:rules].first[:toolName]).to eq('Bash')
      end
    end

    describe ClaudeAgentSDK::PermissionResultAllow do
      it 'has allow behavior' do
        result = described_class.new
        expect(result.behavior).to eq('allow')
      end

      it 'optionally stores updated input' do
        result = described_class.new(updated_input: { modified: true })
        expect(result.updated_input).to eq({ modified: true })
      end
    end

    describe ClaudeAgentSDK::PermissionResultDeny do
      it 'has deny behavior' do
        result = described_class.new(message: 'Not allowed')
        expect(result.behavior).to eq('deny')
        expect(result.message).to eq('Not allowed')
      end

      it 'can interrupt' do
        result = described_class.new(interrupt: true)
        expect(result.interrupt).to eq(true)
      end
    end

    describe ClaudeAgentSDK::ClaudeAgentOptions do
      it 'has default values' do
        options = described_class.new
        expect(options.allowed_tools).to eq([])
        expect(options.mcp_servers).to eq({})
        expect(options.continue_conversation).to eq(false)
        expect(options.output_format).to be_nil
        expect(options.max_budget_usd).to be_nil
        expect(options.max_thinking_tokens).to be_nil
        expect(options.fallback_model).to be_nil
        expect(options.plugins).to be_nil
        expect(options.debug_stderr).to be_nil
      end

      it 'accepts configuration' do
        options = described_class.new(
          allowed_tools: ['Read', 'Write'],
          permission_mode: 'acceptEdits',
          max_turns: 5
        )

        expect(options.allowed_tools).to eq(['Read', 'Write'])
        expect(options.permission_mode).to eq('acceptEdits')
        expect(options.max_turns).to eq(5)
      end

      it 'accepts new Python SDK options' do
        output_schema = {
          type: 'object',
          properties: {
            name: { type: 'string' },
            age: { type: 'integer' }
          }
        }
        plugin = ClaudeAgentSDK::SdkPluginConfig.new(path: '/plugin')

        options = described_class.new(
          output_format: output_schema,
          max_budget_usd: 10.0,
          max_thinking_tokens: 5000,
          fallback_model: 'claude-haiku-3',
          plugins: [plugin],
          debug_stderr: '/tmp/debug.log'
        )

        expect(options.output_format).to eq(output_schema)
        expect(options.max_budget_usd).to eq(10.0)
        expect(options.max_thinking_tokens).to eq(5000)
        expect(options.fallback_model).to eq('claude-haiku-3')
        expect(options.plugins).to eq([plugin])
        expect(options.debug_stderr).to eq('/tmp/debug.log')
      end

      it 'can duplicate with changes' do
        options = described_class.new(max_turns: 5)
        new_options = options.dup_with(max_turns: 10, model: 'claude-opus-4')

        expect(new_options.max_turns).to eq(10)
        expect(new_options.model).to eq('claude-opus-4')
      end
    end

    describe ClaudeAgentSDK::HookMatcher do
      it 'stores matcher and hooks' do
        hook_fn = ->(_input, _tool_id, _context) { {} }
        matcher = described_class.new(matcher: 'Bash', hooks: [hook_fn])

        expect(matcher.matcher).to eq('Bash')
        expect(matcher.hooks).to eq([hook_fn])
      end

      it 'stores timeout' do
        matcher = described_class.new(matcher: 'Bash', timeout: 30)
        expect(matcher.timeout).to eq(30)
      end
    end

    describe ClaudeAgentSDK::HookContext do
      it 'stores signal' do
        context = described_class.new(signal: :test_signal)
        expect(context.signal).to eq(:test_signal)
      end
    end

    describe ClaudeAgentSDK::PreToolUseHookInput do
      it 'stores hook input fields' do
        input = described_class.new(
          tool_name: 'Bash',
          tool_input: { command: 'ls' },
          session_id: 'sess_123',
          cwd: '/home/user'
        )

        expect(input.hook_event_name).to eq('PreToolUse')
        expect(input.tool_name).to eq('Bash')
        expect(input.tool_input).to eq({ command: 'ls' })
        expect(input.session_id).to eq('sess_123')
        expect(input.cwd).to eq('/home/user')
      end
    end

    describe ClaudeAgentSDK::PostToolUseHookInput do
      it 'stores hook input with tool response' do
        input = described_class.new(
          tool_name: 'Bash',
          tool_input: { command: 'ls' },
          tool_response: 'file1.txt\nfile2.txt'
        )

        expect(input.hook_event_name).to eq('PostToolUse')
        expect(input.tool_response).to eq('file1.txt\nfile2.txt')
      end
    end

    describe ClaudeAgentSDK::PostToolUseFailureHookInput do
      it 'stores hook input fields' do
        input = described_class.new(
          tool_name: 'Bash',
          tool_input: { command: 'rm -rf /' },
          tool_use_id: 'toolu_123',
          error: 'Command blocked',
          is_interrupt: true,
          session_id: 'sess_123'
        )

        expect(input.hook_event_name).to eq('PostToolUseFailure')
        expect(input.tool_name).to eq('Bash')
        expect(input.tool_input).to eq({ command: 'rm -rf /' })
        expect(input.tool_use_id).to eq('toolu_123')
        expect(input.error).to eq('Command blocked')
        expect(input.is_interrupt).to eq(true)
        expect(input.session_id).to eq('sess_123')
      end
    end

    describe ClaudeAgentSDK::NotificationHookInput do
      it 'stores notification fields' do
        input = described_class.new(
          message: 'Hello',
          title: 'Greeting',
          notification_type: 'info'
        )

        expect(input.hook_event_name).to eq('Notification')
        expect(input.message).to eq('Hello')
        expect(input.title).to eq('Greeting')
        expect(input.notification_type).to eq('info')
      end
    end

    describe ClaudeAgentSDK::SubagentStartHookInput do
      it 'stores subagent fields' do
        input = described_class.new(agent_id: 'agent_1', agent_type: 'coder')

        expect(input.hook_event_name).to eq('SubagentStart')
        expect(input.agent_id).to eq('agent_1')
        expect(input.agent_type).to eq('coder')
      end
    end

    describe ClaudeAgentSDK::PermissionRequestHookInput do
      it 'stores permission request fields' do
        input = described_class.new(
          tool_name: 'Bash',
          tool_input: { command: 'ls' },
          permission_suggestions: [{ type: 'setMode', mode: 'default' }]
        )

        expect(input.hook_event_name).to eq('PermissionRequest')
        expect(input.tool_name).to eq('Bash')
        expect(input.tool_input).to eq({ command: 'ls' })
        expect(input.permission_suggestions).to eq([{ type: 'setMode', mode: 'default' }])
      end
    end

    describe ClaudeAgentSDK::SubagentStopHookInput do
      it 'stores subagent stop fields' do
        input = described_class.new(
          stop_hook_active: true,
          agent_id: 'agent_1',
          agent_transcript_path: '/tmp/agent.jsonl',
          agent_type: 'coder'
        )

        expect(input.hook_event_name).to eq('SubagentStop')
        expect(input.stop_hook_active).to eq(true)
        expect(input.agent_id).to eq('agent_1')
        expect(input.agent_transcript_path).to eq('/tmp/agent.jsonl')
        expect(input.agent_type).to eq('coder')
      end
    end

    describe ClaudeAgentSDK::PreToolUseHookSpecificOutput do
      it 'converts to CLI format' do
        output = described_class.new(
          permission_decision: 'deny',
          permission_decision_reason: 'Command not allowed'
        )

        hash = output.to_h
        expect(hash[:hookEventName]).to eq('PreToolUse')
        expect(hash[:permissionDecision]).to eq('deny')
        expect(hash[:permissionDecisionReason]).to eq('Command not allowed')
      end
    end

    describe ClaudeAgentSDK::PostToolUseHookSpecificOutput do
      it 'converts to CLI format with updatedMCPToolOutput' do
        output = described_class.new(
          additional_context: 'ok',
          updated_mcp_tool_output: { content: [{ type: 'text', text: 'patched' }] }
        )

        hash = output.to_h
        expect(hash[:hookEventName]).to eq('PostToolUse')
        expect(hash[:additionalContext]).to eq('ok')
        expect(hash[:updatedMCPToolOutput]).to eq({ content: [{ type: 'text', text: 'patched' }] })
      end
    end

    describe ClaudeAgentSDK::PostToolUseFailureHookSpecificOutput do
      it 'converts to CLI format' do
        output = described_class.new(additional_context: 'failed')
        hash = output.to_h
        expect(hash[:hookEventName]).to eq('PostToolUseFailure')
        expect(hash[:additionalContext]).to eq('failed')
      end
    end

    describe ClaudeAgentSDK::NotificationHookSpecificOutput do
      it 'converts to CLI format' do
        output = described_class.new(additional_context: 'shown')
        hash = output.to_h
        expect(hash[:hookEventName]).to eq('Notification')
        expect(hash[:additionalContext]).to eq('shown')
      end
    end

    describe ClaudeAgentSDK::SubagentStartHookSpecificOutput do
      it 'converts to CLI format' do
        output = described_class.new(additional_context: 'started')
        hash = output.to_h
        expect(hash[:hookEventName]).to eq('SubagentStart')
        expect(hash[:additionalContext]).to eq('started')
      end
    end

    describe ClaudeAgentSDK::PermissionRequestHookSpecificOutput do
      it 'converts to CLI format' do
        output = described_class.new(decision: { behavior: 'deny', message: 'nope' })
        hash = output.to_h
        expect(hash[:hookEventName]).to eq('PermissionRequest')
        expect(hash[:decision]).to eq({ behavior: 'deny', message: 'nope' })
      end
    end

    describe ClaudeAgentSDK::SyncHookJSONOutput do
      it 'converts to CLI format' do
        specific = ClaudeAgentSDK::PreToolUseHookSpecificOutput.new(
          permission_decision: 'allow'
        )
        output = described_class.new(
          continue: true,
          suppress_output: false,
          hook_specific_output: specific
        )

        hash = output.to_h
        expect(hash[:continue]).to eq(true)
        expect(hash[:hookSpecificOutput][:hookEventName]).to eq('PreToolUse')
      end
    end

    describe ClaudeAgentSDK::SdkPluginConfig do
      it 'stores plugin path' do
        plugin = described_class.new(path: '/path/to/plugin')
        expect(plugin.type).to eq('plugin')
        expect(plugin.path).to eq('/path/to/plugin')
      end

      it 'converts to hash' do
        plugin = described_class.new(path: '/path/to/plugin')
        hash = plugin.to_h
        expect(hash[:type]).to eq('plugin')
        expect(hash[:path]).to eq('/path/to/plugin')
      end
    end

    describe ClaudeAgentSDK::SdkMcpTool do
      it 'stores tool definition' do
        handler = ->(_args) { { content: [] } }
        tool = described_class.new(
          name: 'test_tool',
          description: 'A test tool',
          input_schema: { param: :string },
          handler: handler
        )

        expect(tool.name).to eq('test_tool')
        expect(tool.description).to eq('A test tool')
        expect(tool.handler).to eq(handler)
      end
    end

    describe ClaudeAgentSDK::SandboxNetworkConfig do
      it 'stores network configuration' do
        config = described_class.new(
          allow_unix_sockets: ['/tmp/socket'],
          allow_local_binding: true,
          http_proxy_port: 8080
        )

        expect(config.allow_unix_sockets).to eq(['/tmp/socket'])
        expect(config.allow_local_binding).to eq(true)
        expect(config.http_proxy_port).to eq(8080)
      end

      it 'converts to hash with camelCase keys' do
        config = described_class.new(
          allow_local_binding: true,
          http_proxy_port: 8080
        )

        hash = config.to_h
        expect(hash[:allowLocalBinding]).to eq(true)
        expect(hash[:httpProxyPort]).to eq(8080)
      end

      it 'omits nil values in hash' do
        config = described_class.new(allow_local_binding: true)
        hash = config.to_h

        expect(hash.key?(:allowLocalBinding)).to eq(true)
        expect(hash.key?(:allowUnixSockets)).to eq(false)
      end
    end

    describe ClaudeAgentSDK::SandboxIgnoreViolations do
      it 'stores file and network patterns' do
        config = described_class.new(
          file: ['/tmp/*'],
          network: ['localhost:*']
        )

        expect(config.file).to eq(['/tmp/*'])
        expect(config.network).to eq(['localhost:*'])
      end

      it 'converts to hash' do
        config = described_class.new(file: ['/tmp/*'])
        hash = config.to_h

        expect(hash[:file]).to eq(['/tmp/*'])
        expect(hash.key?(:network)).to eq(false)
      end
    end

    describe ClaudeAgentSDK::SandboxSettings do
      it 'stores sandbox configuration' do
        sandbox = described_class.new(
          enabled: true,
          auto_allow_bash_if_sandboxed: true,
          excluded_commands: ['rm', 'sudo']
        )

        expect(sandbox.enabled).to eq(true)
        expect(sandbox.auto_allow_bash_if_sandboxed).to eq(true)
        expect(sandbox.excluded_commands).to eq(['rm', 'sudo'])
      end

      it 'converts to hash with nested configs' do
        network = ClaudeAgentSDK::SandboxNetworkConfig.new(allow_local_binding: true)
        sandbox = described_class.new(
          enabled: true,
          network: network
        )

        hash = sandbox.to_h
        expect(hash[:enabled]).to eq(true)
        expect(hash[:network][:allowLocalBinding]).to eq(true)
      end

      it 'handles all configuration options' do
        network = ClaudeAgentSDK::SandboxNetworkConfig.new(allow_local_binding: true)
        ignore = ClaudeAgentSDK::SandboxIgnoreViolations.new(file: ['/tmp/*'])

        sandbox = described_class.new(
          enabled: true,
          auto_allow_bash_if_sandboxed: true,
          excluded_commands: ['rm'],
          allow_unsandboxed_commands: false,
          network: network,
          ignore_violations: ignore,
          enable_weaker_nested_sandbox: false
        )

        hash = sandbox.to_h
        expect(hash[:enabled]).to eq(true)
        expect(hash[:autoAllowBashIfSandboxed]).to eq(true)
        expect(hash[:excludedCommands]).to eq(['rm'])
        expect(hash[:allowUnsandboxedCommands]).to eq(false)
        expect(hash[:network]).to be_a(Hash)
        expect(hash[:ignoreViolations]).to be_a(Hash)
        expect(hash[:enableWeakerNestedSandbox]).to eq(false)
      end
    end

    describe ClaudeAgentSDK::ToolsPreset do
      it 'stores preset name' do
        preset = described_class.new(preset: 'claude_code')
        expect(preset.type).to eq('preset')
        expect(preset.preset).to eq('claude_code')
      end

      it 'converts to hash' do
        preset = described_class.new(preset: 'claude_code')
        hash = preset.to_h

        expect(hash[:type]).to eq('preset')
        expect(hash[:preset]).to eq('claude_code')
      end
    end

    describe ClaudeAgentSDK::SystemPromptPreset do
      it 'stores preset and append' do
        preset = described_class.new(preset: 'default', append: 'Extra instructions')
        expect(preset.type).to eq('preset')
        expect(preset.preset).to eq('default')
        expect(preset.append).to eq('Extra instructions')
      end

      it 'converts to hash' do
        preset = described_class.new(preset: 'default', append: 'Extra')
        hash = preset.to_h

        expect(hash[:type]).to eq('preset')
        expect(hash[:preset]).to eq('default')
        expect(hash[:append]).to eq('Extra')
      end

      it 'omits append if nil' do
        preset = described_class.new(preset: 'default')
        hash = preset.to_h

        expect(hash.key?(:append)).to eq(false)
      end
    end

    describe 'ClaudeAgentOptions new options' do
      it 'accepts betas option' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          betas: ['context-1m-2025-08-07']
        )
        expect(options.betas).to eq(['context-1m-2025-08-07'])
      end

      it 'accepts tools option as array' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          tools: ['Read', 'Edit', 'Bash']
        )
        expect(options.tools).to eq(['Read', 'Edit', 'Bash'])
      end

      it 'accepts tools option as ToolsPreset' do
        preset = ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code')
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: preset)
        expect(options.tools).to eq(preset)
      end

      it 'accepts sandbox option' do
        sandbox = ClaudeAgentSDK::SandboxSettings.new(enabled: true)
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(sandbox: sandbox)
        expect(options.sandbox).to eq(sandbox)
      end

      it 'accepts enable_file_checkpointing option' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          enable_file_checkpointing: true
        )
        expect(options.enable_file_checkpointing).to eq(true)
      end

      it 'defaults enable_file_checkpointing to false' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new
        expect(options.enable_file_checkpointing).to eq(false)
      end

      it 'accepts append_allowed_tools option' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          append_allowed_tools: ['Write', 'Bash']
        )
        expect(options.append_allowed_tools).to eq(['Write', 'Bash'])
      end

      it 'accepts thinking option with ThinkingConfigAdaptive' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new
        )
        expect(options.thinking).to be_a(ClaudeAgentSDK::ThinkingConfigAdaptive)
      end

      it 'accepts thinking option with ThinkingConfigEnabled' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          thinking: ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 50_000)
        )
        expect(options.thinking).to be_a(ClaudeAgentSDK::ThinkingConfigEnabled)
        expect(options.thinking.budget_tokens).to eq(50_000)
      end

      it 'accepts thinking option with ThinkingConfigDisabled' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          thinking: ClaudeAgentSDK::ThinkingConfigDisabled.new
        )
        expect(options.thinking).to be_a(ClaudeAgentSDK::ThinkingConfigDisabled)
      end

      it 'accepts effort option' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(effort: 'high')
        expect(options.effort).to eq('high')
      end
    end

    describe ClaudeAgentSDK::ThinkingConfigAdaptive do
      it 'has adaptive type' do
        config = described_class.new
        expect(config.type).to eq('adaptive')
      end
    end

    describe ClaudeAgentSDK::ThinkingConfigEnabled do
      it 'stores budget_tokens' do
        config = described_class.new(budget_tokens: 16_000)
        expect(config.type).to eq('enabled')
        expect(config.budget_tokens).to eq(16_000)
      end
    end

    describe ClaudeAgentSDK::ThinkingConfigDisabled do
      it 'has disabled type' do
        config = described_class.new
        expect(config.type).to eq('disabled')
      end
    end

    describe ClaudeAgentSDK::PreToolUseHookInput do
      it 'stores tool_use_id' do
        input = described_class.new(
          tool_name: 'Bash',
          tool_input: { command: 'ls' },
          tool_use_id: 'toolu_abc123'
        )
        expect(input.tool_use_id).to eq('toolu_abc123')
      end

      it 'defaults tool_use_id to nil' do
        input = described_class.new(tool_name: 'Bash')
        expect(input.tool_use_id).to be_nil
      end
    end

    describe ClaudeAgentSDK::PostToolUseHookInput do
      it 'stores tool_use_id' do
        input = described_class.new(
          tool_name: 'Bash',
          tool_input: { command: 'ls' },
          tool_use_id: 'toolu_def456'
        )
        expect(input.tool_use_id).to eq('toolu_def456')
      end
    end

    describe ClaudeAgentSDK::PreToolUseHookSpecificOutput do
      it 'includes additionalContext in to_h' do
        output = described_class.new(
          permission_decision: 'allow',
          additional_context: 'Approved by admin'
        )
        hash = output.to_h
        expect(hash[:additionalContext]).to eq('Approved by admin')
        expect(hash[:permissionDecision]).to eq('allow')
      end

      it 'omits additionalContext when nil' do
        output = described_class.new(permission_decision: 'allow')
        hash = output.to_h
        expect(hash.key?(:additionalContext)).to eq(false)
      end
    end

    describe ClaudeAgentSDK::UserMessage do
      it 'stores tool_use_result' do
        msg = described_class.new(
          content: 'result',
          tool_use_result: { output: 'success' }
        )
        expect(msg.tool_use_result).to eq({ output: 'success' })
      end

      it 'defaults tool_use_result to nil' do
        msg = described_class.new(content: 'Hello')
        expect(msg.tool_use_result).to be_nil
      end
    end

    describe ClaudeAgentSDK::SdkMcpTool do
      it 'stores annotations' do
        handler = ->(_args) { { content: [] } }
        tool = described_class.new(
          name: 'test',
          description: 'A test tool',
          input_schema: {},
          handler: handler,
          annotations: { title: 'Test Tool', readOnlyHint: true }
        )
        expect(tool.annotations).to eq({ title: 'Test Tool', readOnlyHint: true })
      end

      it 'defaults annotations to nil' do
        handler = ->(_args) { { content: [] } }
        tool = described_class.new(
          name: 'test',
          description: 'A test tool',
          input_schema: {},
          handler: handler
        )
        expect(tool.annotations).to be_nil
      end
    end
  end
end
