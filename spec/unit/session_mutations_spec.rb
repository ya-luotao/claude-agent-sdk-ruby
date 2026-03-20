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
  end
end
