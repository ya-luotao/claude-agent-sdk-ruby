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

    it 'returns nil for unknown message type' do
      result = described_class.parse({ type: 'future_type' })
      expect(result).to be_nil
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

      it 'preserves unknown content block types as UnknownBlock' do
        data = {
          type: 'user',
          message: {
            content: [
              { type: 'text', text: 'Check this PDF' },
              { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: 'abc123' } }
            ]
          }
        }

        msg = described_class.parse(data)
        expect(msg.content.length).to eq(2)
        expect(msg.content[0]).to be_a(ClaudeAgentSDK::TextBlock)
        expect(msg.content[1]).to be_a(ClaudeAgentSDK::UnknownBlock)
        expect(msg.content[1].type).to eq('document')
        expect(msg.content[1].data[:source][:media_type]).to eq('application/pdf')
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

      it 'parses uuid for rewind support' do
        data = {
          type: 'user',
          message: { content: 'Hello' },
          uuid: 'user_msg_abc123'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::UserMessage)
        expect(msg.uuid).to eq('user_msg_abc123')
      end

      it 'handles missing uuid gracefully' do
        data = {
          type: 'user',
          message: { content: 'Hello' }
        }

        msg = described_class.parse(data)
        expect(msg.uuid).to be_nil
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

      it 'preserves unknown content block types in assistant messages' do
        data = {
          type: 'assistant',
          message: {
            model: 'claude-sonnet-4',
            content: [
              { type: 'text', text: 'Here is the image' },
              { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'png_data' } }
            ]
          }
        }

        msg = described_class.parse(data)
        expect(msg.content.length).to eq(2)
        expect(msg.content[0]).to be_a(ClaudeAgentSDK::TextBlock)
        expect(msg.content[1]).to be_a(ClaudeAgentSDK::UnknownBlock)
        expect(msg.content[1].type).to eq('image')
        expect(msg.content[1].data[:source][:media_type]).to eq('image/png')
      end

      it 'parses error field' do
        data = {
          type: 'assistant',
          message: {
            model: 'claude-sonnet-4',
            content: [
              { type: 'text', text: 'Error occurred' }
            ]
          },
          error: 'rate_limit'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::AssistantMessage)
        expect(msg.error).to eq('rate_limit')
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

      it 'parses task_started as TaskStartedMessage' do
        data = {
          type: 'system',
          subtype: 'task_started',
          task_id: 'task_abc',
          description: 'Running background task',
          uuid: 'uuid_123',
          session_id: 'sess_1',
          tool_use_id: 'toolu_1',
          task_type: 'background'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskStartedMessage)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.task_id).to eq('task_abc')
        expect(msg.description).to eq('Running background task')
        expect(msg.uuid).to eq('uuid_123')
        expect(msg.session_id).to eq('sess_1')
        expect(msg.tool_use_id).to eq('toolu_1')
        expect(msg.task_type).to eq('background')
        expect(msg.subtype).to eq('task_started')
        expect(msg.data).to eq(data)
      end

      it 'parses task_progress as TaskProgressMessage' do
        data = {
          type: 'system',
          subtype: 'task_progress',
          task_id: 'task_abc',
          description: 'Still working',
          usage: { total_tokens: 500, tool_uses: 3, duration_ms: 2000 },
          uuid: 'uuid_456',
          session_id: 'sess_1',
          tool_use_id: 'toolu_2',
          last_tool_name: 'Bash'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskProgressMessage)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.task_id).to eq('task_abc')
        expect(msg.usage).to eq({ total_tokens: 500, tool_uses: 3, duration_ms: 2000 })
        expect(msg.last_tool_name).to eq('Bash')
      end

      it 'parses task_notification as TaskNotificationMessage' do
        data = {
          type: 'system',
          subtype: 'task_notification',
          task_id: 'task_abc',
          status: 'completed',
          output_file: '/tmp/output.jsonl',
          summary: 'Task completed successfully',
          uuid: 'uuid_789',
          session_id: 'sess_1',
          usage: { total_tokens: 1000, tool_uses: 5, duration_ms: 5000 }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskNotificationMessage)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.status).to eq('completed')
        expect(msg.output_file).to eq('/tmp/output.jsonl')
        expect(msg.summary).to eq('Task completed successfully')
        expect(msg.usage).to eq({ total_tokens: 1000, tool_uses: 5, duration_ms: 5000 })
      end

      it 'falls back to SystemMessage for unknown subtypes' do
        data = {
          type: 'system',
          subtype: 'future_subtype',
          some_field: 'value'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg).not_to be_a(ClaudeAgentSDK::TaskStartedMessage)
        expect(msg.subtype).to eq('future_subtype')
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

      it 'parses stop_reason' do
        data = {
          type: 'result',
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'test',
          stop_reason: 'end_turn'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::ResultMessage)
        expect(msg.stop_reason).to eq('end_turn')
      end

      it 'parses structured_output' do
        data = {
          type: 'result',
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'test',
          structured_output: { name: 'John', age: 30, active: true }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::ResultMessage)
        expect(msg.structured_output).to eq({ name: 'John', age: 30, active: true })
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

    context 'rate limit events' do
      it 'parses rate_limit_event with typed fields' do
        data = {
          type: 'rate_limit_event',
          uuid: 'rl_123',
          session_id: 'sess_456',
          rate_limit_info: {
            status: 'allowed_warning',
            resetsAt: 1_700_000_000,
            rateLimitType: 'five_hour',
            utilization: 0.85,
            overageStatus: 'allowed',
            overageResetsAt: 1_700_100_000,
            overageDisabledReason: nil
          }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::RateLimitEvent)
        expect(msg.uuid).to eq('rl_123')
        expect(msg.session_id).to eq('sess_456')

        info = msg.rate_limit_info
        expect(info).to be_a(ClaudeAgentSDK::RateLimitInfo)
        expect(info.status).to eq('allowed_warning')
        expect(info.resets_at).to eq(1_700_000_000)
        expect(info.rate_limit_type).to eq('five_hour')
        expect(info.utilization).to eq(0.85)
        expect(info.overage_status).to eq('allowed')
        expect(info.overage_resets_at).to eq(1_700_100_000)
        expect(info.overage_disabled_reason).to be_nil
        expect(info.raw).to eq(data[:rate_limit_info])
      end

      it 'handles missing rate_limit_info gracefully' do
        data = {
          type: 'rate_limit_event',
          uuid: 'rl_456',
          session_id: 'sess_789'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::RateLimitEvent)
        expect(msg.rate_limit_info.status).to be_nil
        expect(msg.rate_limit_info.raw).to eq({})
      end

      it 'provides backward-compatible data accessor with full payload' do
        data = {
          type: 'rate_limit_event',
          uuid: 'rl_789',
          session_id: 'sess_abc',
          rate_limit_info: { status: 'rejected', resetsAt: 1_700_000_000 }
        }

        msg = described_class.parse(data)
        expect(msg.data).to eq(data)
        expect(msg.data[:uuid]).to eq('rl_789')
        expect(msg.data[:session_id]).to eq('sess_abc')
      end
    end

    context 'user message tool_use_result' do
      it 'parses tool_use_result when present' do
        data = {
          type: 'user',
          message: { content: 'Tool result' },
          tool_use_result: { output: 'success', status: 'ok' }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::UserMessage)
        expect(msg.tool_use_result).to eq({ output: 'success', status: 'ok' })
      end

      it 'defaults tool_use_result to nil when absent' do
        data = {
          type: 'user',
          message: { content: 'Hello' }
        }

        msg = described_class.parse(data)
        expect(msg.tool_use_result).to be_nil
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
