# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# A project path longer than 200 sanitized characters is stored under its
# first 200 characters plus a hash of the whole path. Older CLIs hashed with
# Bun.hash, so when the exact name is missing the SDK looks for a directory
# with the same 200-character prefix — which every sibling path shares.
RSpec.describe 'project directory lookup for paths over 200 characters' do
  include_context 'with a Claude config dir'

  let(:session_id) { '6d7e8f90-a1b2-4c3d-8e4f-5a6b7c8d9e0f' }
  let(:tenant) { File.join(cwd, "tenant-#{'a' * 200}") }
  let(:project_a) { File.join(tenant, 'one').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:project_b) { File.join(tenant, 'two').tap { |dir| FileUtils.mkdir_p(dir) } }

  before { allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees) { |path| [path] } }

  def session_recorded_in(directory)
    transcript = CLITranscript.new(session_id: session_id, cwd: directory)
    transcript.queue_operations('the private question of project one')
    transcript.prompt(:prompt, 'the private question of project one')
    transcript.assistant(:answer, transcript.text('Answered.'), parent: :prompt)
    transcript.last_prompt('the private question of project one', leaf: :answer)
    transcript
  end

  # The name an older CLI gave the project dir of +directory+: same 200
  # characters, another hash.
  def old_cli_project_dir(directory, hash = 'bunhash1')
    name = ClaudeAgentSDK::Sessions.sanitize_path(directory)
    File.join(config_dir, 'projects', "#{name[0, 200]}-#{hash}")
  end

  context 'when a sibling project shares the first 200 characters' do
    let!(:transcript_a) { session_recorded_in(project_a).write(transcript_path(session_id, project_a)) }

    it 'has two different project keys with one prefix' do
      key_a = ClaudeAgentSDK.project_key_for_directory(project_a)
      key_b = ClaudeAgentSDK.project_key_for_directory(project_b)

      expect(key_a).not_to eq(key_b)
      expect(key_a[0, 201]).to eq(key_b[0, 201])
    end

    it 'does not list the sibling project for a directory without sessions' do
      expect(ClaudeAgentSDK.list_sessions(directory: project_b)).to eq([])
      expect(ClaudeAgentSDK.list_sessions(directory: project_a).map(&:session_id)).to eq([session_id])
    end

    it "does not read the sibling project's session through that directory" do
      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: project_b)).to be_nil
      expect(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: project_b)).to eq([])
    end

    it "does not write to the sibling project's session through that directory" do
      before_rename = File.binread(transcript_a)

      expect { ClaudeAgentSDK.rename_session(session_id: session_id, title: 'Mine now', directory: project_b) }
        .to raise_error(Errno::ENOENT)
      expect { ClaudeAgentSDK.delete_session(session_id: session_id, directory: project_b) }
        .to raise_error(Errno::ENOENT)
      expect(File.binread(transcript_a)).to eq(before_rename)
    end
  end

  context 'when an older CLI named the project dir with another hash' do
    it 'still finds it when a transcript in it records the directory as its cwd' do
      session_recorded_in(project_a).write(File.join(old_cli_project_dir(project_a), "#{session_id}.jsonl"))

      expect(ClaudeAgentSDK.list_sessions(directory: project_a).map(&:session_id)).to eq([session_id])
      expect(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: project_a).length).to eq(2)
    end

    it 'does not use a directory whose transcripts record no cwd' do
      transcript = CLITranscript.new(session_id: session_id, cwd: project_a)
      transcript.ai_title('Titled, with no entry that carries a cwd')
      transcript.last_prompt('the private question of project one')
      transcript.write(File.join(old_cli_project_dir(project_a), "#{session_id}.jsonl"))

      expect(ClaudeAgentSDK.list_sessions(directory: project_a)).to eq([])
    end

    it 'does not choose between two directories that both record the directory' do
      %w[bunhash1 bunhash2].each do |hash|
        session_recorded_in(project_a).write(File.join(old_cli_project_dir(project_a, hash), "#{session_id}.jsonl"))
      end

      expect(ClaudeAgentSDK.list_sessions(directory: project_a)).to eq([])
    end
  end
end
