# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'securerandom'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# list_sessions(directory:) covers the directory and every worktree of its
# repository. `git worktree list` reports worktree ROOTS, so a subdirectory
# (a monorepo package) is none of the paths it prints.
RSpec.describe 'list_sessions over git worktrees' do
  include_context 'with a Claude config dir'

  # One listed session recorded for +directory+: the CLI keeps it in the
  # project dir named after the canonical, NFC-normalized directory.
  def record_session(directory, prompt, session_id: SecureRandom.uuid)
    transcript = CLITranscript.new(session_id: session_id, cwd: directory)
    transcript.queue_operations(prompt)
    transcript.prompt(:prompt, prompt)
    transcript.assistant(:answer, transcript.text('Done.'), parent: :prompt)
    transcript.last_prompt(prompt, leaf: :answer)
    transcript.write(transcript_path(session_id, directory))
  end

  def summaries(directory, **)
    ClaudeAgentSDK.list_sessions(directory: directory, **).map(&:summary)
  end

  def git(repo, *)
    output, status = Open3.capture2e('git', '-C', repo, '-c', 'user.name=spec', '-c', 'user.email=spec@example.invalid',
                                     '-c', 'commit.gpgsign=false', *)
    raise "git #{[*].join(' ')} failed: #{output}" unless status.success?
  end

  let(:root) { File.join(cwd, 'repo').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:second) { File.join(cwd, 'repo-wt2').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:package) { File.join(root, 'packages', 'app').tap { |dir| FileUtils.mkdir_p(dir) } }

  context 'when the repository has two worktrees' do
    before do
      allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees).and_return([root, second])
      record_session(root, 'asked in the repository root')
      record_session(second, 'asked in the second worktree')
      record_session(package, 'asked in packages/app')
    end

    it "lists a subdirectory's own sessions along with those of every worktree" do
      expect(summaries(package)).to contain_exactly(
        'asked in packages/app', 'asked in the repository root', 'asked in the second worktree'
      )
    end

    it 'lists a worktree root as before' do
      expect(summaries(root)).to contain_exactly('asked in the repository root', 'asked in the second worktree')
    end

    it "lists only the directory's own sessions with include_worktrees: false" do
      expect(summaries(package, include_worktrees: false)).to eq(['asked in packages/app'])
    end
  end

  # The same session in two project dirs with equal mtime and size: the copy
  # recorded for the directory that was asked about is kept.
  it "keeps the directory's own copy of a session on an equal-rank duplicate" do
    main = File.join(cwd, 'repo-a').tap { |dir| FileUtils.mkdir_p(dir) }
    linked = File.join(cwd, 'repo-b').tap { |dir| FileUtils.mkdir_p(dir) }
    allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees).and_return([main, linked])
    session_id = '7c1e9d52-3a4b-4f60-8e21-0b9a8c7d6e5f'
    written = Time.utc(2026, 9, 8, 6, 0, 0)
    copies = { main => 'copy kept for repo-a', linked => 'copy kept for repo-b' }.map do |directory, prompt|
      record_session(directory, prompt, session_id: session_id).tap { |path| File.utime(written, written, path) }
    end

    expect(copies.map { |path| File.size(path) }.uniq.length).to eq(1)
    expect(summaries(linked)).to eq(['copy kept for repo-b'])
    expect(summaries(main)).to eq(['copy kept for repo-a'])
  end

  # No stub: a real `git worktree list --porcelain` over a real repository.
  context 'with a real repository' do
    # git takes GIT_DIR and friends from the environment (they are set while
    # a git hook runs the suite) and would then describe another repository.
    around do |example|
      saved = ENV.select { |name, _| name.start_with?('GIT_') }
      saved.each_key { |name| ENV.delete(name) }
      example.run
    ensure
      saved&.each { |name, value| ENV[name] = value }
    end

    before do
      git(root, 'init', '-q')
      git(root, 'commit', '-q', '--no-verify', '--allow-empty', '-m', 'init')
      git(root, 'worktree', 'add', '-q', '--detach', '--no-checkout', second)
      record_session(root, 'asked in the repository root')
      record_session(second, 'asked in the second worktree')
      record_session(package, 'asked in packages/app')
    end

    it 'lists a subdirectory with the sessions of both worktrees' do
      expect(summaries(package)).to contain_exactly(
        'asked in packages/app', 'asked in the repository root', 'asked in the second worktree'
      )
    end

    it 'lists the linked worktree with the sessions of the main one' do
      expect(summaries(second)).to contain_exactly('asked in the repository root', 'asked in the second worktree')
    end
  end
end
