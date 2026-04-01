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

      it 'parses usage field when present' do
        data = {
          type: 'assistant',
          message: {
            model: 'claude-sonnet-4',
            content: [
              { type: 'text', text: 'Hello' }
            ],
            usage: { input_tokens: 100, output_tokens: 50 }
          }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::AssistantMessage)
        expect(msg.usage).to eq({ input_tokens: 100, output_tokens: 50 })
      end

      it 'defaults usage to nil when absent' do
        data = {
          type: 'assistant',
          message: {
            model: 'claude-sonnet-4',
            content: [
              { type: 'text', text: 'Hello' }
            ]
          }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::AssistantMessage)
        expect(msg.usage).to be_nil
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

      it 'parses init as InitMessage with all fields' do
        data = {
          type: 'system',
          subtype: 'init',
          uuid: 'uuid-123',
          session_id: 'new-session-uuid',
          agents: ['code-reviewer'],
          apiKeySource: 'env',
          betas: ['context-1m-2025-08-07'],
          claude_code_version: '1.2.3',
          cwd: '/tmp/test',
          tools: %w[Read Write Bash],
          mcp_servers: [{ name: 'myserver', status: 'connected' }],
          model: 'claude-sonnet-4-20250514',
          permissionMode: 'acceptEdits',
          slash_commands: %w[compact clear],
          output_style: 'concise',
          skills: ['commit'],
          plugins: [{ name: 'my-plugin', path: './plugin' }]
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::InitMessage)
        expect(msg.uuid).to eq('uuid-123')
        expect(msg.session_id).to eq('new-session-uuid')
        expect(msg.agents).to eq(['code-reviewer'])
        expect(msg.api_key_source).to eq('env')
        expect(msg.betas).to eq(['context-1m-2025-08-07'])
        expect(msg.claude_code_version).to eq('1.2.3')
        expect(msg.cwd).to eq('/tmp/test')
        expect(msg.tools).to eq(%w[Read Write Bash])
        expect(msg.model).to eq('claude-sonnet-4-20250514')
        expect(msg.permission_mode).to eq('acceptEdits')
        expect(msg.slash_commands).to eq(%w[compact clear])
        expect(msg.output_style).to eq('concise')
        expect(msg.skills).to eq(['commit'])
        expect(msg.plugins).to eq([{ name: 'my-plugin', path: './plugin' }])
      end

      it 'parses compact_boundary as CompactBoundaryMessage with uuid and session_id' do
        data = {
          type: 'system',
          subtype: 'compact_boundary',
          uuid: 'uuid-456',
          session_id: 'sess-789',
          compact_metadata: {
            pre_tokens: 95_000,
            trigger: 'auto'
          }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::CompactBoundaryMessage)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.uuid).to eq('uuid-456')
        expect(msg.session_id).to eq('sess-789')
        expect(msg.compact_metadata).to be_a(ClaudeAgentSDK::CompactMetadata)
        expect(msg.compact_metadata.pre_tokens).to eq(95_000)
        expect(msg.compact_metadata.trigger).to eq('auto')
      end

      it 'parses compact_boundary with nil metadata' do
        data = {
          type: 'system',
          subtype: 'compact_boundary'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::CompactBoundaryMessage)
        expect(msg.compact_metadata).to be_nil
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

      it 'parses model_usage, permission_denials, and errors' do
        data = {
          type: 'result',
          subtype: 'error_max_turns',
          duration_ms: 5000,
          duration_api_ms: 4000,
          is_error: true,
          num_turns: 10,
          session_id: 'test',
          modelUsage: { 'claude-sonnet' => { input_tokens: 1000, output_tokens: 500 } },
          permission_denials: [{ tool_name: 'Bash', tool_use_id: 'tu_1', tool_input: { command: 'rm -rf /' } }],
          errors: ['Max turns exceeded']
        }

        msg = described_class.parse(data)
        expect(msg.model_usage).to eq({ 'claude-sonnet' => { input_tokens: 1000, output_tokens: 500 } })
        expect(msg.permission_denials).to eq([{ tool_name: 'Bash', tool_use_id: 'tu_1',
                                                tool_input: { command: 'rm -rf /' } }])
        expect(msg.errors).to eq(['Max turns exceeded'])
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

    context 'new system message subtypes' do
      it 'parses status as StatusMessage' do
        data = {
          type: 'system',
          subtype: 'status',
          uuid: 'u1',
          session_id: 's1',
          status: 'compacting',
          permissionMode: 'default'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::StatusMessage)
        expect(msg.status).to eq('compacting')
        expect(msg.permission_mode).to eq('default')
      end

      it 'parses api_retry as APIRetryMessage' do
        data = {
          type: 'system',
          subtype: 'api_retry',
          uuid: 'u1',
          session_id: 's1',
          attempt: 2,
          maxRetries: 5,
          retryDelayMs: 1000,
          errorStatus: 429,
          error: 'Rate limited'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::APIRetryMessage)
        expect(msg.attempt).to eq(2)
        expect(msg.max_retries).to eq(5)
        expect(msg.retry_delay_ms).to eq(1000)
        expect(msg.error_status).to eq(429)
        expect(msg.error).to eq('Rate limited')
      end

      it 'parses local_command_output as LocalCommandOutputMessage' do
        data = {
          type: 'system',
          subtype: 'local_command_output',
          uuid: 'u1',
          session_id: 's1',
          content: 'command output here'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::LocalCommandOutputMessage)
        expect(msg.content).to eq('command output here')
      end

      it 'parses hook_started as HookStartedMessage' do
        data = {
          type: 'system',
          subtype: 'hook_started',
          uuid: 'u1',
          session_id: 's1',
          hookId: 'h1',
          hookName: 'my-hook',
          hookEvent: 'PreToolUse'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::HookStartedMessage)
        expect(msg.hook_id).to eq('h1')
        expect(msg.hook_name).to eq('my-hook')
        expect(msg.hook_event).to eq('PreToolUse')
      end

      it 'parses hook_progress as HookProgressMessage' do
        data = {
          type: 'system',
          subtype: 'hook_progress',
          uuid: 'u1',
          session_id: 's1',
          hookId: 'h1',
          hookName: 'my-hook',
          hookEvent: 'PreToolUse',
          stdout: 'out',
          stderr: 'err',
          output: 'combined'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::HookProgressMessage)
        expect(msg.stdout).to eq('out')
        expect(msg.stderr).to eq('err')
        expect(msg.output).to eq('combined')
      end

      it 'parses hook_response as HookResponseMessage' do
        data = {
          type: 'system',
          subtype: 'hook_response',
          uuid: 'u1',
          session_id: 's1',
          hookId: 'h1',
          hookName: 'my-hook',
          hookEvent: 'PostToolUse',
          output: 'result',
          stdout: 'out',
          stderr: 'err',
          exitCode: 0,
          outcome: 'success'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::HookResponseMessage)
        expect(msg.exit_code).to eq(0)
        expect(msg.outcome).to eq('success')
        expect(msg.hook_id).to eq('h1')
      end

      it 'parses session_state_changed as SessionStateChangedMessage' do
        data = {
          type: 'system',
          subtype: 'session_state_changed',
          uuid: 'u1',
          session_id: 's1',
          state: 'running'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::SessionStateChangedMessage)
        expect(msg.state).to eq('running')
      end

      it 'parses files_persisted as FilesPersistedMessage' do
        data = {
          type: 'system',
          subtype: 'files_persisted',
          uuid: 'u1',
          session_id: 's1',
          files: [{ filename: 'a.txt', file_id: 'f1' }],
          failed: [{ filename: 'b.txt', error: 'too big' }],
          processedAt: '2026-04-01T00:00:00Z'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::FilesPersistedMessage)
        expect(msg.files.length).to eq(1)
        expect(msg.failed.length).to eq(1)
        expect(msg.processed_at).to eq('2026-04-01T00:00:00Z')
      end

      it 'parses elicitation_complete as ElicitationCompleteMessage' do
        data = {
          type: 'system',
          subtype: 'elicitation_complete',
          uuid: 'u1',
          session_id: 's1',
          mcpServerName: 'my-server',
          elicitationId: 'e1'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::ElicitationCompleteMessage)
        expect(msg.mcp_server_name).to eq('my-server')
        expect(msg.elicitation_id).to eq('e1')
      end
    end

    context 'expanded task messages' do
      it 'parses task_started with workflow_name and prompt' do
        data = {
          type: 'system',
          subtype: 'task_started',
          task_id: 'task_1',
          description: 'Running deploy',
          uuid: 'u1',
          session_id: 's1',
          workflowName: 'deploy',
          prompt: 'Deploy to prod'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskStartedMessage)
        expect(msg.workflow_name).to eq('deploy')
        expect(msg.prompt).to eq('Deploy to prod')
      end

      it 'parses task_progress with summary' do
        data = {
          type: 'system',
          subtype: 'task_progress',
          task_id: 'task_1',
          description: 'Working',
          usage: {},
          uuid: 'u1',
          session_id: 's1',
          summary: 'Halfway done'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskProgressMessage)
        expect(msg.summary).to eq('Halfway done')
      end
    end

    context 'result message new fields' do
      it 'parses uuid and fast_mode_state' do
        data = {
          type: 'result',
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'test',
          uuid: 'result_uuid',
          fastModeState: 'on'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::ResultMessage)
        expect(msg.uuid).to eq('result_uuid')
        expect(msg.fast_mode_state).to eq('on')
      end
    end

    context 'init message fast_mode_state' do
      it 'parses fast_mode_state from camelCase' do
        data = {
          type: 'system',
          subtype: 'init',
          uuid: 'u1',
          session_id: 's1',
          fastModeState: 'cooldown'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::InitMessage)
        expect(msg.fast_mode_state).to eq('cooldown')
      end
    end

    context 'new top-level message types' do
      it 'parses tool_progress messages' do
        data = {
          type: 'tool_progress',
          uuid: 'u1',
          session_id: 's1',
          toolUseId: 'tu1',
          toolName: 'Bash',
          parentToolUseId: 'ptu1',
          elapsedTimeSeconds: 5.2,
          taskId: 't1'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::ToolProgressMessage)
        expect(msg.tool_use_id).to eq('tu1')
        expect(msg.tool_name).to eq('Bash')
        expect(msg.parent_tool_use_id).to eq('ptu1')
        expect(msg.elapsed_time_seconds).to eq(5.2)
        expect(msg.task_id).to eq('t1')
      end

      it 'parses auth_status messages' do
        data = {
          type: 'auth_status',
          uuid: 'u1',
          session_id: 's1',
          isAuthenticating: true,
          output: 'Opening browser...',
          error: nil
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::AuthStatusMessage)
        expect(msg.is_authenticating).to eq(true)
        expect(msg.output).to eq('Opening browser...')
      end

      it 'parses tool_use_summary messages' do
        data = {
          type: 'tool_use_summary',
          uuid: 'u1',
          session_id: 's1',
          summary: 'Read 3 files',
          precedingToolUseIds: %w[tu1 tu2 tu3]
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::ToolUseSummaryMessage)
        expect(msg.summary).to eq('Read 3 files')
        expect(msg.preceding_tool_use_ids).to eq(%w[tu1 tu2 tu3])
      end

      it 'parses prompt_suggestion messages' do
        data = {
          type: 'prompt_suggestion',
          uuid: 'u1',
          session_id: 's1',
          suggestion: 'Try asking about the API'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::PromptSuggestionMessage)
        expect(msg.suggestion).to eq('Try asking about the API')
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
