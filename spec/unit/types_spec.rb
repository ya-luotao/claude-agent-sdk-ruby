# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK do
  describe 'Module constants' do
    it 'exposes EFFORT_LEVELS' do
      expect(ClaudeAgentSDK::EFFORT_LEVELS).to eq(%w[low medium high xhigh max])
      expect(ClaudeAgentSDK::EFFORT_LEVELS).to be_frozen
    end
  end

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

      it 'stores usage field' do
        blocks = [ClaudeAgentSDK::TextBlock.new(text: 'Hello')]
        usage = { input_tokens: 100, output_tokens: 50 }
        msg = described_class.new(content: blocks, model: 'claude-sonnet-4', usage: usage)
        expect(msg.usage).to eq(usage)
      end

      it 'defaults usage to nil' do
        blocks = [ClaudeAgentSDK::TextBlock.new(text: 'Hello')]
        msg = described_class.new(content: blocks, model: 'claude-sonnet-4')
        expect(msg.usage).to be_nil
      end
    end

    describe '#text uniform contract' do
      let(:text_block) { ClaudeAgentSDK::TextBlock.new(text: 'Hi') }
      let(:tool_use_block) { ClaudeAgentSDK::ToolUseBlock.new(id: 't1', name: 'Read', input: {}) }
      let(:thinking_block) { ClaudeAgentSDK::ThinkingBlock.new(thinking: 'hmm', signature: 'sig') }
      let(:tool_result_block) { ClaudeAgentSDK::ToolResultBlock.new(tool_use_id: 't1', content: 'ok') }
      let(:unknown_block) { ClaudeAgentSDK::UnknownBlock.new(type: 'image', data: {}) }

      describe 'content blocks' do
        it 'TextBlock#text returns the text' do
          expect(text_block.text).to eq('Hi')
        end

        it 'non-text blocks do not respond to #text' do
          expect(tool_use_block).not_to respond_to(:text)
          expect(thinking_block).not_to respond_to(:text)
          expect(tool_result_block).not_to respond_to(:text)
          expect(unknown_block).not_to respond_to(:text)
        end
      end

      describe 'AssistantMessage#text' do
        it 'concatenates text across typed blocks, skipping non-text' do
          msg = ClaudeAgentSDK::AssistantMessage.new(
            content: [
              ClaudeAgentSDK::TextBlock.new(text: 'First'),
              tool_use_block,
              ClaudeAgentSDK::TextBlock.new(text: 'Second')
            ],
            model: 'claude-sonnet-4'
          )
          expect(msg.text).to eq("First\n\nSecond")
        end

        it 'returns "" when no text blocks are present' do
          msg = ClaudeAgentSDK::AssistantMessage.new(content: [tool_use_block], model: 'claude-sonnet-4')
          expect(msg.text).to eq('')
        end

        it 'aliases #to_s to #text' do
          msg = ClaudeAgentSDK::AssistantMessage.new(content: [text_block], model: 'claude-sonnet-4')
          expect(msg.to_s).to eq('Hi')
          expect("got: #{msg}").to eq('got: Hi')
        end
      end

      describe 'UserMessage#text' do
        it 'returns the raw string when content is a String' do
          expect(ClaudeAgentSDK::UserMessage.new(content: 'Hello').text).to eq('Hello')
        end

        it 'concatenates text across typed blocks' do
          msg = ClaudeAgentSDK::UserMessage.new(
            content: [
              ClaudeAgentSDK::TextBlock.new(text: 'A'),
              tool_use_block,
              ClaudeAgentSDK::TextBlock.new(text: 'B')
            ]
          )
          expect(msg.text).to eq("A\n\nB")
        end

        it 'returns "" when content is nil' do
          expect(ClaudeAgentSDK::UserMessage.new(content: nil).text).to eq('')
        end

        it 'aliases #to_s to #text' do
          msg = ClaudeAgentSDK::UserMessage.new(content: 'Hello')
          expect(msg.to_s).to eq('Hello')
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

    describe ClaudeAgentSDK::InitMessage do
      it 'is a SystemMessage subclass with all fields defaulting to nil' do
        msg = described_class.new(subtype: 'init', data: {})
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.subtype).to eq('init')
        expect(msg.session_id).to be_nil
        expect(msg.uuid).to be_nil
        expect(msg.tools).to be_nil
        expect(msg.model).to be_nil
      end

      it 'stores all session initialization fields' do
        msg = described_class.new(
          subtype: 'init', data: {}, uuid: 'u1', session_id: 'sess',
          agents: ['reviewer'], api_key_source: 'env', betas: ['beta1'],
          claude_code_version: '1.0', cwd: '/tmp', tools: ['Read'],
          mcp_servers: [], model: 'opus', permission_mode: 'default',
          slash_commands: ['/clear'], output_style: 'concise',
          skills: ['commit'], plugins: []
        )
        expect(msg.uuid).to eq('u1')
        expect(msg.agents).to eq(['reviewer'])
        expect(msg.api_key_source).to eq('env')
        expect(msg.claude_code_version).to eq('1.0')
        expect(msg.tools).to eq(['Read'])
        expect(msg.model).to eq('opus')
        expect(msg.permission_mode).to eq('default')
        expect(msg.output_style).to eq('concise')
        expect(msg.skills).to eq(['commit'])
      end
    end

    describe ClaudeAgentSDK::CompactBoundaryMessage do
      it 'is a SystemMessage subclass' do
        msg = described_class.new(subtype: 'compact_boundary', data: {})
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.subtype).to eq('compact_boundary')
        expect(msg.compact_metadata).to be_nil
      end

      it 'stores compact metadata' do
        metadata = ClaudeAgentSDK::CompactMetadata.new(pre_tokens: 95_000, post_tokens: 12_000, trigger: 'auto')
        msg = described_class.new(subtype: 'compact_boundary', data: {}, compact_metadata: metadata)
        expect(msg.compact_metadata.pre_tokens).to eq(95_000)
        expect(msg.compact_metadata.post_tokens).to eq(12_000)
        expect(msg.compact_metadata.trigger).to eq('auto')
      end
    end

    describe ClaudeAgentSDK::CompactMetadata do
      it 'stores all fields' do
        meta = described_class.new(
          pre_tokens: 95_000, post_tokens: 12_000,
          trigger: 'manual', custom_instructions: 'Focus on code'
        )
        expect(meta.pre_tokens).to eq(95_000)
        expect(meta.post_tokens).to eq(12_000)
        expect(meta.trigger).to eq('manual')
        expect(meta.custom_instructions).to eq('Focus on code')
      end

      it 'creates from hash with symbol keys' do
        meta = described_class.from_hash({ pre_tokens: 100, post_tokens: 50, trigger: 'auto' })
        expect(meta.pre_tokens).to eq(100)
        expect(meta.post_tokens).to eq(50)
        expect(meta.trigger).to eq('auto')
      end

      it 'creates from hash with string keys' do
        meta = described_class.from_hash({ 'pre_tokens' => 100, 'post_tokens' => 50, 'trigger' => 'manual' })
        expect(meta.pre_tokens).to eq(100)
        expect(meta.trigger).to eq('manual')
      end

      it 'creates from hash with camelCase keys' do
        meta = described_class.from_hash({ preTokens: 100, postTokens: 50, customInstructions: 'Keep it brief' })
        expect(meta.pre_tokens).to eq(100)
        expect(meta.post_tokens).to eq(50)
        expect(meta.custom_instructions).to eq('Keep it brief')
      end

      it 'returns nil for non-hash input' do
        expect(described_class.from_hash(nil)).to be_nil
        expect(described_class.from_hash('not a hash')).to be_nil
      end
    end

    describe ClaudeAgentSDK::TaskUsage do
      it 'stores usage fields with defaults' do
        usage = described_class.new
        expect(usage.total_tokens).to eq(0)
        expect(usage.tool_uses).to eq(0)
        expect(usage.duration_ms).to eq(0)
      end

      it 'stores custom usage values' do
        usage = described_class.new(total_tokens: 1000, tool_uses: 5, duration_ms: 3000)
        expect(usage.total_tokens).to eq(1000)
        expect(usage.tool_uses).to eq(5)
        expect(usage.duration_ms).to eq(3000)
      end

      it 'creates from hash with symbol keys' do
        usage = described_class.from_hash({ total_tokens: 500, tool_uses: 3, duration_ms: 2000 })
        expect(usage.total_tokens).to eq(500)
        expect(usage.tool_uses).to eq(3)
        expect(usage.duration_ms).to eq(2000)
      end

      it 'creates from hash with string keys' do
        usage = described_class.from_hash({ 'total_tokens' => 500, 'tool_uses' => 3, 'duration_ms' => 2000 })
        expect(usage.total_tokens).to eq(500)
        expect(usage.tool_uses).to eq(3)
        expect(usage.duration_ms).to eq(2000)
      end

      it 'creates from hash with camelCase keys' do
        usage = described_class.from_hash({ totalTokens: 500, toolUses: 3, durationMs: 2000 })
        expect(usage.total_tokens).to eq(500)
        expect(usage.tool_uses).to eq(3)
        expect(usage.duration_ms).to eq(2000)
      end

      it 'returns nil for non-hash input' do
        expect(described_class.from_hash(nil)).to be_nil
        expect(described_class.from_hash('not a hash')).to be_nil
      end
    end

    describe ClaudeAgentSDK::AgentDefinition do
      it 'stores basic fields' do
        agent = described_class.new(description: 'A coding agent', prompt: 'You write code')
        expect(agent.description).to eq('A coding agent')
        expect(agent.prompt).to eq('You write code')
        expect(agent.tools).to be_nil
        expect(agent.model).to be_nil
      end

      it 'stores skills, memory, mcp_servers' do
        agent = described_class.new(
          description: 'Agent',
          prompt: 'Do stuff',
          skills: %w[code review],
          memory: 'project',
          mcp_servers: ['server1', { name: 'server2', url: 'http://example.com' }]
        )
        expect(agent.skills).to eq(%w[code review])
        expect(agent.memory).to eq('project')
        expect(agent.mcp_servers).to eq(['server1', { name: 'server2', url: 'http://example.com' }])
      end

      it 'defaults new fields to nil' do
        agent = described_class.new(description: 'Agent', prompt: 'Do stuff')
        expect(agent.skills).to be_nil
        expect(agent.memory).to be_nil
        expect(agent.mcp_servers).to be_nil
      end
    end

    describe ClaudeAgentSDK::TaskStartedMessage do
      it 'is a SystemMessage subclass' do
        msg = described_class.new(
          subtype: 'task_started',
          data: {},
          task_id: 'task_1',
          description: 'Working on feature',
          uuid: 'uuid_123',
          session_id: 'sess_1'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.task_id).to eq('task_1')
        expect(msg.description).to eq('Working on feature')
        expect(msg.uuid).to eq('uuid_123')
        expect(msg.session_id).to eq('sess_1')
      end

      it 'stores optional fields' do
        msg = described_class.new(
          subtype: 'task_started',
          data: {},
          task_id: 'task_1',
          description: 'test',
          uuid: 'uuid_1',
          session_id: 'sess_1',
          tool_use_id: 'toolu_1',
          task_type: 'background'
        )
        expect(msg.tool_use_id).to eq('toolu_1')
        expect(msg.task_type).to eq('background')
      end
    end

    describe ClaudeAgentSDK::TaskProgressMessage do
      it 'is a SystemMessage subclass' do
        msg = described_class.new(
          subtype: 'task_progress',
          data: {},
          task_id: 'task_1',
          description: 'In progress',
          usage: { total_tokens: 500, tool_uses: 3, duration_ms: 2000 },
          uuid: 'uuid_123',
          session_id: 'sess_1'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.task_id).to eq('task_1')
        expect(msg.description).to eq('In progress')
        expect(msg.usage).to eq({ total_tokens: 500, tool_uses: 3, duration_ms: 2000 })
        expect(msg.uuid).to eq('uuid_123')
        expect(msg.session_id).to eq('sess_1')
      end

      it 'stores optional fields' do
        msg = described_class.new(
          subtype: 'task_progress',
          data: {},
          task_id: 'task_1',
          description: 'test',
          usage: {},
          uuid: 'uuid_1',
          session_id: 'sess_1',
          tool_use_id: 'toolu_1',
          last_tool_name: 'Bash'
        )
        expect(msg.tool_use_id).to eq('toolu_1')
        expect(msg.last_tool_name).to eq('Bash')
      end
    end

    describe ClaudeAgentSDK::TaskNotificationMessage do
      it 'is a SystemMessage subclass' do
        msg = described_class.new(
          subtype: 'task_notification',
          data: {},
          task_id: 'task_1',
          status: 'completed',
          output_file: '/tmp/output.txt',
          summary: 'Task finished',
          uuid: 'uuid_123',
          session_id: 'sess_1'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.task_id).to eq('task_1')
        expect(msg.status).to eq('completed')
        expect(msg.output_file).to eq('/tmp/output.txt')
        expect(msg.summary).to eq('Task finished')
      end

      it 'stores optional fields' do
        msg = described_class.new(
          subtype: 'task_notification',
          data: {},
          task_id: 'task_1',
          status: 'failed',
          output_file: '/tmp/out.txt',
          summary: 'failed',
          uuid: 'uuid_1',
          session_id: 'sess_1',
          tool_use_id: 'toolu_1',
          usage: { total_tokens: 100, tool_uses: 1, duration_ms: 500 }
        )
        expect(msg.tool_use_id).to eq('toolu_1')
        expect(msg.usage).to eq({ total_tokens: 100, tool_uses: 1, duration_ms: 500 })
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

      it 'stores stop_reason' do
        msg = described_class.new(
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'session_123',
          stop_reason: 'end_turn'
        )

        expect(msg.stop_reason).to eq('end_turn')
      end

      it 'defaults stop_reason to nil' do
        msg = described_class.new(
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'session_123'
        )

        expect(msg.stop_reason).to be_nil
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

    describe ClaudeAgentSDK::RateLimitInfo do
      it 'stores all fields' do
        info = described_class.new(
          status: 'allowed_warning',
          resets_at: 1_700_000_000,
          rate_limit_type: 'five_hour',
          utilization: 0.85,
          overage_status: 'allowed',
          overage_resets_at: 1_700_100_000,
          overage_disabled_reason: nil,
          raw: { status: 'allowed_warning' }
        )

        expect(info.status).to eq('allowed_warning')
        expect(info.resets_at).to eq(1_700_000_000)
        expect(info.rate_limit_type).to eq('five_hour')
        expect(info.utilization).to eq(0.85)
        expect(info.overage_status).to eq('allowed')
        expect(info.overage_resets_at).to eq(1_700_100_000)
        expect(info.overage_disabled_reason).to be_nil
        expect(info.raw).to eq({ status: 'allowed_warning' })
      end

      it 'defaults optional fields to nil' do
        info = described_class.new(status: 'allowed')

        expect(info.status).to eq('allowed')
        expect(info.resets_at).to be_nil
        expect(info.rate_limit_type).to be_nil
        expect(info.utilization).to be_nil
        expect(info.overage_status).to be_nil
        expect(info.overage_resets_at).to be_nil
        expect(info.overage_disabled_reason).to be_nil
        expect(info.raw).to eq({})
      end
    end

    describe ClaudeAgentSDK::RateLimitEvent do
      it 'stores rate_limit_info, uuid, and session_id' do
        info = ClaudeAgentSDK::RateLimitInfo.new(status: 'rejected', raw: { status: 'rejected' })
        event = described_class.new(
          rate_limit_info: info,
          uuid: 'evt_123',
          session_id: 'sess_456'
        )

        expect(event.rate_limit_info).to eq(info)
        expect(event.rate_limit_info.status).to eq('rejected')
        expect(event.uuid).to eq('evt_123')
        expect(event.session_id).to eq('sess_456')
      end

      it 'provides backward-compatible data accessor returning full raw payload' do
        raw_payload = {
          type: 'rate_limit_event', uuid: 'u', session_id: 's',
          rate_limit_info: { status: 'allowed', resetsAt: 1_700_000_000 }
        }
        info = ClaudeAgentSDK::RateLimitInfo.new(status: 'allowed')
        event = described_class.new(rate_limit_info: info, uuid: 'u', session_id: 's', raw_data: raw_payload)

        expect(event.data).to eq(raw_payload)
        expect(event.data[:uuid]).to eq('u')
        expect(event.data[:session_id]).to eq('s')
        expect(event.data[:rate_limit_info][:status]).to eq('allowed')
      end

      it 'returns empty hash from data when no raw_data provided' do
        info = ClaudeAgentSDK::RateLimitInfo.new(status: 'allowed')
        event = described_class.new(rate_limit_info: info, uuid: 'u', session_id: 's')
        expect(event.data).to eq({})
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

      it 'stores agent_id and agent_type for subagent context' do
        input = described_class.new(
          tool_name: 'Bash',
          tool_input: { command: 'ls' },
          agent_id: 'agent_abc',
          agent_type: 'coder'
        )
        expect(input.agent_id).to eq('agent_abc')
        expect(input.agent_type).to eq('coder')
      end

      it 'defaults agent_id and agent_type to nil' do
        input = described_class.new(tool_name: 'Bash')
        expect(input.agent_id).to be_nil
        expect(input.agent_type).to be_nil
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

      it 'stores agent_id and agent_type for subagent context' do
        input = described_class.new(
          tool_name: 'Bash',
          agent_id: 'agent_1',
          agent_type: 'researcher'
        )
        expect(input.agent_id).to eq('agent_1')
        expect(input.agent_type).to eq('researcher')
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

      it 'stores agent_id and agent_type for subagent context' do
        input = described_class.new(
          tool_name: 'Bash',
          agent_id: 'agent_2',
          agent_type: 'tester'
        )
        expect(input.agent_id).to eq('agent_2')
        expect(input.agent_type).to eq('tester')
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

      it 'stores agent_id and agent_type for subagent context' do
        input = described_class.new(
          tool_name: 'Bash',
          agent_id: 'agent_3',
          agent_type: 'planner'
        )
        expect(input.agent_id).to eq('agent_3')
        expect(input.agent_type).to eq('planner')
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

    describe ClaudeAgentSDK::SessionStartHookInput do
      it 'stores session start fields' do
        input = described_class.new(source: 'startup', agent_type: 'main', model: 'opus')
        expect(input.hook_event_name).to eq('SessionStart')
        expect(input.source).to eq('startup')
        expect(input.agent_type).to eq('main')
        expect(input.model).to eq('opus')
      end
    end

    describe ClaudeAgentSDK::SessionEndHookInput do
      it 'stores session end fields' do
        input = described_class.new(reason: 'user_exit')
        expect(input.hook_event_name).to eq('SessionEnd')
        expect(input.reason).to eq('user_exit')
      end
    end

    describe ClaudeAgentSDK::SetupHookInput do
      it 'stores setup fields' do
        input = described_class.new(trigger: 'init')
        expect(input.hook_event_name).to eq('Setup')
        expect(input.trigger).to eq('init')
      end
    end

    describe ClaudeAgentSDK::TeammateIdleHookInput do
      it 'stores teammate idle fields' do
        input = described_class.new(teammate_name: 'reviewer', team_name: 'dev')
        expect(input.hook_event_name).to eq('TeammateIdle')
        expect(input.teammate_name).to eq('reviewer')
        expect(input.team_name).to eq('dev')
      end
    end

    describe ClaudeAgentSDK::TaskCompletedHookInput do
      it 'stores task completed fields' do
        input = described_class.new(
          task_id: 't1', task_subject: 'Review PR',
          task_description: 'Check for bugs', teammate_name: 'reviewer', team_name: 'dev'
        )
        expect(input.hook_event_name).to eq('TaskCompleted')
        expect(input.task_id).to eq('t1')
        expect(input.task_subject).to eq('Review PR')
        expect(input.task_description).to eq('Check for bugs')
        expect(input.teammate_name).to eq('reviewer')
      end
    end

    describe ClaudeAgentSDK::ConfigChangeHookInput do
      it 'stores config change fields' do
        input = described_class.new(source: 'project_settings', file_path: '.claude/settings.json')
        expect(input.hook_event_name).to eq('ConfigChange')
        expect(input.source).to eq('project_settings')
        expect(input.file_path).to eq('.claude/settings.json')
      end
    end

    describe ClaudeAgentSDK::WorktreeCreateHookInput do
      it 'stores worktree create fields' do
        input = described_class.new(name: 'feature-branch')
        expect(input.hook_event_name).to eq('WorktreeCreate')
        expect(input.name).to eq('feature-branch')
      end
    end

    describe ClaudeAgentSDK::WorktreeRemoveHookInput do
      it 'stores worktree remove fields' do
        input = described_class.new(worktree_path: '/tmp/worktree-123')
        expect(input.hook_event_name).to eq('WorktreeRemove')
        expect(input.worktree_path).to eq('/tmp/worktree-123')
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
        expect(plugin.type).to eq('local')
        expect(plugin.path).to eq('/path/to/plugin')
      end

      it 'converts to hash' do
        plugin = described_class.new(path: '/path/to/plugin')
        hash = plugin.to_h
        expect(hash[:type]).to eq('local')
        expect(hash[:path]).to eq('/path/to/plugin')
      end

      it 'normalizes the legacy plugin type to local' do
        plugin = described_class.new(path: '/path/to/plugin', type: 'plugin')

        expect(plugin.type).to eq('local')
      end
    end

    describe ClaudeAgentSDK::McpServerInfo do
      it 'stores server name and version' do
        info = described_class.new(name: 'my-server', version: '1.0.0')
        expect(info.name).to eq('my-server')
        expect(info.version).to eq('1.0.0')
      end
    end

    describe ClaudeAgentSDK::McpToolAnnotations do
      it 'stores annotation hints' do
        annotations = described_class.new(read_only: true, destructive: false, open_world: true)
        expect(annotations.read_only).to eq(true)
        expect(annotations.destructive).to eq(false)
        expect(annotations.open_world).to eq(true)
      end

      it 'parses false values correctly from camelCase keys' do
        data = { readOnly: false, destructive: false, openWorld: false }
        annotations = described_class.parse(data)
        expect(annotations.read_only).to eq(false)
        expect(annotations.destructive).to eq(false)
        expect(annotations.open_world).to eq(false)
      end

      it 'falls back to snake_case keys when camelCase is absent' do
        data = { read_only: true, open_world: false }
        annotations = described_class.parse(data)
        expect(annotations.read_only).to eq(true)
        expect(annotations.open_world).to eq(false)
      end
    end

    describe ClaudeAgentSDK::McpToolInfo do
      it 'stores tool name and description' do
        tool = described_class.new(name: 'read_file', description: 'Read a file')
        expect(tool.name).to eq('read_file')
        expect(tool.description).to eq('Read a file')
      end

      it 'stores annotations' do
        annotations = ClaudeAgentSDK::McpToolAnnotations.new(read_only: true)
        tool = described_class.new(name: 'read_file', annotations: annotations)
        expect(tool.annotations.read_only).to eq(true)
      end
    end

    describe ClaudeAgentSDK::McpSdkServerConfigStatus do
      it 'stores type and name' do
        config = described_class.new(name: 'my-sdk-server')
        expect(config.type).to eq('sdk')
        expect(config.name).to eq('my-sdk-server')
      end

      it 'converts to hash' do
        config = described_class.new(name: 'my-sdk-server')
        hash = config.to_h
        expect(hash).to eq({ type: 'sdk', name: 'my-sdk-server' })
      end
    end

    describe ClaudeAgentSDK::McpClaudeAIProxyServerConfig do
      it 'stores type, url, and id' do
        config = described_class.new(url: 'https://proxy.example.com', id: 'proxy-123')
        expect(config.type).to eq('claudeai-proxy')
        expect(config.url).to eq('https://proxy.example.com')
        expect(config.id).to eq('proxy-123')
      end

      it 'converts to hash' do
        config = described_class.new(url: 'https://proxy.example.com', id: 'proxy-123')
        hash = config.to_h
        expect(hash).to eq({ type: 'claudeai-proxy', url: 'https://proxy.example.com', id: 'proxy-123' })
      end
    end

    describe ClaudeAgentSDK::McpServerStatus do
      it 'stores all fields' do
        info = ClaudeAgentSDK::McpServerInfo.new(name: 'srv', version: '1.0')
        status = described_class.new(
          name: 'my-server',
          status: 'connected',
          server_info: info,
          error: nil,
          scope: 'project',
          tools: []
        )
        expect(status.name).to eq('my-server')
        expect(status.status).to eq('connected')
        expect(status.server_info.name).to eq('srv')
        expect(status.scope).to eq('project')
      end

      it 'parses from raw hash with camelCase keys' do
        raw = {
          name: 'test-server',
          status: 'connected',
          serverInfo: { name: 'test', version: '2.0' },
          tools: [
            { name: 'tool1', description: 'desc1', annotations: { readOnly: true } }
          ],
          scope: 'user'
        }
        status = described_class.parse(raw)
        expect(status.name).to eq('test-server')
        expect(status.status).to eq('connected')
        expect(status.server_info).to be_a(ClaudeAgentSDK::McpServerInfo)
        expect(status.server_info.version).to eq('2.0')
        expect(status.tools.length).to eq(1)
        expect(status.tools.first).to be_a(ClaudeAgentSDK::McpToolInfo)
        expect(status.tools.first.annotations.read_only).to eq(true)
      end

      it 'parses claudeai-proxy config into McpClaudeAIProxyServerConfig' do
        raw = {
          name: 'proxy-server',
          status: 'connected',
          config: { type: 'claudeai-proxy', url: 'https://proxy.example.com', id: 'proxy-1' }
        }
        status = described_class.parse(raw)
        expect(status.config).to be_a(ClaudeAgentSDK::McpClaudeAIProxyServerConfig)
        expect(status.config.type).to eq('claudeai-proxy')
        expect(status.config.url).to eq('https://proxy.example.com')
        expect(status.config.id).to eq('proxy-1')
      end

      it 'parses sdk config into McpSdkServerConfigStatus' do
        raw = {
          name: 'sdk-server',
          status: 'connected',
          config: { type: 'sdk', name: 'my-sdk' }
        }
        status = described_class.parse(raw)
        expect(status.config).to be_a(ClaudeAgentSDK::McpSdkServerConfigStatus)
        expect(status.config.type).to eq('sdk')
        expect(status.config.name).to eq('my-sdk')
      end

      it 'passes through unknown config types as raw hash' do
        raw = {
          name: 'stdio-server',
          status: 'connected',
          config: { type: 'stdio', command: 'node', args: ['server.js'] }
        }
        status = described_class.parse(raw)
        expect(status.config).to be_a(Hash)
        expect(status.config[:type]).to eq('stdio')
      end
    end

    describe ClaudeAgentSDK::McpStatusResponse do
      it 'parses from raw hash' do
        raw = {
          mcpServers: [
            { name: 'server1', status: 'connected' },
            { name: 'server2', status: 'failed', error: 'timeout' }
          ]
        }
        response = described_class.parse(raw)
        expect(response.mcp_servers.length).to eq(2)
        expect(response.mcp_servers[0]).to be_a(ClaudeAgentSDK::McpServerStatus)
        expect(response.mcp_servers[0].name).to eq('server1')
        expect(response.mcp_servers[1].status).to eq('failed')
        expect(response.mcp_servers[1].error).to eq('timeout')
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
          allowed_domains: ['example.com'],
          allow_unix_sockets: ['/tmp/socket'],
          allow_local_binding: true,
          http_proxy_port: 8080
        )

        expect(config.allowed_domains).to eq(['example.com'])
        expect(config.allow_unix_sockets).to eq(['/tmp/socket'])
        expect(config.allow_local_binding).to eq(true)
        expect(config.http_proxy_port).to eq(8080)
      end

      it 'converts to hash with camelCase keys' do
        config = described_class.new(
          allowed_domains: ['api.example.com'],
          allow_managed_domains_only: true,
          allow_local_binding: true,
          http_proxy_port: 8080
        )

        hash = config.to_h
        expect(hash[:allowedDomains]).to eq(['api.example.com'])
        expect(hash[:allowManagedDomainsOnly]).to eq(true)
        expect(hash[:allowLocalBinding]).to eq(true)
        expect(hash[:httpProxyPort]).to eq(8080)
      end

      it 'omits nil values in hash' do
        config = described_class.new(allow_local_binding: true)
        hash = config.to_h

        expect(hash.key?(:allowLocalBinding)).to eq(true)
        expect(hash.key?(:allowUnixSockets)).to eq(false)
        expect(hash.key?(:allowedDomains)).to eq(false)
      end
    end

    describe ClaudeAgentSDK::SandboxFilesystemConfig do
      it 'stores filesystem configuration' do
        config = described_class.new(
          allow_write: ['/tmp'],
          deny_write: ['/etc'],
          deny_read: ['/secrets'],
          allow_read: ['/secrets/public']
        )

        expect(config.allow_write).to eq(['/tmp'])
        expect(config.deny_write).to eq(['/etc'])
        expect(config.deny_read).to eq(['/secrets'])
        expect(config.allow_read).to eq(['/secrets/public'])
      end

      it 'converts to hash with camelCase keys' do
        config = described_class.new(
          allow_write: ['/tmp'],
          deny_read: ['/secrets'],
          allow_managed_read_paths_only: true
        )

        hash = config.to_h
        expect(hash[:allowWrite]).to eq(['/tmp'])
        expect(hash[:denyRead]).to eq(['/secrets'])
        expect(hash[:allowManagedReadPathsOnly]).to eq(true)
        expect(hash.key?(:denyWrite)).to eq(false)
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
        network = ClaudeAgentSDK::SandboxNetworkConfig.new(
          allowed_domains: ['api.example.com'], allow_local_binding: true
        )
        filesystem = ClaudeAgentSDK::SandboxFilesystemConfig.new(
          allow_write: ['/tmp'], deny_read: ['/secrets']
        )

        sandbox = described_class.new(
          enabled: true,
          fail_if_unavailable: true,
          auto_allow_bash_if_sandboxed: true,
          excluded_commands: ['rm'],
          allow_unsandboxed_commands: false,
          network: network,
          filesystem: filesystem,
          ignore_violations: { 'file' => ['/tmp/*'] },
          enable_weaker_nested_sandbox: false,
          enable_weaker_network_isolation: true,
          ripgrep: { command: '/usr/bin/rg', args: ['--hidden'] }
        )

        hash = sandbox.to_h
        expect(hash[:enabled]).to eq(true)
        expect(hash[:failIfUnavailable]).to eq(true)
        expect(hash[:autoAllowBashIfSandboxed]).to eq(true)
        expect(hash[:excludedCommands]).to eq(['rm'])
        expect(hash[:allowUnsandboxedCommands]).to eq(false)
        expect(hash[:network][:allowedDomains]).to eq(['api.example.com'])
        expect(hash[:filesystem][:allowWrite]).to eq(['/tmp'])
        expect(hash[:ignoreViolations]).to eq({ 'file' => ['/tmp/*'] })
        expect(hash[:enableWeakerNestedSandbox]).to eq(false)
        expect(hash[:enableWeakerNetworkIsolation]).to eq(true)
        expect(hash[:ripgrep]).to eq({ command: '/usr/bin/rg', args: ['--hidden'] })
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

      it 'stores exclude_dynamic_sections' do
        preset = described_class.new(preset: 'claude_code', exclude_dynamic_sections: true)
        expect(preset.exclude_dynamic_sections).to eq(true)
      end

      it 'includes exclude_dynamic_sections in to_h when set' do
        preset = described_class.new(preset: 'claude_code', exclude_dynamic_sections: true)
        hash = preset.to_h

        expect(hash[:exclude_dynamic_sections]).to eq(true)
      end

      it 'omits exclude_dynamic_sections from to_h when nil' do
        preset = described_class.new(preset: 'claude_code')
        hash = preset.to_h

        expect(hash.key?(:exclude_dynamic_sections)).to eq(false)
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

      it 'accepts xhigh effort level' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(effort: 'xhigh')
        expect(options.effort).to eq('xhigh')
      end

      it 'accepts bare option' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(bare: true)
        expect(options.bare).to eq(true)
      end

      it 'defaults bare to nil' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new
        expect(options.bare).to be_nil
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

    # New system message types

    describe ClaudeAgentSDK::StatusMessage do
      it 'is a SystemMessage subclass' do
        msg = described_class.new(subtype: 'status', data: {}, status: 'compacting')
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.status).to eq('compacting')
      end

      it 'stores all fields' do
        msg = described_class.new(
          subtype: 'status', data: {}, uuid: 'u1', session_id: 's1',
          status: 'compacting', permission_mode: 'default'
        )
        expect(msg.uuid).to eq('u1')
        expect(msg.session_id).to eq('s1')
        expect(msg.status).to eq('compacting')
        expect(msg.permission_mode).to eq('default')
      end
    end

    describe ClaudeAgentSDK::APIRetryMessage do
      it 'is a SystemMessage subclass' do
        msg = described_class.new(subtype: 'api_retry', data: {})
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
      end

      it 'stores all fields' do
        msg = described_class.new(
          subtype: 'api_retry', data: {}, uuid: 'u1', session_id: 's1',
          attempt: 2, max_retries: 5, retry_delay_ms: 1000,
          error_status: 429, error: 'Rate limited'
        )
        expect(msg.attempt).to eq(2)
        expect(msg.max_retries).to eq(5)
        expect(msg.retry_delay_ms).to eq(1000)
        expect(msg.error_status).to eq(429)
        expect(msg.error).to eq('Rate limited')
      end
    end

    describe ClaudeAgentSDK::LocalCommandOutputMessage do
      it 'is a SystemMessage subclass' do
        msg = described_class.new(subtype: 'local_command_output', data: {}, content: 'output text')
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.content).to eq('output text')
      end
    end

    describe ClaudeAgentSDK::HookStartedMessage do
      it 'stores all fields' do
        msg = described_class.new(
          subtype: 'hook_started', data: {}, uuid: 'u1', session_id: 's1',
          hook_id: 'h1', hook_name: 'my-hook', hook_event: 'PreToolUse'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.hook_id).to eq('h1')
        expect(msg.hook_name).to eq('my-hook')
        expect(msg.hook_event).to eq('PreToolUse')
      end
    end

    describe ClaudeAgentSDK::HookProgressMessage do
      it 'stores all fields' do
        msg = described_class.new(
          subtype: 'hook_progress', data: {}, uuid: 'u1', session_id: 's1',
          hook_id: 'h1', hook_name: 'my-hook', hook_event: 'PreToolUse',
          stdout: 'out', stderr: 'err', output: 'combined'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.stdout).to eq('out')
        expect(msg.stderr).to eq('err')
        expect(msg.output).to eq('combined')
      end
    end

    describe ClaudeAgentSDK::HookResponseMessage do
      it 'stores all fields' do
        msg = described_class.new(
          subtype: 'hook_response', data: {}, uuid: 'u1', session_id: 's1',
          hook_id: 'h1', hook_name: 'my-hook', hook_event: 'PreToolUse',
          output: 'result', stdout: 'out', stderr: 'err',
          exit_code: 0, outcome: 'success'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.exit_code).to eq(0)
        expect(msg.outcome).to eq('success')
      end
    end

    describe ClaudeAgentSDK::SessionStateChangedMessage do
      it 'stores state' do
        msg = described_class.new(
          subtype: 'session_state_changed', data: {}, uuid: 'u1', session_id: 's1',
          state: 'running'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.state).to eq('running')
      end
    end

    describe ClaudeAgentSDK::FilesPersistedMessage do
      it 'stores all fields' do
        files = [{ filename: 'a.txt', file_id: 'f1' }]
        failed = [{ filename: 'b.txt', error: 'too big' }]
        msg = described_class.new(
          subtype: 'files_persisted', data: {}, uuid: 'u1', session_id: 's1',
          files: files, failed: failed, processed_at: '2026-04-01T00:00:00Z'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.files).to eq(files)
        expect(msg.failed).to eq(failed)
        expect(msg.processed_at).to eq('2026-04-01T00:00:00Z')
      end
    end

    describe ClaudeAgentSDK::ElicitationCompleteMessage do
      it 'stores all fields' do
        msg = described_class.new(
          subtype: 'elicitation_complete', data: {}, uuid: 'u1', session_id: 's1',
          mcp_server_name: 'my-server', elicitation_id: 'e1'
        )
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.mcp_server_name).to eq('my-server')
        expect(msg.elicitation_id).to eq('e1')
      end
    end

    # New non-system message types

    describe ClaudeAgentSDK::ToolProgressMessage do
      it 'stores all fields' do
        msg = described_class.new(
          uuid: 'u1', session_id: 's1', tool_use_id: 'tu1',
          tool_name: 'Bash', parent_tool_use_id: 'ptu1',
          elapsed_time_seconds: 5.2, task_id: 't1'
        )
        expect(msg.uuid).to eq('u1')
        expect(msg.tool_use_id).to eq('tu1')
        expect(msg.tool_name).to eq('Bash')
        expect(msg.parent_tool_use_id).to eq('ptu1')
        expect(msg.elapsed_time_seconds).to eq(5.2)
        expect(msg.task_id).to eq('t1')
      end

      it 'defaults all fields to nil' do
        msg = described_class.new
        expect(msg.uuid).to be_nil
        expect(msg.tool_use_id).to be_nil
      end
    end

    describe ClaudeAgentSDK::AuthStatusMessage do
      it 'stores all fields' do
        msg = described_class.new(
          uuid: 'u1', session_id: 's1', is_authenticating: true,
          output: 'Please authenticate', error: nil
        )
        expect(msg.is_authenticating).to eq(true)
        expect(msg.output).to eq('Please authenticate')
        expect(msg.error).to be_nil
      end
    end

    describe ClaudeAgentSDK::ToolUseSummaryMessage do
      it 'stores all fields' do
        msg = described_class.new(
          uuid: 'u1', session_id: 's1', summary: 'Read 3 files',
          preceding_tool_use_ids: %w[tu1 tu2 tu3]
        )
        expect(msg.summary).to eq('Read 3 files')
        expect(msg.preceding_tool_use_ids).to eq(%w[tu1 tu2 tu3])
      end
    end

    describe ClaudeAgentSDK::PromptSuggestionMessage do
      it 'stores all fields' do
        msg = described_class.new(
          uuid: 'u1', session_id: 's1', suggestion: 'Try asking about...'
        )
        expect(msg.suggestion).to eq('Try asking about...')
      end
    end

    # New hook input types

    describe ClaudeAgentSDK::StopFailureHookInput do
      it 'stores all fields' do
        input = described_class.new(
          error: 'timeout', error_details: 'Process timed out',
          last_assistant_message: 'Working on it...'
        )
        expect(input.hook_event_name).to eq('StopFailure')
        expect(input.error).to eq('timeout')
        expect(input.error_details).to eq('Process timed out')
        expect(input.last_assistant_message).to eq('Working on it...')
      end
    end

    describe ClaudeAgentSDK::PostCompactHookInput do
      it 'stores all fields' do
        input = described_class.new(
          trigger: 'auto', compact_summary: 'Reduced to 12k tokens'
        )
        expect(input.hook_event_name).to eq('PostCompact')
        expect(input.trigger).to eq('auto')
        expect(input.compact_summary).to eq('Reduced to 12k tokens')
      end
    end

    describe ClaudeAgentSDK::PermissionDeniedHookInput do
      it 'stores all fields' do
        input = described_class.new(
          tool_name: 'Bash', tool_input: { command: 'rm -rf /' },
          tool_use_id: 'tu1', reason: 'Destructive command',
          agent_id: 'a1', agent_type: 'coder'
        )
        expect(input.hook_event_name).to eq('PermissionDenied')
        expect(input.tool_name).to eq('Bash')
        expect(input.reason).to eq('Destructive command')
        expect(input.agent_id).to eq('a1')
      end
    end

    describe ClaudeAgentSDK::TaskCreatedHookInput do
      it 'stores all fields' do
        input = described_class.new(
          task_id: 't1', task_subject: 'Fix bug',
          task_description: 'Fix the null pointer', teammate_name: 'coder', team_name: 'dev'
        )
        expect(input.hook_event_name).to eq('TaskCreated')
        expect(input.task_id).to eq('t1')
        expect(input.task_subject).to eq('Fix bug')
        expect(input.teammate_name).to eq('coder')
      end
    end

    describe ClaudeAgentSDK::ElicitationHookInput do
      it 'stores all fields' do
        input = described_class.new(
          mcp_server_name: 'srv', message: 'Auth needed',
          mode: 'oauth', url: 'https://example.com',
          elicitation_id: 'e1', requested_schema: { type: 'object' }
        )
        expect(input.hook_event_name).to eq('Elicitation')
        expect(input.mcp_server_name).to eq('srv')
        expect(input.message).to eq('Auth needed')
        expect(input.mode).to eq('oauth')
        expect(input.url).to eq('https://example.com')
        expect(input.elicitation_id).to eq('e1')
        expect(input.requested_schema).to eq({ type: 'object' })
      end
    end

    describe ClaudeAgentSDK::ElicitationResultHookInput do
      it 'stores all fields' do
        input = described_class.new(
          mcp_server_name: 'srv', elicitation_id: 'e1',
          mode: 'oauth', action: 'submit', content: 'token123'
        )
        expect(input.hook_event_name).to eq('ElicitationResult')
        expect(input.mcp_server_name).to eq('srv')
        expect(input.action).to eq('submit')
        expect(input.content).to eq('token123')
      end
    end

    describe ClaudeAgentSDK::InstructionsLoadedHookInput do
      it 'stores all fields' do
        input = described_class.new(
          file_path: 'CLAUDE.md', memory_type: 'project',
          load_reason: 'startup', globs: ['*.md'],
          trigger_file_path: 'src/main.rb'
        )
        expect(input.hook_event_name).to eq('InstructionsLoaded')
        expect(input.file_path).to eq('CLAUDE.md')
        expect(input.memory_type).to eq('project')
        expect(input.load_reason).to eq('startup')
        expect(input.globs).to eq(['*.md'])
        expect(input.trigger_file_path).to eq('src/main.rb')
      end
    end

    describe ClaudeAgentSDK::CwdChangedHookInput do
      it 'stores all fields' do
        input = described_class.new(old_cwd: '/old', new_cwd: '/new')
        expect(input.hook_event_name).to eq('CwdChanged')
        expect(input.old_cwd).to eq('/old')
        expect(input.new_cwd).to eq('/new')
      end
    end

    describe ClaudeAgentSDK::FileChangedHookInput do
      it 'stores all fields' do
        input = described_class.new(file_path: '/src/main.rb', event: 'change')
        expect(input.hook_event_name).to eq('FileChanged')
        expect(input.file_path).to eq('/src/main.rb')
        expect(input.event).to eq('change')
      end
    end

    # New hook specific output types

    describe ClaudeAgentSDK::PermissionDeniedHookSpecificOutput do
      it 'converts to CLI format' do
        output = described_class.new(retry: true)
        hash = output.to_h
        expect(hash[:hookEventName]).to eq('PermissionDenied')
        expect(hash[:retry]).to eq(true)
      end
    end

    describe ClaudeAgentSDK::CwdChangedHookSpecificOutput do
      it 'converts to CLI format' do
        output = described_class.new(watch_paths: ['/src', '/test'])
        hash = output.to_h
        expect(hash[:hookEventName]).to eq('CwdChanged')
        expect(hash[:watchPaths]).to eq(['/src', '/test'])
      end

      it 'omits watchPaths when nil' do
        output = described_class.new
        hash = output.to_h
        expect(hash.key?(:watchPaths)).to eq(false)
      end
    end

    describe ClaudeAgentSDK::FileChangedHookSpecificOutput do
      it 'converts to CLI format' do
        output = described_class.new(watch_paths: ['/src/**/*.rb'])
        hash = output.to_h
        expect(hash[:hookEventName]).to eq('FileChanged')
        expect(hash[:watchPaths]).to eq(['/src/**/*.rb'])
      end
    end

    # CompactMetadata preserved_segment

    describe 'CompactMetadata preserved_segment' do
      it 'stores preserved_segment' do
        meta = ClaudeAgentSDK::CompactMetadata.new(
          pre_tokens: 100, post_tokens: 50, trigger: 'auto',
          preserved_segment: { head_uuid: 'h1', anchor_uuid: 'a1', tail_uuid: 't1' }
        )
        expect(meta.preserved_segment).to eq({ head_uuid: 'h1', anchor_uuid: 'a1', tail_uuid: 't1' })
      end

      it 'parses preserved_segment from hash with snake_case' do
        meta = ClaudeAgentSDK::CompactMetadata.from_hash({
                                                           pre_tokens: 100, preserved_segment: { head_uuid: 'h1' }
                                                         })
        expect(meta.preserved_segment).to eq({ head_uuid: 'h1' })
      end

      it 'parses preserved_segment from hash with camelCase' do
        meta = ClaudeAgentSDK::CompactMetadata.from_hash({
                                                           preTokens: 100, preservedSegment: { headUuid: 'h1' }
                                                         })
        expect(meta.preserved_segment).to eq({ headUuid: 'h1' })
      end
    end

    # TaskStartedMessage new fields

    describe 'TaskStartedMessage workflow_name and prompt' do
      it 'stores workflow_name and prompt' do
        msg = ClaudeAgentSDK::TaskStartedMessage.new(
          subtype: 'task_started', data: {},
          task_id: 't1', description: 'desc', uuid: 'u1', session_id: 's1',
          workflow_name: 'deploy', prompt: 'Deploy to production'
        )
        expect(msg.workflow_name).to eq('deploy')
        expect(msg.prompt).to eq('Deploy to production')
      end

      it 'defaults to nil' do
        msg = ClaudeAgentSDK::TaskStartedMessage.new(
          subtype: 'task_started', data: {},
          task_id: 't1', description: 'desc', uuid: 'u1', session_id: 's1'
        )
        expect(msg.workflow_name).to be_nil
        expect(msg.prompt).to be_nil
      end
    end

    # TaskProgressMessage summary

    describe 'TaskProgressMessage summary' do
      it 'stores summary' do
        msg = ClaudeAgentSDK::TaskProgressMessage.new(
          subtype: 'task_progress', data: {},
          task_id: 't1', description: 'desc', usage: {},
          uuid: 'u1', session_id: 's1', summary: 'Halfway done'
        )
        expect(msg.summary).to eq('Halfway done')
      end

      it 'defaults to nil' do
        msg = ClaudeAgentSDK::TaskProgressMessage.new(
          subtype: 'task_progress', data: {},
          task_id: 't1', description: 'desc', usage: {},
          uuid: 'u1', session_id: 's1'
        )
        expect(msg.summary).to be_nil
      end
    end

    # ResultMessage uuid and fast_mode_state

    describe 'ResultMessage uuid and fast_mode_state' do
      it 'stores uuid and fast_mode_state' do
        msg = ClaudeAgentSDK::ResultMessage.new(
          subtype: 'success', duration_ms: 1000, duration_api_ms: 800,
          is_error: false, num_turns: 1, session_id: 's1',
          uuid: 'u1', fast_mode_state: 'on'
        )
        expect(msg.uuid).to eq('u1')
        expect(msg.fast_mode_state).to eq('on')
      end

      it 'defaults to nil' do
        msg = ClaudeAgentSDK::ResultMessage.new(
          subtype: 'success', duration_ms: 1000, duration_api_ms: 800,
          is_error: false, num_turns: 1, session_id: 's1'
        )
        expect(msg.uuid).to be_nil
        expect(msg.fast_mode_state).to be_nil
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
