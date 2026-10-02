# frozen_string_literal: true

require 'spec_helper'
require 'bundler'

RSpec.describe 'claude-agent-sdk.gemspec' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:gemspec_path) { File.join(root, 'claude-agent-sdk.gemspec') }

  def git_tracked_files
    IO.popen(%w[git ls-files -z lib sig docs README.md LICENSE CHANGELOG.md UPGRADING-1.0.md .yardopts],
             chdir: root, err: File::NULL, &:read).split("\x0")
      .reject { |path| path.start_with?('docs/history/') }
  rescue SystemCallError
    []
  end

  it 'packages the same files through the git-less fallback as through git ls-files' do
    tracked = git_tracked_files
    skip 'not a git checkout' if tracked.empty?

    # Simulate a host without git: the gemspec's `git ls-files` probe raises.
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, 'git')
    fallback = Bundler.load_gemspec_uncached(gemspec_path).files

    expect(fallback).to match_array(tracked)
  end

  it 'ships the RBS signatures under sig/, through git and without it' do
    from_git = Bundler.load_gemspec_uncached(gemspec_path).files
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, 'git')
    fallback = Bundler.load_gemspec_uncached(gemspec_path).files

    [from_git, fallback].each do |files|
      expect(files).to include('sig/claude_agent_sdk.rbs', 'sig/claude_agent_sdk/types/options.rbs')
    end
  end

  # rubydoc.info builds a gem's documentation from the packaged files. Without
  # .yardopts it runs YARD with its defaults: nothing tagged `@api private` is
  # hidden (the tag is this gem's SemVer boundary) and the extra files are not
  # rendered.
  it 'ships .yardopts, through git and without it' do
    from_git = Bundler.load_gemspec_uncached(gemspec_path).files
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, 'git')
    fallback = Bundler.load_gemspec_uncached(gemspec_path).files

    [from_git, fallback].each do |files|
      expect(files).to include('.yardopts')
    end
  end

  it 'packages every extra file .yardopts tells YARD to render' do
    # Everything after the lone `-` line is an extra file (README, CHANGELOG, ...).
    extra_files = File.readlines(File.join(root, '.yardopts'), chomp: true)
                      .drop_while { |line| line != '-' }.drop(1).reject(&:empty?)

    expect(extra_files).not_to be_empty
    expect(Bundler.load_gemspec_uncached(gemspec_path).files).to include(*extra_files)
  end
end
