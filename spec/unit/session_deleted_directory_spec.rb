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

  # The session was recorded through a symlinked project directory, so the CLI
  # keyed it by the link's target. The target is gone; the link is still
  # there, pointing at nothing.
  context 'when the directory is a symlink whose target was removed' do
    let(:target) { File.join(cwd, 'checkouts', 'project') }
    let(:link) { File.join(cwd, 'current') }

    before do
      FileUtils.mkdir_p(target)
      File.symlink(target, link)
      record_session(link)
      FileUtils.rm_rf(target)
    end

    it 'is found by the readers through the link' do
      expect(File.symlink?(link) && !File.exist?(link)).to be(true)
      expect(ClaudeAgentSDK.list_sessions(directory: link).map(&:session_id)).to eq([session_id])
      expect(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: link).length).to eq(2)
    end

    it 'can be renamed through the link' do
      ClaudeAgentSDK.rename_session(session_id: session_id, title: 'Old checkout', directory: link)

      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: link).custom_title)
        .to eq('Old checkout')
    end

    it 'has the project key of the former target, also through a relative link' do
      relative = File.join(cwd, 'relative')
      File.symlink(File.join('checkouts', 'project'), relative)

      expect(ClaudeAgentSDK.project_key_for_directory(link)).to eq(ClaudeAgentSDK::Sessions.sanitize_path(target))
      expect(ClaudeAgentSDK.project_key_for_directory(File.join(relative, 'packages', 'app')))
        .to eq(ClaudeAgentSDK::Sessions.sanitize_path(File.join(target, 'packages', 'app')))
    end
  end

  # The session was recorded through `current/../sibling` while the target of
  # `current` existed. A link is followed before the `..` after it is applied,
  # so that is the sibling of the TARGET (checkouts/sibling), not of the link
  # — and the link, still there, says so after its target is gone.
  #
  # The expected directory is what Python's os.path.realpath returns for this
  # layout once checkouts/project is removed. Obtained by hand, not by the
  # suite (Python 3.11.13 on macOS):
  #   python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' <path>
  # printed <cwd>/checkouts/sibling for <cwd>/current/../sibling,
  # <cwd>/relative/../sibling, <cwd>/via-target and
  # <cwd>/gone/../checkouts/sibling, and for the relative current/../sibling
  # (run in <cwd>) and ../../current/../sibling (run in <cwd>/checkouts/sibling).
  context 'when the path goes up from a symlink whose target was removed' do
    let(:target) { File.join(cwd, 'checkouts', 'project') }
    let(:sibling) { File.join(cwd, 'checkouts', 'sibling') }
    let(:link) { File.join(cwd, 'current') }
    let(:through) { File.join(link, '..', 'sibling') }
    let(:sibling_key) { ClaudeAgentSDK::Sessions.sanitize_path(sibling) }

    # The project key of the path while the target existed. Then the target
    # goes; checkouts/sibling, where the session was recorded, stays.
    let!(:recorded_key) do
      FileUtils.mkdir_p(target)
      File.symlink(target, link)
      record_session(through)
      ClaudeAgentSDK.project_key_for_directory(through).tap { FileUtils.rm_rf(target) }
    end

    it 'keeps the project key it had while the target existed' do
      expect(File.symlink?(link) && !File.exist?(link)).to be(true)
      expect(recorded_key).to eq(sibling_key)
      expect(ClaudeAgentSDK.project_key_for_directory(through)).to eq(sibling_key)
    end

    it 'is found by the readers' do
      expect(ClaudeAgentSDK.list_sessions(directory: through).map(&:session_id)).to eq([session_id])
      expect(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: through).length).to eq(2)
    end

    it 'can be renamed' do
      ClaudeAgentSDK.rename_session(session_id: session_id, title: 'Sibling checkout', directory: through)

      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: through).custom_title)
        .to eq('Sibling checkout')
    end

    it 'goes up from the target of a relative link, and of a link another link names' do
      File.symlink(File.join('checkouts', 'project'), File.join(cwd, 'relative'))
      File.symlink(File.join('current', '..', 'sibling'), File.join(cwd, 'via-target'))

      expect(ClaudeAgentSDK.project_key_for_directory(File.join(cwd, 'relative', '..', 'sibling'))).to eq(sibling_key)
      expect(ClaudeAgentSDK.project_key_for_directory(File.join(cwd, 'via-target'))).to eq(sibling_key)
    end

    it 'goes up from a directory that is simply missing by its name' do
      expect(ClaudeAgentSDK.project_key_for_directory(File.join(cwd, 'gone', '..', 'checkouts', 'sibling')))
        .to eq(sibling_key)
    end

    it 'resolves the path alike when it is given relative to the working directory' do
      Dir.chdir(cwd) do
        relative = File.join('current', '..', 'sibling')

        expect(ClaudeAgentSDK.project_key_for_directory(relative)).to eq(sibling_key)
        expect(ClaudeAgentSDK.list_sessions(directory: relative).map(&:session_id)).to eq([session_id])
      end
      Dir.chdir(sibling) do
        expect(ClaudeAgentSDK.project_key_for_directory(File.join('..', '..', 'current', '..', 'sibling')))
          .to eq(sibling_key)
      end
    end
  end

  # File.realpath does not expand a leading ~, so a directory named with one
  # is resolved as a missing path whether it exists or not.
  context 'when the directory is named with a leading ~' do
    let(:home) { File.join(cwd, 'home') }

    around do |example|
      previous_home = ENV.fetch('HOME', nil) # rubocop:disable Style/EnvHome -- raw value; nil when unset
      ENV['HOME'] = home
      example.run
    ensure
      previous_home.nil? ? ENV.delete('HOME') : (ENV['HOME'] = previous_home)
    end

    it 'names the directory under the home directory, removed or not' do
      record_session(File.join(home, 'project'))

      expect(ClaudeAgentSDK.list_sessions(directory: '~/project').map(&:session_id)).to eq([session_id])
      FileUtils.rm_rf(File.join(home, 'project'))
      expect(ClaudeAgentSDK.list_sessions(directory: '~/project').map(&:session_id)).to eq([session_id])
      expect(ClaudeAgentSDK.project_key_for_directory('~/gone/../project'))
        .to eq(ClaudeAgentSDK::Sessions.sanitize_path(File.join(home, 'project')))
      expect(ClaudeAgentSDK.project_key_for_directory('~')).to eq(ClaudeAgentSDK::Sessions.sanitize_path(home))
    end
  end

  it 'resolves a missing path under symlinks that point at each other without looping' do
    one = File.join(cwd, 'one')
    two = File.join(cwd, 'two')
    File.symlink(two, one)
    File.symlink(one, two)

    expect(ClaudeAgentSDK.list_sessions(directory: File.join(one, 'project'))).to eq([])
  end

  it 'reports a directory that never held the session as a missing session' do
    typo = File.join(cwd, 'no-such-project')

    expect { ClaudeAgentSDK.rename_session(session_id: session_id, title: 'x', directory: typo) }
      .to raise_error(Errno::ENOENT, /Session #{session_id} not found in project directory/)
    expect { ClaudeAgentSDK.delete_session(session_id: session_id, directory: typo) }
      .to raise_error(Errno::ENOENT, /Session #{session_id} not found in project directory/)
  end
end
