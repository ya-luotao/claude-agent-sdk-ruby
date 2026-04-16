# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe ClaudeAgentSDK::Sessions do
  describe '.simple_hash' do
    it 'returns "0" for empty string' do
      expect(described_class.simple_hash('')).to eq('0')
    end

    it 'produces consistent output for known inputs' do
      # These must match TypeScript's simpleHash exactly
      result = described_class.simple_hash('/Users/test/project')
      expect(result).to be_a(String)
      expect(result).to match(/\A[0-9a-z]+\z/)
    end

    it 'handles unicode characters' do
      result = described_class.simple_hash('/Users/日本語/project')
      expect(result).to be_a(String)
      expect(result.length).to be > 0
    end
  end

  describe '.sanitize_path' do
    it 'replaces non-alphanumeric characters with hyphens' do
      expect(described_class.sanitize_path('/Users/test/project')).to eq('-Users-test-project')
    end

    it 'returns as-is when under 200 chars' do
      short_path = '/Users/test'
      result = described_class.sanitize_path(short_path)
      expect(result.length).to be <= 200
      expect(result).not_to include('/')
    end

    it 'appends hash suffix for paths over 200 chars' do
      long_path = "/Users/#{'a' * 300}/project"
      result = described_class.sanitize_path(long_path)
      expect(result.length).to be > 200
      expect(result).to match(/-[0-9a-z]+\z/)
    end
  end

  describe '.extract_json_string_field' do
    it 'extracts first occurrence by default' do
      text = '{"summary":"first"}\n{"summary":"second"}'
      expect(described_class.extract_json_string_field(text, 'summary')).to eq('first')
    end

    it 'extracts last occurrence when last: true' do
      text = '{"summary":"first"}\n{"summary":"second"}'
      expect(described_class.extract_json_string_field(text, 'summary', last: true)).to eq('second')
    end

    it 'handles escaped characters' do
      text = '{"title":"hello \\"world\\""}'
      expect(described_class.extract_json_string_field(text, 'title')).to eq('hello "world"')
    end

    it 'returns nil when field not found' do
      text = '{"other":"value"}'
      expect(described_class.extract_json_string_field(text, 'missing')).to be_nil
    end

    it 'handles spacing after colon' do
      text = '{"summary": "with space"}'
      expect(described_class.extract_json_string_field(text, 'summary')).to eq('with space')
    end
  end

  describe '.extract_first_prompt_from_head' do
    it 'extracts plain string content' do
      head = '{"type":"user","message":{"content":"Hello Claude"}}'
      expect(described_class.extract_first_prompt_from_head(head)).to eq('Hello Claude')
    end

    it 'extracts text from content blocks' do
      head = '{"type":"user","message":{"content":[{"type":"text","text":"Block text"}]}}'
      expect(described_class.extract_first_prompt_from_head(head)).to eq('Block text')
    end

    it 'skips tool_result lines' do
      lines = [
        '{"type":"user","message":{"content":"tool result"},"tool_result":true}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    it 'skips isMeta lines' do
      lines = [
        '{"type":"user","message":{"content":"meta"},"isMeta":true}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    it 'skips isCompactSummary lines' do
      lines = [
        '{"type":"user","message":{"content":"Summary of prior conversation"},"isCompactSummary":true}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    it 'skips session-start-hook content' do
      lines = [
        '{"type":"user","message":{"content":"<session-start-hook>stuff"}}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    it 'truncates long prompts to 200 chars with ellipsis' do
      long_text = 'x' * 300
      head = "{\"type\":\"user\",\"message\":{\"content\":\"#{long_text}\"}}"
      result = described_class.extract_first_prompt_from_head(head)
      expect(result.length).to eq(201) # 200 + ellipsis character
      expect(result).to end_with('…')
    end

    it 'returns empty string when no valid prompt found' do
      head = '{"type":"assistant","message":{"content":"Not a user message"}}'
      expect(described_class.extract_first_prompt_from_head(head)).to eq('')
    end

    it 'extracts command name as fallback' do
      head = '{"type":"user","message":{"content":"<command-name>commit</command-name>"}}'
      expect(described_class.extract_first_prompt_from_head(head)).to eq('commit')
    end
  end

  describe '.read_session_lite' do
    it 'reads a valid session file' do
      Dir.mktmpdir do |dir|
        session_id = '12345678-1234-1234-1234-123456789abc'
        file_path = File.join(dir, "#{session_id}.jsonl")
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'assistant', uuid: 'a1', message: { content: 'Hi!' } }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result).to be_a(ClaudeAgentSDK::SDKSessionInfo)
        expect(result.session_id).to eq(session_id)
        expect(result.first_prompt).to eq('Hello')
        expect(result.summary).to eq('Hello')
        expect(result.file_size).to be > 0
        expect(result.last_modified).to be > 0
      end
    end

    it 'returns nil for sidechain files' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, { type: 'user', isSidechain: true, message: { content: 'x' } }.to_json)

        expect(described_class.read_session_lite(file_path, '/test')).to be_nil
      end
    end

    it 'returns nil for empty files' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, '')

        expect(described_class.read_session_lite(file_path, '/test')).to be_nil
      end
    end

    it 'prefers customTitle as summary' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'system', uuid: 's1', customTitle: 'My Custom Title' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.summary).to eq('My Custom Title')
        expect(result.custom_title).to eq('My Custom Title')
      end
    end

    it 'extracts tag from {"type":"tag"} lines' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'tag', tag: 'experiment', sessionId: '12345678-1234-1234-1234-123456789abc' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.tag).to eq('experiment')
      end
    end

    it 'treats empty tag as cleared (nil)' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'tag', tag: 'first', sessionId: '12345678-1234-1234-1234-123456789abc' }.to_json,
          { type: 'tag', tag: '', sessionId: '12345678-1234-1234-1234-123456789abc' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.tag).to be_nil
      end
    end

    it 'returns nil tag when no tag lines exist' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json)

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.tag).to be_nil
      end
    end

    it 'extracts created_at from first entry ISO timestamp' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', timestamp: '2026-01-15T10:30:00Z',
            message: { content: 'Hello' } }.to_json,
          { type: 'assistant', uuid: 'a1', message: { content: 'Hi' } }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.created_at).to be_a(Integer)
        expect(result.created_at).to be > 0
        # 2026-01-15T10:30:00Z in epoch ms
        expected_ms = (Time.utc(2026, 1, 15, 10, 30, 0).to_f * 1000).to_i
        expect(result.created_at).to eq(expected_ms)
      end
    end

    it 'returns nil created_at when no timestamp in first entry' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json)

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.created_at).to be_nil
      end
    end

    it 'uses aiTitle as fallback for custom_title' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'system', uuid: 's1', aiTitle: 'AI Generated Title' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.custom_title).to eq('AI Generated Title')
        expect(result.summary).to eq('AI Generated Title')
      end
    end
  end

  describe '.read_sessions_from_dir' do
    it 'reads all valid session files from a directory' do
      Dir.mktmpdir do |dir|
        # Valid session file
        File.write(
          File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl'),
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json
        )
        # Another valid session file
        File.write(
          File.join(dir, 'abcdef01-2345-6789-abcd-ef0123456789.jsonl'),
          { type: 'user', uuid: 'u2', message: { content: 'World' } }.to_json
        )
        # Invalid filename (not UUID)
        File.write(File.join(dir, 'not-a-uuid.jsonl'), 'ignored')
        # Non-JSONL file
        File.write(File.join(dir, 'readme.txt'), 'ignored')

        sessions = described_class.read_sessions_from_dir(dir)
        expect(sessions.length).to eq(2)
        expect(sessions.map(&:session_id)).to contain_exactly(
          '12345678-1234-1234-1234-123456789abc',
          'abcdef01-2345-6789-abcd-ef0123456789'
        )
      end
    end

    it 'returns empty array for non-existent directory' do
      expect(described_class.read_sessions_from_dir('/nonexistent')).to eq([])
    end
  end

  describe '.list_sessions' do
    it 'returns empty array when no config dir exists' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect(described_class.list_sessions).to eq([])
    end

    it 'respects limit parameter' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        3.times do |i|
          uuid = "12345678-1234-1234-1234-12345678900#{i}"
          File.write(
            File.join(project_dir, "#{uuid}.jsonl"),
            { type: 'user', uuid: "u#{i}", message: { content: "Prompt #{i}" } }.to_json
          )
          # Ensure different mtimes
          FileUtils.touch(File.join(project_dir, "#{uuid}.jsonl"), mtime: Time.now + i)
        end

        sessions = described_class.list_sessions(limit: 2)
        expect(sessions.length).to eq(2)
      end
    end

    it 'sorts by last_modified descending' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        uuid_old = '12345678-1234-1234-1234-123456789000'
        uuid_new = '12345678-1234-1234-1234-123456789001'

        File.write(
          File.join(project_dir, "#{uuid_old}.jsonl"),
          { type: 'user', uuid: 'u1', message: { content: 'Old' } }.to_json
        )
        FileUtils.touch(File.join(project_dir, "#{uuid_old}.jsonl"), mtime: Time.now - 100)

        File.write(
          File.join(project_dir, "#{uuid_new}.jsonl"),
          { type: 'user', uuid: 'u2', message: { content: 'New' } }.to_json
        )

        sessions = described_class.list_sessions
        expect(sessions.first.session_id).to eq(uuid_new)
      end
    end

    it 'treats offset: nil the same as offset: 0' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect { described_class.list_sessions(offset: nil) }.not_to raise_error
    end
  end

  describe '.get_session_info' do
    it 'returns nil for invalid session_id' do
      expect(described_class.get_session_info(session_id: 'not-a-uuid')).to be_nil
    end

    it 'returns nil when session file not found' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect(described_class.get_session_info(session_id: '12345678-1234-1234-1234-123456789abc')).to be_nil
    end

    it 'finds a session by id in a specific directory' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        # Create a project dir matching the directory path
        dir_path = File.join(config_dir, 'testproject')
        FileUtils.mkdir_p(dir_path)
        sanitized = described_class.sanitize_path(File.realpath(dir_path).unicode_normalize(:nfc))
        project_dir = File.join(config_dir, 'projects', sanitized)
        FileUtils.mkdir_p(project_dir)

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          { type: 'user', uuid: 'u1', message: { content: 'Hello from info' } }.to_json
        )

        result = described_class.get_session_info(session_id: session_id, directory: dir_path)
        expect(result).to be_a(ClaudeAgentSDK::SDKSessionInfo)
        expect(result.session_id).to eq(session_id)
        expect(result.first_prompt).to eq('Hello from info')
      end
    end

    it 'finds a session by id across all project dirs' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-some-project')
        FileUtils.mkdir_p(project_dir)

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          { type: 'user', uuid: 'u1', message: { content: 'Found it' } }.to_json
        )

        result = described_class.get_session_info(session_id: session_id)
        expect(result).to be_a(ClaudeAgentSDK::SDKSessionInfo)
        expect(result.session_id).to eq(session_id)
        expect(result.first_prompt).to eq('Found it')
      end
    end

    it 'returns nil for sidechain sessions' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          { type: 'user', isSidechain: true, uuid: 'u1', message: { content: 'Side' } }.to_json
        )

        expect(described_class.get_session_info(session_id: session_id)).to be_nil
      end
    end
  end

  describe '.get_session_messages' do
    it 'returns empty for invalid session_id' do
      expect(described_class.get_session_messages(session_id: 'not-a-uuid')).to eq([])
    end

    it 'returns empty when session file not found' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect(described_class.get_session_messages(session_id: '12345678-1234-1234-1234-123456789abc')).to eq([])
    end

    it 'treats offset: nil the same as offset: 0' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect do
        described_class.get_session_messages(
          session_id: '12345678-1234-1234-1234-123456789abc',
          offset: nil
        )
      end.not_to raise_error
    end

    it 'parses a simple conversation' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        entries = [
          {
            type: 'user', uuid: 'msg-1', sessionId: session_id,
            message: { role: 'user', content: 'Hello' }
          },
          {
            type: 'assistant', uuid: 'msg-2', parentUuid: 'msg-1', sessionId: session_id,
            message: { role: 'assistant', content: [{ type: 'text', text: 'Hi!' }] }
          }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.length).to eq(2)
        expect(messages[0]).to be_a(ClaudeAgentSDK::SessionMessage)
        expect(messages[0].type).to eq('user')
        expect(messages[0].uuid).to eq('msg-1')
        expect(messages[1].type).to eq('assistant')
      end
    end

    it 'filters out sidechain messages' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        # Main chain: msg-1 → msg-2 → msg-3 (continues main)
        # Sidechain: msg-4 branches off msg-2
        entries = [
          { type: 'user', uuid: 'msg-1', sessionId: session_id, message: { content: 'Hello' } },
          { type: 'assistant', uuid: 'msg-2', parentUuid: 'msg-1', sessionId: session_id,
            message: { content: 'Hi' } },
          { type: 'user', uuid: 'msg-3', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'Follow up' } },
          { type: 'user', uuid: 'msg-4', parentUuid: 'msg-2', isSidechain: true,
            sessionId: session_id, message: { content: 'Side branch' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.length).to eq(3)
        expect(messages.map(&:uuid)).to eq(%w[msg-1 msg-2 msg-3])
        expect(messages.none? { |m| m.uuid == 'msg-4' }).to be true
      end
    end

    it 'filters out meta messages' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        entries = [
          { type: 'user', uuid: 'msg-1', sessionId: session_id, isMeta: true,
            message: { content: 'Meta' } },
          { type: 'user', uuid: 'msg-2', sessionId: session_id,
            message: { content: 'Real' } },
          { type: 'assistant', uuid: 'msg-3', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'Response' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.none? { |m| m.uuid == 'msg-1' }).to be true
      end
    end

    it 'handles circular parentUuid references without infinite loop' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        # msg-1 and msg-2 form a cycle, msg-3 is a terminal that leads into the cycle
        entries = [
          { type: 'user', uuid: 'msg-1', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'First' } },
          { type: 'assistant', uuid: 'msg-2', parentUuid: 'msg-1', sessionId: session_id,
            message: { content: 'Second' } },
          { type: 'system', uuid: 'msg-3', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'System' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        # Should not hang — returns some result without infinite looping
        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.length).to be <= 3
      end
    end

    it 'applies offset and limit' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        entries = [
          { type: 'user', uuid: 'msg-1', sessionId: session_id, message: { content: 'First' } },
          { type: 'assistant', uuid: 'msg-2', parentUuid: 'msg-1', sessionId: session_id,
            message: { content: 'Second' } },
          { type: 'user', uuid: 'msg-3', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'Third' } },
          { type: 'assistant', uuid: 'msg-4', parentUuid: 'msg-3', sessionId: session_id,
            message: { content: 'Fourth' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id, offset: 1, limit: 2)
        expect(messages.length).to eq(2)
        expect(messages[0].uuid).to eq('msg-2')
        expect(messages[1].uuid).to eq('msg-3')
      end
    end

    it 'keeps isCompactSummary messages visible' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        entries = [
          { type: 'user', uuid: 'compact-summary', sessionId: session_id,
            isCompactSummary: true, message: { content: 'Summary of prior conversation' } },
          { type: 'assistant', uuid: 'reply-1', parentUuid: 'compact-summary', sessionId: session_id,
            message: { content: 'Continuing from summary' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.length).to eq(2)
        expect(messages[0].uuid).to eq('compact-summary')
        expect(messages[1].uuid).to eq('reply-1')
      end
    end
  end
end

RSpec.describe ClaudeAgentSDK::SDKSessionInfo do
  it 'stores all fields including tag and created_at' do
    info = described_class.new(
      session_id: 'abc-123',
      summary: 'Test session',
      last_modified: 1_000_000,
      file_size: 4096,
      custom_title: 'My Title',
      first_prompt: 'Hello',
      git_branch: 'main',
      cwd: '/test',
      tag: 'experiment',
      created_at: 900_000
    )

    expect(info.session_id).to eq('abc-123')
    expect(info.summary).to eq('Test session')
    expect(info.last_modified).to eq(1_000_000)
    expect(info.file_size).to eq(4096)
    expect(info.custom_title).to eq('My Title')
    expect(info.first_prompt).to eq('Hello')
    expect(info.git_branch).to eq('main')
    expect(info.cwd).to eq('/test')
    expect(info.tag).to eq('experiment')
    expect(info.created_at).to eq(900_000)
  end

  it 'defaults file_size, tag, and created_at to nil' do
    info = described_class.new(session_id: 'x', summary: 's', last_modified: 0)
    expect(info.file_size).to be_nil
    expect(info.tag).to be_nil
    expect(info.created_at).to be_nil
  end
end

RSpec.describe ClaudeAgentSDK::SessionMessage do
  it 'stores message data' do
    msg = described_class.new(
      type: 'user',
      uuid: 'msg-1',
      session_id: 'sess-1',
      message: { 'role' => 'user', 'content' => 'Hello' }
    )

    expect(msg.type).to eq('user')
    expect(msg.uuid).to eq('msg-1')
    expect(msg.session_id).to eq('sess-1')
    expect(msg.message).to eq({ 'role' => 'user', 'content' => 'Hello' })
    expect(msg.parent_tool_use_id).to be_nil
  end
end

RSpec.describe 'ClaudeAgentSDK top-level session functions' do
  it 'delegates list_sessions to Sessions module' do
    expect(ClaudeAgentSDK::Sessions).to receive(:list_sessions)
      .with(directory: '/test', limit: 5, offset: 0, include_worktrees: false)
      .and_return([])

    ClaudeAgentSDK.list_sessions(directory: '/test', limit: 5, include_worktrees: false)
  end

  it 'delegates get_session_info to Sessions module' do
    expect(ClaudeAgentSDK::Sessions).to receive(:get_session_info)
      .with(session_id: 'abc', directory: '/test')
      .and_return(nil)

    ClaudeAgentSDK.get_session_info(session_id: 'abc', directory: '/test')
  end

  it 'delegates get_session_messages to Sessions module' do
    expect(ClaudeAgentSDK::Sessions).to receive(:get_session_messages)
      .with(session_id: 'abc', directory: nil, limit: nil, offset: 0)
      .and_return([])

    ClaudeAgentSDK.get_session_messages(session_id: 'abc')
  end
end
