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

      it 'raises MessageParseError (not a raw TypeError) on a non-Hash content block' do
        data = { type: 'user', message: { content: ['oops'] } }

        expect { described_class.parse(data) }
          .to raise_error(ClaudeAgentSDK::MessageParseError, /Invalid content block \(expected Hash, got String\)/)
      end

      # Regression (L5): a non-Hash message field raised a raw TypeError from
      # message_data[:content] instead of the documented MessageParseError.
      it 'raises MessageParseError (not a raw TypeError) on a non-Hash message field' do
        data = { type: 'user', message: 'not a hash' }

        expect { described_class.parse(data) }
          .to raise_error(ClaudeAgentSDK::MessageParseError, /Invalid message field in user message \(expected Hash, got String\)/)
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

      it 'raises MessageParseError (not a raw NoMethodError) on string content' do
        data = { type: 'assistant', message: { model: 'm', content: 'hi' } }

        expect { described_class.parse(data) }
          .to raise_error(ClaudeAgentSDK::MessageParseError, /Invalid assistant content \(expected Array, got String\)/)
      end

      it 'raises MessageParseError (not a raw TypeError) on a non-Hash content block' do
        data = { type: 'assistant', message: { model: 'm', content: ['oops'] } }

        expect { described_class.parse(data) }
          .to raise_error(ClaudeAgentSDK::MessageParseError, /Invalid content block \(expected Hash, got String\)/)
      end

      # Regression (L5): a non-Hash message field raised a raw TypeError from
      # dig instead of the documented MessageParseError.
      it 'raises MessageParseError (not a raw TypeError) on a non-Hash message field' do
        data = { type: 'assistant', message: 'not a hash' }

        expect { described_class.parse(data) }
          .to raise_error(ClaudeAgentSDK::MessageParseError, /Invalid message field in assistant message \(expected Hash, got String\)/)
      end

      # I1: model is required, like Python — a missing model previously
      # constructed AssistantMessage(model: nil) silently.
      it 'raises MessageParseError when model is missing' do
        data = { type: 'assistant', message: { content: [{ type: 'text', text: 'hi' }] } }

        expect { described_class.parse(data) }
          .to raise_error(ClaudeAgentSDK::MessageParseError, /Missing required field.*model/)
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

      it 'parses mirror_error as MirrorErrorMessage' do
        data = {
          type: 'system',
          subtype: 'mirror_error',
          error: 'append failed',
          key: { 'project_key' => 'pk', 'session_id' => 'sess_1' },
          uuid: 'uuid_me',
          session_id: 'sess_1'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::MirrorErrorMessage)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.error).to eq('append failed')
        expect(msg.key).to eq('project_key' => 'pk', 'session_id' => 'sess_1')
        expect(msg.uuid).to eq('uuid_me')
        expect(msg.session_id).to eq('sess_1')
        expect(msg.subtype).to eq('mirror_error')
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

      it 'parses task_updated with a terminal patch.status as TaskUpdatedMessage' do
        data = {
          type: 'system',
          subtype: 'task_updated',
          task_id: 'task-abc',
          patch: { status: 'completed', end_time: 1_780_405_729_183 },
          uuid: 'uuid-4',
          session_id: 'session-1'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskUpdatedMessage)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.task_id).to eq('task-abc')
        expect(msg.patch).to eq({ status: 'completed', end_time: 1_780_405_729_183 })
        expect(msg.status).to eq('completed')
        expect(msg.uuid).to eq('uuid-4')
        expect(msg.session_id).to eq('session-1')
        expect(msg.subtype).to eq('task_updated')
        expect(ClaudeAgentSDK::TERMINAL_TASK_STATUSES).to include(msg.status)
      end

      it 'parses task_updated with only task_id and patch (no uuid/session_id)' do
        data = {
          type: 'system',
          subtype: 'task_updated',
          task_id: 'b1m21w89v',
          patch: { status: 'completed', end_time: 1_780_405_729_183 }
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskUpdatedMessage)
        expect(msg.task_id).to eq('b1m21w89v')
        expect(msg.status).to eq('completed')
        expect(msg.uuid).to be_nil
        expect(msg.session_id).to be_nil
      end

      it "defaults task_id to '' when absent (parity: never nil for this lifecycle message)" do
        data = { type: 'system', subtype: 'task_updated', patch: { status: 'killed' } }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskUpdatedMessage)
        expect(msg.task_id).to eq('')
        expect(msg.status).to eq('killed')
      end

      %w[pending running paused].each do |status|
        it "parses non-terminal task_updated status #{status.inspect} as not terminal" do
          data = { type: 'system', subtype: 'task_updated', task_id: 'task-abc', patch: { status: status } }

          msg = described_class.parse(data)
          expect(msg).to be_a(ClaudeAgentSDK::TaskUpdatedMessage)
          expect(msg.status).to eq(status)
          expect(ClaudeAgentSDK::TASK_UPDATED_STATUSES).to include(status)
          expect(ClaudeAgentSDK::TERMINAL_TASK_STATUSES).not_to include(status)
        end
      end

      %w[completed failed killed].each do |status|
        it "surfaces terminal task_updated status #{status.inspect} as terminal" do
          data = { type: 'system', subtype: 'task_updated', task_id: 'task-abc', patch: { status: status } }

          msg = described_class.parse(data)
          expect(msg.status).to eq(status)
          expect(ClaudeAgentSDK::TERMINAL_TASK_STATUSES).to include(status)
        end
      end

      it 'treats a TaskStop-killed task (status="killed") as terminal' do
        # In some kill paths no task_notification is emitted, so this
        # task_updated patch is the only terminal signal.
        data = {
          type: 'system',
          subtype: 'task_updated',
          task_id: 'bs2r8eew4',
          patch: { status: 'killed', end_time: 1_780_405_729_183 }
        }

        msg = described_class.parse(data)
        expect(msg.status).to eq('killed')
        expect(ClaudeAgentSDK::TERMINAL_TASK_STATUSES).to include('killed')
      end

      it 'parses task_updated with no patch as an empty patch and nil status' do
        data = { type: 'system', subtype: 'task_updated', task_id: 'task-abc' }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskUpdatedMessage)
        expect(msg.patch).to eq({})
        expect(msg.status).to be_nil
      end

      it 'preserves a patch lacking status verbatim with nil status' do
        data = { type: 'system', subtype: 'task_updated', task_id: 'task-abc', patch: { end_time: 1_780_405_729_183 } }

        msg = described_class.parse(data)
        expect(msg.patch).to eq({ end_time: 1_780_405_729_183 })
        expect(msg.status).to be_nil
      end

      ['completed', ['completed'], 42, nil].each do |patch|
        it "never raises on a non-Hash patch (#{patch.inspect}); falls back to {}" do
          data = { type: 'system', subtype: 'task_updated', task_id: 'task-abc', patch: patch }

          msg = described_class.parse(data)
          expect(msg).to be_a(ClaudeAgentSDK::TaskUpdatedMessage)
          expect(msg.patch).to eq({})
          expect(msg.status).to be_nil
        end
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

      it 'parses the subagent UI fields on task_started' do
        data = {
          type: 'system', subtype: 'task_started', task_id: 'task_abc', tool_use_id: 'toolu_1',
          description: 'Review the diff', task_type: 'local_agent', subagent_type: 'reviewer',
          is_backgrounded: false, spawn_depth: 1, uuid: 'uuid_1', session_id: 'sess_1'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::TaskStartedMessage)
        expect(msg.subagent_type).to eq('reviewer')
        expect(msg.is_backgrounded).to be(false) # foreground/blocking — must not read as nil
        expect(msg.spawn_depth).to eq(1)
        expect(msg.data).to eq(data)
      end

      it 'leaves the subagent UI fields nil on a task_started frame that omits them' do
        msg = described_class.parse({ type: 'system', subtype: 'task_started', task_id: 'task_abc',
                                      description: 'npm test', task_type: 'local_bash' })

        expect(msg.subagent_type).to be_nil
        expect(msg.is_backgrounded).to be_nil
        expect(msg.spawn_depth).to be_nil
      end

      it 'parses the skip_transcript / ambient display flags without filtering the frame' do
        started = described_class.parse({ type: 'system', subtype: 'task_started', task_id: 'watch-1',
                                          description: 'live-update watcher', skip_transcript: true, ambient: true })
        settled = described_class.parse({ type: 'system', subtype: 'task_notification', task_id: 'watch-1',
                                          status: 'completed', output_file: '/tmp/o', summary: 'done',
                                          skip_transcript: false, ambient: true })

        expect(started).to be_a(ClaudeAgentSDK::TaskStartedMessage) # surfaced, never dropped
        expect(started.skip_transcript).to be(true)
        expect(started.ambient).to be(true)
        expect(settled).to be_a(ClaudeAgentSDK::TaskNotificationMessage)
        expect(settled.skip_transcript).to be(false) # explicit false is not nil
        expect(settled.ambient).to be(true)
      end

      it 'leaves the display flags nil when a task frame omits them' do
        started = described_class.parse({ type: 'system', subtype: 'task_started', task_id: 't', description: 'd' })
        settled = described_class.parse({ type: 'system', subtype: 'task_notification', task_id: 't',
                                          status: 'completed', output_file: '/tmp/o', summary: 'done' })

        [started, settled].each do |msg|
          expect(msg.skip_transcript).to be_nil
          expect(msg.ambient).to be_nil
        end
      end

      it 'parses subagent_type on task_progress' do
        msg = described_class.parse({
                                      type: 'system', subtype: 'task_progress', task_id: 'task_abc',
                                      description: 'Still working', subagent_type: 'reviewer',
                                      usage: { total_tokens: 1, tool_uses: 0, duration_ms: 5 },
                                      summary: 'Reading the diff'
                                    })

        expect(msg).to be_a(ClaudeAgentSDK::TaskProgressMessage)
        expect(msg.subagent_type).to eq('reviewer')
        expect(msg.summary).to eq('Reading the diff')
      end

      it 'parses reason and raw resource_links on task_notification' do
        links = [{ uri: 'file:///tmp/report.pdf', name: 'report.pdf', mimeType: 'application/pdf', size: 1024 }]
        msg = described_class.parse({
                                      type: 'system', subtype: 'task_notification', task_id: 'task_abc',
                                      tool_use_id: 'toolu_1', status: 'stopped', reason: 'worker_restart',
                                      output_file: '/tmp/o.jsonl', summary: 'orphaned', resource_links: links
                                    })

        expect(msg).to be_a(ClaudeAgentSDK::TaskNotificationMessage)
        expect(msg.reason).to eq('worker_restart')
        expect(msg.resource_links).to eq(links)
        expect(msg.resource_links.first[:mimeType]).to eq('application/pdf') # wire spelling preserved
      end

      it 'passes resource_links through raw: nothing dropped, reshaped, or capped' do
        # 51 links, well past the CLI's own "at most 50 links / 64 KiB" producer
        # note — the SDK must not enforce either figure.
        links = Array.new(51) do |i|
          {
            uri: "file:///tmp/report-#{i}.bin", name: "report-#{i}.bin", title: "Report #{i}",
            description: 'x' * 1500, mimeType: 'application/octet-stream', size: 1024.5 + i,
            annotations: { audience: ['user'], priority: 0.25, nested: { lastModified: '2026-01-01T00:00:00Z' } },
            futureField: { kept: true }
          }
        end
        expect(JSON.generate(links).bytesize).to be > 64 * 1024
        snapshot = Marshal.load(Marshal.dump(links)) # taken BEFORE parsing, to catch in-place edits

        msg = described_class.parse({
                                      type: 'system', subtype: 'task_notification', task_id: 'task_abc',
                                      tool_use_id: 'toolu_1', status: 'completed', output_file: '/tmp/o.jsonl',
                                      summary: 'done', resource_links: links
                                    })

        expect(msg.resource_links).to equal(links) # the very same Array, not a reconstruction
        expect(msg.resource_links.size).to eq(51)
        expect(msg.resource_links).to eq(snapshot) # and nobody edited it in place
        last = msg.resource_links.last
        expect(last[:size]).to eq(1074.5) # fractional size survives (a Number, not an Integer)
        expect(last[:annotations]).to eq(audience: ['user'], priority: 0.25,
                                         nested: { lastModified: '2026-01-01T00:00:00Z' })
        expect(last[:futureField]).to eq(kept: true) # unknown fields survive
        expect(last).not_to have_key(:type) # no discriminator is invented
      end

      it 'leaves reason and resource_links nil on an ordinary task_notification' do
        msg = described_class.parse({ type: 'system', subtype: 'task_notification', task_id: 'task_abc',
                                      status: 'completed', output_file: '/tmp/o.jsonl', summary: 'done' })

        expect(msg.reason).to be_nil
        expect(msg.resource_links).to be_nil
      end

      it 'surfaces a move to the background through task_updated patch.is_backgrounded' do
        msg = described_class.parse({ type: 'system', subtype: 'task_updated', task_id: 'task_abc',
                                      patch: { is_backgrounded: true } })

        expect(msg).to be_a(ClaudeAgentSDK::TaskUpdatedMessage)
        expect(msg.is_backgrounded).to be(true)
        expect(msg.status).to be_nil
      end

      it 'keeps a zero end_time / total_paused_ms from the wire (0 is not nil)' do
        msg = described_class.parse({ type: 'system', subtype: 'task_updated', task_id: 'task_abc',
                                      patch: { end_time: 0, total_paused_ms: 0 } })

        expect(msg.end_time).to eq(0)
        expect(msg.total_paused_ms).to eq(0)
      end

      it 'keeps patch.is_backgrounded false distinct from an absent key' do
        explicit = described_class.parse({ type: 'system', subtype: 'task_updated', task_id: 'task_abc',
                                           patch: { is_backgrounded: false } })
        absent = described_class.parse({ type: 'system', subtype: 'task_updated', task_id: 'task_abc',
                                         patch: { status: 'running' } })

        expect(explicit.is_backgrounded).to be(false)
        expect(absent.is_backgrounded).to be_nil
      end

      it 'derives error, end_time, total_paused_ms and description from the task_updated patch' do
        msg = described_class.parse({
                                      type: 'system', subtype: 'task_updated', task_id: 'task_abc',
                                      patch: { status: 'failed', error: 'boom', end_time: 1_780_405_729_183,
                                               total_paused_ms: 0, description: 'renamed' }
                                    })

        expect(msg.error).to eq('boom')
        expect(msg.end_time).to eq(1_780_405_729_183)
        expect(msg.total_paused_ms).to eq(0)
        expect(msg.description).to eq('renamed')
      end

      it 'parses background_tasks_changed as BackgroundTasksChangedMessage with the raw task list' do
        data = {
          type: 'system', subtype: 'background_tasks_changed',
          tasks: [
            { task_id: 'bg-1', task_type: 'local_agent', description: 'Review the diff' },
            { task_id: 'bg-2', task_type: 'local_bash', description: 'tail -f log', ambient: true }
          ],
          uuid: 'uuid_1', session_id: 'sess_1'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::BackgroundTasksChangedMessage)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.subtype).to eq('background_tasks_changed')
        expect(msg.tasks).to eq(data[:tasks])
        expect(msg.tasks.last[:ambient]).to be(true)
        expect(msg.uuid).to eq('uuid_1')
        expect(msg.session_id).to eq('sess_1')
        expect(msg.data).to eq(data)
      end

      it 'parses an empty background_tasks_changed set as [] (not nil)' do
        msg = described_class.parse({ type: 'system', subtype: 'background_tasks_changed', tasks: [] })

        expect(msg).to be_a(ClaudeAgentSDK::BackgroundTasksChangedMessage)
        expect(msg.tasks).to eq([])
      end

      it 'parses permission_denied as PermissionDeniedMessage' do
        data = {
          type: 'system', subtype: 'permission_denied', tool_name: 'Bash', tool_use_id: 'toolu_9',
          agent_id: 'agent_7', decision_reason_type: 'classifier', decision_reason_code: 'memory_paused',
          decision_reason: 'Blocked by the auto-mode classifier', message: 'Permission to use Bash was denied.',
          uuid: 'uuid_1', session_id: 'sess_1'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::PermissionDeniedMessage)
        expect(msg).to be_a(ClaudeAgentSDK::SystemMessage)
        expect(msg.subtype).to eq('permission_denied')
        expect(msg.tool_name).to eq('Bash')
        expect(msg.tool_use_id).to eq('toolu_9')
        expect(msg.agent_id).to eq('agent_7')
        expect(msg.decision_reason_type).to eq('classifier')
        expect(msg.decision_reason).to eq('Blocked by the auto-mode classifier')
        expect(msg.message).to eq('Permission to use Bash was denied.')
        expect(msg.uuid).to eq('uuid_1')
        expect(msg.session_id).to eq('sess_1')
        # @internal in the CLI schema: reachable through data, never a typed reader.
        expect(msg).not_to respond_to(:decision_reason_code)
        expect(msg.data[:decision_reason_code]).to eq('memory_paused')
      end

      it 'parses a main-session permission_denied with only the required fields' do
        msg = described_class.parse({ type: 'system', subtype: 'permission_denied', tool_name: 'Write',
                                      tool_use_id: 'toolu_9', message: 'denied' })

        expect(msg).to be_a(ClaudeAgentSDK::PermissionDeniedMessage)
        expect(msg.agent_id).to be_nil
        expect(msg.decision_reason_type).to be_nil
        expect(msg.decision_reason).to be_nil
      end

      %w[agents_killed task_summary].each do |subtype|
        it "leaves the CLI-internal #{subtype} frame as a generic SystemMessage" do
          data = { type: 'system', subtype: subtype, task_id: 'task_abc' }

          msg = described_class.parse(data)
          expect(msg.class).to eq(ClaudeAgentSDK::SystemMessage)
          expect(msg.data).to eq(data)
        end
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
        expect(msg).not_to be_a(ClaudeAgentSDK::TaskProgressMessage)
        expect(msg).not_to be_a(ClaudeAgentSDK::TaskNotificationMessage)
        expect(msg).not_to be_a(ClaudeAgentSDK::TaskUpdatedMessage)
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

      it 'parses model_usage, permission_denials, and errors',
         rbs_incompatible: 'parses a hand-built frame with a String model_usage key' do
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

    context 'conversation reset' do
      it 'parses conversation_reset into a typed ConversationResetMessage' do
        data = {
          type: 'conversation_reset',
          new_conversation_id: 'd2f4a573-ca99-42a2-bb7a-905b40c908e8',
          uuid: 'msg-1',
          session_id: '66694129-ce74-4ee1-9b0f-994155ac97ba'
        }

        msg = described_class.parse(data)
        expect(msg).to be_a(ClaudeAgentSDK::ConversationResetMessage)
        expect(msg.new_conversation_id).to eq('d2f4a573-ca99-42a2-bb7a-905b40c908e8')
        expect(msg.uuid).to eq('msg-1')
        expect(msg.session_id).to eq('66694129-ce74-4ee1-9b0f-994155ac97ba')
      end

      it 'raises MessageParseError when a required field is missing' do
        expect do
          described_class.parse(type: 'conversation_reset', uuid: 'u', session_id: 's')
        end.to raise_error(ClaudeAgentSDK::MessageParseError, /new_conversation_id/)
      end
    end

    context 'message origin' do
      it 'surfaces origin on user messages for both content shapes, passing unmodeled keys through' do
        peer = {
          kind: 'peer',
          from: 'peer-addr',
          name: 'other-session',
          verifiedPeerPid: 4242,
          someFutureField: true
        }

        ['hi', [{ type: 'text', text: 'hi' }]].each do |content|
          msg = described_class.parse(type: 'user', message: { content: content }, origin: peer)
          expect(msg).to be_a(ClaudeAgentSDK::UserMessage)
          expect(msg.origin).to eq(peer)
          expect(msg.origin[:kind]).to eq('peer')
          expect(msg.origin[:from]).to eq('peer-addr')
          # camelCase wire keys survive untouched, unlike snake_case attributes
          expect(msg.origin[:verifiedPeerPid]).to eq(4242)
          expect(msg.origin[:someFutureField]).to be(true)
        end
      end

      it 'parses an absent, non-Hash or kind-less origin on a user message to nil' do
        [{}, { origin: nil }, { origin: 'human' }, { origin: {} }, { origin: { kind: 42 } }].each do |extra|
          msg = described_class.parse({ type: 'user', message: { content: 'hi' } }.merge(extra))
          expect(msg).to be_a(ClaudeAgentSDK::UserMessage)
          expect(msg.origin).to be_nil, "expected nil origin for #{extra.inspect}"
        end
      end

      context 'on results' do
        let(:base) do
          {
            type: 'result',
            subtype: 'success',
            duration_ms: 1000,
            duration_api_ms: 500,
            is_error: false,
            num_turns: 2,
            session_id: 'session_123'
          }
        end

        it 'is nil when the CLI did not attribute the turn' do
          msg = described_class.parse(base)
          expect(msg).to be_a(ClaudeAgentSDK::ResultMessage)
          expect(msg.origin).to be_nil
        end

        it 'identifies what triggered the turn' do
          msg = described_class.parse(base.merge(origin: { kind: 'human' }))
          expect(msg.origin).to eq({ kind: 'human' })

          %w[scheduled-trigger peer-send-message].each do |subkind|
            origin = { kind: 'task-notification', subkind: subkind }
            expect(described_class.parse(base.merge(origin: origin)).origin).to eq(origin)
          end

          msg = described_class.parse(base.merge(origin: { kind: 'unclassified' }))
          expect(msg.origin[:kind]).to eq('unclassified')
        end

        it 'reads a malformed origin as absent rather than surfacing it verbatim' do
          [{ origin: nil }, { origin: 'human' }, { origin: {} }, { origin: { kind: 42 } }].each do |extra|
            msg = described_class.parse(base.merge(extra))
            expect(msg.origin).to be_nil, "expected nil origin for #{extra.inspect}"
          end
        end
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

      it 'parses terminal_reason' do
        data = {
          type: 'result',
          subtype: 'success',
          duration_ms: 1000,
          duration_api_ms: 800,
          is_error: false,
          num_turns: 1,
          session_id: 'test',
          terminal_reason: 'aborted_streaming'
        }

        msg = described_class.parse(data)
        expect(msg.terminal_reason).to eq('aborted_streaming')
      end

      it 'leaves terminal_reason nil when the CLI does not report one' do
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
        expect(msg.terminal_reason).to be_nil
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
