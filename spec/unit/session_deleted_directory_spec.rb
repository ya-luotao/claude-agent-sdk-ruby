# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# The CLI keys a project by its path, so the transcripts outlive the
# directory: after `rm -rf <worktree>` its sessions are still there to list,
# read, and clean up.
RSpec.describe 'sessions of a project directory that no longer exists' do
  include_context 'with a Claude config dir'

  let(:session_id) { '2b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091' }

  before { allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees) { |path| [path] } }

  # A session the CLI recorded while +directory+ existed: keyed by the
  # directory's real path.
  def record_session(directory)
    FileUtils.mkdir_p(directory)
    real = File.realpath(directory)
    transcript = CLITranscript.new(session_id: session_id, cwd: real)
    transcript.queue_operations('clean up the old worktree')
    transcript.prompt(:prompt, 'clean up the old worktree')
    transcript.assistant(:answer, transcript.text('Done.'), parent: :prompt)
    transcript.last_prompt('clean up the old worktree', leaf: :answer)
    transcript.write(transcript_path(session_id, real))
  end

  context 'when the directory was removed' do
    let(:removed) { File.join(cwd, 'removed-worktree') }
    let!(:transcript_file) { record_session(removed).tap { FileUtils.rm_rf(removed) } }

    it 'is still found by the readers' do
      expect(ClaudeAgentSDK.list_sessions(directory: removed).map(&:session_id)).to eq([session_id])
      expect(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: removed).length).to eq(2)
    end

    it 'can be renamed through the directory' do
      ClaudeAgentSDK.rename_session(session_id: session_id, title: 'Old worktree', directory: removed)

      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: removed).custom_title)
        .to eq('Old worktree')
    end

    it 'can be tagged through the directory' do
      ClaudeAgentSDK.tag_session(session_id: session_id, tag: 'stale', directory: removed)

      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: removed).tag).to eq('stale')
    end

    it 'can be forked through the directory' do
      fork = ClaudeAgentSDK.fork_session(session_id: session_id, directory: removed)

      expect(ClaudeAgentSDK.get_session_messages(session_id: fork.session_id, directory: removed).length).to eq(2)
    end

    it 'can be deleted through the directory' do
      ClaudeAgentSDK.delete_session(session_id: session_id, directory: removed)

      expect(File.exist?(transcript_file)).to be(false)
    end
  end

  # The CLI recorded the real path; the caller names the directory through a
  # symlink (macOS /tmp and /var are symlinks). With the directory gone there
  # is nothing left to resolve at the end of the path, only above it.
  context 'when the removed directory is named through a symlinked parent' do
    let(:real_parent) { File.join(cwd, 'volumes', 'data').tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:link) { File.join(cwd, 'data').tap { |path| File.symlink(real_parent, path) } }
    let(:removed) { File.join(link, 'removed-worktree') }

    before { record_session(removed).tap { FileUtils.rm_rf(removed) } }

    it 'is found by the readers' do
      expect(ClaudeAgentSDK.list_sessions(directory: removed).map(&:session_id)).to eq([session_id])
      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: removed)&.summary)
        .to eq('clean up the old worktree')
      expect(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: removed).length).to eq(2)
    end

    it 'can be renamed through the directory' do
      ClaudeAgentSDK.rename_session(session_id: session_id, title: 'Old worktree', directory: removed)

      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: removed).custom_title)
        .to eq('Old worktree')
    end

    it 'has the project key the directory had while it existed' do
      expect(ClaudeAgentSDK.project_key_for_directory(removed))
        .to eq(ClaudeAgentSDK::Sessions.sanitize_path(File.join(real_parent, 'removed-worktree')))
    end
  end

  it 'reports a directory that never held the session as a missing session' do
    typo = File.join(cwd, 'no-such-project')

    expect { ClaudeAgentSDK.rename_session(session_id: session_id, title: 'x', directory: typo) }
      .to raise_error(Errno::ENOENT, /Session #{session_id} not found in project directory/)
    expect { ClaudeAgentSDK.delete_session(session_id: session_id, directory: typo) }
      .to raise_error(Errno::ENOENT, /Session #{session_id} not found in project directory/)
  end
end
