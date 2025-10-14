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
    end

    describe ClaudeAgentSDK::AssistantMessage do
      it 'stores assistant content' do
        blocks = [ClaudeAgentSDK::TextBlock.new(text: 'Hello')]
        msg = described_class.new(content: blocks, model: 'claude-sonnet-4')
        expect(msg.content).to eq(blocks)
        expect(msg.model).to eq('claude-sonnet-4')
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
  end
end
