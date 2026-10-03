# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'tmpdir'
require 'fileutils'

# ClaudeAgentOptions#cli_path is signed `(String | Pathname)?`, and
# `Rails.root.join('vendor/claude/claude')` is the obvious value to pass.
# The version probe stringified it; the spawn did not. Real spawns here: an
# argv assertion alone would not have caught the TypeError.
RSpec.describe ClaudeAgentSDK::SubprocessCLITransport, 'cli_path given as a Pathname' do
  after { described_class.active_processes.clear }

  around do |example|
    previous = ENV.fetch('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK', nil)
    ENV.delete('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK')
    Dir.mktmpdir('cli-pathname-spec') do |dir|
      @root = File.realpath(dir)
      example.run
    end
  ensure
    ENV['CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'] = previous if previous
  end

  # The fake answers `-v` at once, but on a starved machine "at once" can
  # exceed the probe's 2 s deadline, which would drop the probe's marker line.
  before { stub_const("#{described_class}::VERSION_CHECK_TIMEOUT_SECONDS", 60) }

  attr_reader :root

  def marker = File.join(root, 'legs')

  # Records the version probe (`-v`) and the session spawn separately.
  def install_fake_cli(relative_path)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "-v" ]; then
        echo 'probe' >> '#{marker}'
        echo '2.1.286 (Claude Code)'
        exit 0
      fi
      echo 'spawn' >> '#{marker}'
    SH
    File.chmod(0o755, path)
    path
  end

  def run_session(transport)
    transport.connect
    transport.read_messages { |_frame| nil }
    File.readlines(marker, chomp: true)
  ensure
    transport.close
  end

  it 'spawns the CLI an absolute Pathname names' do
    cli = Pathname.new(install_fake_cli('bin/claude'))
    transport = described_class.new(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: cli))

    expect(run_session(transport)).to eq(%w[probe spawn])
  end

  it 'resolves a relative Pathname like a relative String: against the process cwd' do
    install_fake_cli('app/bin/claude')
    FileUtils.mkdir_p(File.join(root, 'target'))
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      cli_path: Pathname.new('bin/claude'), cwd: Pathname.new(File.join(root, 'target'))
    )

    legs = Dir.chdir(File.join(root, 'app')) { run_session(described_class.new(options)) }

    expect(legs).to eq(%w[probe spawn])
  end

  it 'hands CommandBuilder a String' do
    cli = install_fake_cli('bin/claude')
    transport = described_class.new(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: Pathname.new(cli)))

    expect(transport.build_command.first).to be_a(String).and eq(cli)
  end
end
