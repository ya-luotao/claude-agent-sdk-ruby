# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'

RSpec.describe ClaudeAgentSDK::SessionMutations do
  let(:session_id) { '550e8400-e29b-41d4-a716-446655440000' }

  describe '.rename_session' do
    it 'rejects invalid UUID' do
      expect { described_class.rename_session(session_id: 'not-a-uuid', title: 'Test') }
        .to raise_error(ArgumentError, /Invalid session_id/)
    end

    it 'rejects empty title' do
      expect { described_class.rename_session(session_id: session_id, title: '') }
        .to raise_error(ArgumentError, /title must be non-empty/)
    end

    it 'rejects whitespace-only title' do
      expect { described_class.rename_session(session_id: session_id, title: '   ') }
        .to raise_error(ArgumentError, /title must be non-empty/)
    end

    it 'strips whitespace from title' do
      Dir.mktmpdir do |tmpdir|
        # Set up a fake project directory structure
        project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
        FileUtils.mkdir_p(project_dir)
        session_file = File.join(project_dir, "#{session_id}.jsonl")
        File.write(session_file, "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"hello\"}}\n")

        allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)

        described_class.rename_session(session_id: session_id, title: '  My Title  ', directory: tmpdir)

        lines = File.readlines(session_file)
        last_line = JSON.parse(lines.last.strip)
        expect(last_line['customTitle']).to eq('My Title')
      end
    end

    it 'appends correct JSONL format' do
      Dir.mktmpdir do |tmpdir|
        project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
        FileUtils.mkdir_p(project_dir)
        session_file = File.join(project_dir, "#{session_id}.jsonl")
        File.write(session_file, "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"hello\"}}\n")

        allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)

        described_class.rename_session(session_id: session_id, title: 'New Title', directory: tmpdir)

        lines = File.readlines(session_file)
        last_line = JSON.parse(lines.last.strip)
        expect(last_line['type']).to eq('custom-title')
        expect(last_line['customTitle']).to eq('New Title')
        expect(last_line['sessionId']).to eq(session_id)
      end
    end

    it 'raises when session file not found' do
      Dir.mktmpdir do |tmpdir|
        project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
        FileUtils.mkdir_p(project_dir)
        # No session file created

        allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)

        expect { described_class.rename_session(session_id: session_id, title: 'Test', directory: tmpdir) }
          .to raise_error(Errno::ENOENT, /not found/)
      end
    end
  end

  describe '.tag_session' do
    it 'appends correct JSONL with sanitized tag' do
      Dir.mktmpdir do |tmpdir|
        project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
        FileUtils.mkdir_p(project_dir)
        session_file = File.join(project_dir, "#{session_id}.jsonl")
        File.write(session_file, "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"hello\"}}\n")

        allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)

        described_class.tag_session(session_id: session_id, tag: 'experiment', directory: tmpdir)

        lines = File.readlines(session_file)
        last_line = JSON.parse(lines.last.strip)
        expect(last_line['type']).to eq('tag')
        expect(last_line['tag']).to eq('experiment')
        expect(last_line['sessionId']).to eq(session_id)
      end
    end

    it 'with nil tag appends empty-string tag entry' do
      Dir.mktmpdir do |tmpdir|
        project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
        FileUtils.mkdir_p(project_dir)
        session_file = File.join(project_dir, "#{session_id}.jsonl")
        File.write(session_file, "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"hello\"}}\n")

        allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)

        described_class.tag_session(session_id: session_id, tag: nil, directory: tmpdir)

        lines = File.readlines(session_file)
        last_line = JSON.parse(lines.last.strip)
        expect(last_line['type']).to eq('tag')
        expect(last_line['tag']).to eq('')
      end
    end

    it 'rejects tag that becomes empty after sanitization' do
      # Zero-width space only tag
      expect { described_class.tag_session(session_id: session_id, tag: "\u200b\u200c\u200d") }
        .to raise_error(ArgumentError, /tag must be non-empty/)
    end

    it 'rejects invalid UUID' do
      expect { described_class.tag_session(session_id: 'bad', tag: 'test') }
        .to raise_error(ArgumentError, /Invalid session_id/)
    end
  end

  describe '.sanitize_unicode (via tag_session)' do
    it 'strips zero-width chars, directional marks, BOM, private-use chars' do
      Dir.mktmpdir do |tmpdir|
        project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
        FileUtils.mkdir_p(project_dir)
        session_file = File.join(project_dir, "#{session_id}.jsonl")
        File.write(session_file, "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"hello\"}}\n")

        allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)

        # Tag with zero-width chars and BOM surrounding real text
        described_class.tag_session(
          session_id: session_id,
          tag: "\u200bhello\u200f\ufeffworld\ue000",
          directory: tmpdir
        )

        lines = File.readlines(session_file)
        last_line = JSON.parse(lines.last.strip)
        expect(last_line['tag']).to eq('helloworld')
      end
    end
  end

  describe '.try_append' do
    it 'returns false for nonexistent files' do
      result = described_class.send(:try_append, '/nonexistent/path/file.jsonl', 'data')
      expect(result).to eq(false)
    end

    it 'returns false for zero-byte files' do
      Dir.mktmpdir do |tmpdir|
        file_path = File.join(tmpdir, 'empty.jsonl')
        File.write(file_path, '')

        result = described_class.send(:try_append, file_path, 'data')
        expect(result).to eq(false)
      end
    end

    it 'returns true and appends for valid files' do
      Dir.mktmpdir do |tmpdir|
        file_path = File.join(tmpdir, 'test.jsonl')
        File.write(file_path, "existing content\n")

        result = described_class.send(:try_append, file_path, "new line\n")
        expect(result).to eq(true)
        expect(File.read(file_path)).to eq("existing content\nnew line\n")
      end
    end
  end

  describe '.delete_session' do
    it 'rejects invalid UUID' do
      expect { described_class.delete_session(session_id: 'not-a-uuid') }
        .to raise_error(ArgumentError, /Invalid session_id/)
    end

    it 'deletes an existing session file' do
      Dir.mktmpdir do |tmpdir|
        project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
        FileUtils.mkdir_p(project_dir)
        session_file = File.join(project_dir, "#{session_id}.jsonl")
        File.write(session_file, "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"content\":\"hello\"}}\n")

        allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)

        described_class.delete_session(session_id: session_id, directory: tmpdir)
        expect(File.exist?(session_file)).to be false
      end
    end

    it 'raises when session not found' do
      Dir.mktmpdir do |tmpdir|
        project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
        FileUtils.mkdir_p(project_dir)

        allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)

        expect { described_class.delete_session(session_id: session_id, directory: tmpdir) }
          .to raise_error(Errno::ENOENT, /not found/)
      end
    end
  end

  describe '.fork_session' do
    let(:msg1_uuid) { '11111111-1111-1111-1111-111111111111' }
    let(:msg2_uuid) { '22222222-2222-2222-2222-222222222222' }
    let(:msg3_uuid) { '33333333-3333-3333-3333-333333333333' }

    def build_session_content(entries)
      "#{entries.map { |e| JSON.generate(e) }.join("\n")}\n"
    end

    def setup_session(tmpdir, content)
      project_dir = File.join(tmpdir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(File.realpath(tmpdir)))
      FileUtils.mkdir_p(project_dir)
      session_file = File.join(project_dir, "#{session_id}.jsonl")
      File.write(session_file, content)
      allow(ClaudeAgentSDK::Sessions).to receive(:config_dir).and_return(tmpdir)
      [project_dir, session_file]
    end

    it 'rejects invalid session_id' do
      expect { described_class.fork_session(session_id: 'bad') }
        .to raise_error(ArgumentError, /Invalid session_id/)
    end

    it 'rejects invalid up_to_message_id' do
      expect { described_class.fork_session(session_id: session_id, up_to_message_id: 'bad') }
        .to raise_error(ArgumentError, /Invalid up_to_message_id/)
    end

    it 'tolerates non-UTF-8 bytes in the session file' do
      Dir.mktmpdir do |tmpdir|
        entry = { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil,
                  'message' => { 'content' => 'hello' } }
        # Embed an invalid UTF-8 byte (0xFF) alongside valid JSONL entries.
        content = "#{JSON.generate(entry)}\n".b + "\xFF\n".b
        setup_session(tmpdir, content)

        expect do
          described_class.fork_session(session_id: session_id, directory: tmpdir)
        end.not_to raise_error
      end
    end

    it 'forks a session with UUID remapping' do
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'message' => { 'content' => 'hello' } },
                                          { 'type' => 'assistant', 'uuid' => msg2_uuid, 'parentUuid' => msg1_uuid, 'message' => { 'content' => 'hi' } }
                                        ])
        project_dir, = setup_session(tmpdir, content)

        result = described_class.fork_session(session_id: session_id, directory: tmpdir)
        expect(result).to be_a(ClaudeAgentSDK::ForkSessionResult)
        expect(result.session_id).to match(ClaudeAgentSDK::Sessions::UUID_RE)
        expect(result.session_id).not_to eq(session_id)

        fork_file = File.join(project_dir, "#{result.session_id}.jsonl")
        expect(File.exist?(fork_file)).to be true

        lines = File.readlines(fork_file).map { |l| JSON.parse(l.strip) }
        message_lines = lines.reject { |l| l['type'] == 'custom-title' }

        # UUIDs should be remapped
        expect(message_lines[0]['uuid']).not_to eq(msg1_uuid)
        expect(message_lines[1]['uuid']).not_to eq(msg2_uuid)

        # parentUuid chain should be remapped
        expect(message_lines[1]['parentUuid']).to eq(message_lines[0]['uuid'])

        # sessionId should be the new fork's ID
        expect(message_lines[0]['sessionId']).to eq(result.session_id)

        # forkedFrom should reference original
        expect(message_lines[0]['forkedFrom']['sessionId']).to eq(session_id)
        expect(message_lines[0]['forkedFrom']['messageUuid']).to eq(msg1_uuid)
      end
    end

    it 'truncates at up_to_message_id' do
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'message' => { 'content' => 'hello' } },
                                          { 'type' => 'assistant', 'uuid' => msg2_uuid, 'parentUuid' => msg1_uuid, 'message' => { 'content' => 'hi' } },
                                          { 'type' => 'user', 'uuid' => msg3_uuid, 'parentUuid' => msg2_uuid, 'message' => { 'content' => 'bye' } }
                                        ])
        setup_session(tmpdir, content)

        result = described_class.fork_session(session_id: session_id, directory: tmpdir, up_to_message_id: msg2_uuid)
        fork_file = File.join(File.dirname(Dir.glob(File.join(tmpdir, 'projects', '**', "#{result.session_id}.jsonl")).first))
        lines = File.readlines(File.join(fork_file, "#{result.session_id}.jsonl")).map { |l| JSON.parse(l.strip) }
        message_lines = lines.reject { |l| l['type'] == 'custom-title' }

        expect(message_lines.size).to eq(2)
      end
    end

    it 'raises when up_to_message_id not found' do
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'message' => { 'content' => 'hello' } }
                                        ])
        setup_session(tmpdir, content)

        expect { described_class.fork_session(session_id: session_id, directory: tmpdir, up_to_message_id: msg3_uuid) }
          .to raise_error(ArgumentError, /not found in session/)
      end
    end

    it 'filters out sidechain entries' do
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'isSidechain' => false,
                                            'message' => { 'content' => 'hello' } },
                                          { 'type' => 'assistant', 'uuid' => msg2_uuid, 'parentUuid' => msg1_uuid, 'isSidechain' => true,
                                            'message' => { 'content' => 'sidechain' } },
                                          { 'type' => 'assistant', 'uuid' => msg3_uuid, 'parentUuid' => msg1_uuid, 'isSidechain' => false,
                                            'message' => { 'content' => 'main' } }
                                        ])
        project_dir, = setup_session(tmpdir, content)

        result = described_class.fork_session(session_id: session_id, directory: tmpdir)
        fork_file = File.join(project_dir, "#{result.session_id}.jsonl")
        lines = File.readlines(fork_file).map { |l| JSON.parse(l.strip) }
        message_lines = lines.reject { |l| l['type'] == 'custom-title' }

        expect(message_lines.size).to eq(2)
        original_uuids = message_lines.map { |l| l['forkedFrom']['messageUuid'] }
        expect(original_uuids).to eq([msg1_uuid, msg3_uuid])
      end
    end

    it 'excludes progress entries from output but uses them for parentUuid chain' do
      progress_uuid = '44444444-4444-4444-4444-444444444444'
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'message' => { 'content' => 'hello' } },
                                          { 'type' => 'progress', 'uuid' => progress_uuid, 'parentUuid' => msg1_uuid },
                                          { 'type' => 'assistant', 'uuid' => msg2_uuid, 'parentUuid' => progress_uuid,
                                            'message' => { 'content' => 'hi' } }
                                        ])
        project_dir, = setup_session(tmpdir, content)

        result = described_class.fork_session(session_id: session_id, directory: tmpdir)
        fork_file = File.join(project_dir, "#{result.session_id}.jsonl")
        lines = File.readlines(fork_file).map { |l| JSON.parse(l.strip) }
        message_lines = lines.reject { |l| l['type'] == 'custom-title' }

        # Progress entry should not appear in output
        expect(message_lines.size).to eq(2)
        # The assistant's parentUuid should skip progress and point to the user message
        expect(message_lines[1]['parentUuid']).to eq(message_lines[0]['uuid'])
      end
    end

    it 'forwards content-replacement entries' do
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'message' => { 'content' => 'hello' } },
                                          { 'type' => 'content-replacement', 'uuid' => msg2_uuid, 'sessionId' => session_id,
                                            'replacements' => [{ 'old' => 'foo', 'new' => 'bar' }] }
                                        ])
        project_dir, = setup_session(tmpdir, content)

        result = described_class.fork_session(session_id: session_id, directory: tmpdir)
        fork_file = File.join(project_dir, "#{result.session_id}.jsonl")
        lines = File.readlines(fork_file).map { |l| JSON.parse(l.strip) }
        cr_lines = lines.select { |l| l['type'] == 'content-replacement' }

        expect(cr_lines.size).to eq(1)
        expect(cr_lines[0]['sessionId']).to eq(result.session_id)
        expect(cr_lines[0]['replacements']).to eq([{ 'old' => 'foo', 'new' => 'bar' }])
      end
    end

    it 'uses custom title when provided' do
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'message' => { 'content' => 'hello' } }
                                        ])
        project_dir, = setup_session(tmpdir, content)

        result = described_class.fork_session(session_id: session_id, directory: tmpdir, title: 'My Fork')
        fork_file = File.join(project_dir, "#{result.session_id}.jsonl")
        lines = File.readlines(fork_file).map { |l| JSON.parse(l.strip) }
        title_line = lines.find { |l| l['type'] == 'custom-title' }

        expect(title_line['customTitle']).to eq('My Fork')
      end
    end

    it 'auto-generates title with (fork) suffix when no title given' do
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'message' => { 'content' => 'hello' } }
                                        ])
        project_dir, = setup_session(tmpdir, content)

        result = described_class.fork_session(session_id: session_id, directory: tmpdir)
        fork_file = File.join(project_dir, "#{result.session_id}.jsonl")
        lines = File.readlines(fork_file).map { |l| JSON.parse(l.strip) }
        title_line = lines.find { |l| l['type'] == 'custom-title' }

        expect(title_line['customTitle']).to end_with('(fork)')
      end
    end

    it 'preserves logicalParentUuid when target is outside truncated range' do
      outside_uuid = '99999999-9999-9999-9999-999999999999'
      Dir.mktmpdir do |tmpdir|
        content = build_session_content([
                                          { 'type' => 'user', 'uuid' => msg1_uuid, 'parentUuid' => nil, 'logicalParentUuid' => outside_uuid,
                                            'message' => { 'content' => 'hello' } }
                                        ])
        project_dir, = setup_session(tmpdir, content)

        result = described_class.fork_session(session_id: session_id, directory: tmpdir)
        fork_file = File.join(project_dir, "#{result.session_id}.jsonl")
        lines = File.readlines(fork_file).map { |l| JSON.parse(l.strip) }
        message_lines = lines.reject { |l| l['type'] == 'custom-title' }

        # Should preserve the original UUID when mapping misses, not null it
        expect(message_lines[0]['logicalParentUuid']).to eq(outside_uuid)
      end
    end
  end

  describe 'top-level delegates' do
    it 'ClaudeAgentSDK.rename_session delegates to SessionMutations' do
      expect(described_class).to receive(:rename_session)
        .with(session_id: session_id, title: 'Test', directory: nil)
      ClaudeAgentSDK.rename_session(session_id: session_id, title: 'Test')
    end

    it 'ClaudeAgentSDK.tag_session delegates to SessionMutations' do
      expect(described_class).to receive(:tag_session)
        .with(session_id: session_id, tag: 'test', directory: nil)
      ClaudeAgentSDK.tag_session(session_id: session_id, tag: 'test')
    end

    it 'ClaudeAgentSDK.delete_session delegates to SessionMutations' do
      expect(described_class).to receive(:delete_session)
        .with(session_id: session_id, directory: nil)
      ClaudeAgentSDK.delete_session(session_id: session_id)
    end

    it 'ClaudeAgentSDK.fork_session delegates to SessionMutations' do
      expect(described_class).to receive(:fork_session)
        .with(session_id: session_id, directory: nil, up_to_message_id: nil, title: nil)
        .and_return(ClaudeAgentSDK::ForkSessionResult.new(session_id: 'new-id'))
      ClaudeAgentSDK.fork_session(session_id: session_id)
    end
  end
end
