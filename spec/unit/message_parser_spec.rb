# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::MessageParser do
  include TestHelpers

  describe '.parse' do
    it 'raises error for non-hash input' do
      expect { described_class.parse('not a hash') }
        .to raise_error(ClaudeAgentSDK::MessageParseError, /Invalid message data type/)
    end

    it 'raises error for missing type field' do
      expect { described_class.parse({}) }
        .to raise_error(ClaudeAgentSDK::MessageParseError, /missing 'type' field/)
    end

    it 'raises error for unknown message type' do
      expect { described_class.parse({ type: 'unknown' }) }
        .to raise_error(ClaudeAgentSDK::MessageParseError, /Unknown message type/)
    end

    context 'user messages' do
      it 'parses user message with string content' do
        data = {
          type: 'user',
          message: { content: 'Hello' },
          parent_tool_use_id: nil
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::UserMessage)
        expect(msg.content).to eq('Hello')
      end

      it 'parses user message with content blocks' do
        data = {
          type: 'user',
          message: {
            content: [
              { type: 'text', text: 'Hello' }
            ]
          }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::UserMessage)
        expect(msg.content).to be_an(Array)
        expect(msg.content.first).to be_a(ClaudeAgentSDK::TextBlock)
        expect(msg.content.first.text).to eq('Hello')
      end

      it 'includes parent_tool_use_id if present' do
        data = {
          type: 'user',
          message: { content: 'Hello' },
          parent_tool_use_id: 'tool_123'
        }

        msg = described_class.parse(data)
        expect(msg.parent_tool_use_id).to eq('tool_123')
      end
    end

    context 'assistant messages' do
      it 'parses assistant message with text blocks' do
        data = sample_assistant_message

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::AssistantMessage)
        expect(msg.model).to eq('claude-sonnet-4')
        expect(msg.content.first).to be_a(ClaudeAgentSDK::TextBlock)
      end

      it 'parses assistant message with tool use' do
        data = sample_assistant_message_with_tool_use

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::AssistantMessage)
        expect(msg.content.length).to eq(2)

        tool_use = msg.content[1]
        expect(tool_use).to be_a(ClaudeAgentSDK::ToolUseBlock)
        expect(tool_use.id).to eq('toolu_123')
        expect(tool_use.name).to eq('Read')
        expect(tool_use.input).to eq({ file_path: '/path/to/file.rb' })
      end

      it 'parses thinking blocks' do
        data = {
          type: 'assistant',
          message: {
            model: 'claude-sonnet-4',
            content: [
              { type: 'thinking', thinking: 'Let me think...', signature: 'sig123' }
            ]
          }
        }

        msg = described_class.parse(data)
        thinking = msg.content.first
        expect(thinking).to be_a(ClaudeAgentSDK::ThinkingBlock)
        expect(thinking.thinking).to eq('Let me think...')
      end
    end

    context 'system messages' do
      it 'parses system messages' do
        data = sample_system_message

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.subtype).to eq('info')
        expect(msg.data).to include(message: 'Test system message')
      end
    end

    context 'result messages' do
      it 'parses result messages' do
        data = sample_result_message

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::ResultMessage)
        expect(msg.subtype).to eq('success')
        expect(msg.duration_ms).to eq(1500)
        expect(msg.is_error).to eq(false)
        expect(msg.session_id).to eq('test_session_123')
        expect(msg.total_cost_usd).to eq(0.001234)
      end

      it 'handles optional fields' do
        data = {
          type: 'result',
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'test'
        }

        msg = described_class.parse(data)
        expect(msg.total_cost_usd).to be_nil
        expect(msg.usage).to be_nil
      end
    end

    context 'stream events' do
      it 'parses stream events' do
        data = {
          type: 'stream_event',
          uuid: 'evt_123',
          session_id: 'session_123',
          event: { type: 'message_start' },
          parent_tool_use_id: nil
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::StreamEvent)
        expect(msg.uuid).to eq('evt_123')
        expect(msg.event).to eq({ type: 'message_start' })
      end
    end

    context 'error handling' do
      it 'raises error for malformed user message' do
        data = { type: 'user' } # Missing message field

        expect { described_class.parse(data) }
          .to raise_error(ClaudeAgentSDK::MessageParseError)
      end

      it 'raises error for malformed assistant message' do
        data = { type: 'assistant', message: {} } # Missing content

        expect { described_class.parse(data) }
          .to raise_error(ClaudeAgentSDK::MessageParseError)
      end
    end
  end
end
