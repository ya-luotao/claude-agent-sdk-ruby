# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# The version probe runs in the process's working directory; the session is
# spawned with `chdir: options.cwd`. A CLI path that is still relative when
# it reaches the spawn names one file for the probe and another for the
# session — whatever sits at that path inside the directory the agent was
# pointed at (CWE-427). These examples run real executables: every fake
# `claude` appends "<leg>:<its own path>" to a marker file, so the assertions
# are about which FILE ran for which leg, not about what Open3 was handed.
RSpec.describe ClaudeAgentSDK::SubprocessCLITransport, 'CLI path resolution' do
  after { described_class.active_processes.clear }

  # `app` is the process cwd, `target` is options.cwd. Canonicalized: the
  # macOS tmpdir lives behind the /var symlink, and Dir.pwd reports the
  # resolved path.
  around do |example|
    Dir.mktmpdir('cli-path-spec') do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p([app, target])
      with_env('CLAUDE_CLI_PATH' => nil, 'CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK' => nil) { example.run }
    end
  end

  # Keep a vendored binary (CLIInstaller.root may point anywhere on a
  # developer machine) out of the discovery examples; `which` is real.
  before { allow(ClaudeAgentSDK::CLIInstaller).to receive(:installed_path).and_return(nil) }

  attr_reader :root

  def app = File.join(root, 'app')
  def target = File.join(root, 'target')
  def marker = File.join(root, 'legs')

  def with_env(changes)
    previous = changes.to_h { |key, _| [key, ENV.fetch(key, nil)] }
    changes.each { |key, value| value.nil? ? ENV.delete(key) : (ENV[key] = value) }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : (ENV[key] = value) }
  end

  # PATH with +entry+ in front of whatever the host has.
  def path_with(entry)
    "#{entry}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"
  end

  # A stand-in `claude` at +relative_path+ under the tmp root. `-v` is the
  # SDK's version probe; anything else is the session spawn.
  def install_fake_cli(relative_path)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "-v" ]; then
        echo 'probe:#{relative_path}' >> '#{marker}'
        echo '2.1.286 (Claude Code)'
        exit 0
      fi
      echo 'spawn:#{relative_path}' >> '#{marker}'
    SH
    File.chmod(0o755, path)
    path
  end

  def options(**values)
    ClaudeAgentSDK::ClaudeAgentOptions.new(cwd: target, **values)
  end

  def legs
    File.exist?(marker) ? File.readlines(marker, chomp: true) : []
  end

  # Construct and connect from the process cwd, then read to EOF: the fake
  # has exited, so both legs are on record.
  def legs_executed(**values)
    Dir.chdir(app) do
      transport = described_class.new(options(**values))
      begin
        transport.connect
        transport.read_messages { |_frame| nil }
      ensure
        transport.close
      end
    end
    legs
  end

  describe 'an explicit cli_path' do
    it 'resolves a relative path against the process cwd, for the probe and the spawn' do
      install_fake_cli('app/bin/claude')
      install_fake_cli('target/bin/claude')

      expect(legs_executed(cli_path: 'bin/claude')).to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
    end

    it 'leaves an absolute path alone' do
      cli = install_fake_cli('app/bin/claude')
      install_fake_cli('target/bin/claude')

      expect(legs_executed(cli_path: cli)).to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
    end

    it 'expands a leading ~ to the home directory, like CLAUDE_CLI_PATH' do
      install_fake_cli('app/bin/claude')

      with_env('HOME' => app) do
        expect(legs_executed(cli_path: '~/bin/claude')).to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
      end
    end

    it 'reports a missing file as CLINotFoundError at connect, not at construction' do
      install_fake_cli('target/bin/missing')
      transport = Dir.chdir(app) { described_class.new(options(cli_path: 'bin/missing')) }

      expect { Dir.chdir(app) { transport.connect } }
        .to raise_error(ClaudeAgentSDK::CLINotFoundError, %r{Claude Code not found at: .*bin/missing})
      expect(legs).to be_empty
    end

    it 'reports a ~user path it cannot expand as CLINotFoundError at connect' do
      transport = Dir.chdir(app) { described_class.new(options(cli_path: '~no-such-user-for-this-spec/bin/claude')) }

      expect { Dir.chdir(app) { transport.connect } }.to raise_error(ClaudeAgentSDK::CLINotFoundError)
    end
  end

  describe 'an explicit bare name' do
    it 'is found through a relative PATH entry in the process cwd, for the probe and the spawn' do
      install_fake_cli('app/bin/claude')
      install_fake_cli('target/bin/claude')

      with_env('PATH' => path_with('bin')) do
        expect(legs_executed(cli_path: 'claude')).to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
      end
    end

    it 'treats `.` and an empty PATH entry as the process cwd' do
      install_fake_cli('app/claude')
      install_fake_cli('target/claude')

      aggregate_failures do
        ['.', ''].each do |entry|
          FileUtils.rm_f(marker)
          with_env('PATH' => path_with(entry)) do
            expect(legs_executed(cli_path: 'claude')).to eq(%w[probe:app/claude spawn:app/claude]),
                                                         "PATH entry #{entry.inspect}: #{legs.inspect}"
          end
        end
      end
    end

    it 'treats a trailing empty PATH entry as the process cwd' do
      install_fake_cli('app/claude-wrapper')
      install_fake_cli('target/claude-wrapper')

      with_env('PATH' => "#{ENV.fetch('PATH')}#{File::PATH_SEPARATOR}") do
        expect(legs_executed(cli_path: 'claude-wrapper'))
          .to eq(%w[probe:app/claude-wrapper spawn:app/claude-wrapper])
      end
    end

    # spawn searched the PATH it was about to give the child, so that is the
    # PATH which decides here too — and the probe now runs the same file.
    it 'is searched on the PATH from options.env, for the probe and the spawn' do
      install_fake_cli('tools/claude-wrapper')
      env = { 'PATH' => path_with(File.join(root, 'tools')) }

      expect(legs_executed(cli_path: 'claude-wrapper', env: env))
        .to eq(%w[probe:tools/claude-wrapper spawn:tools/claude-wrapper])
    end

    it 'anchors a relative entry of the options.env PATH to the process cwd as well' do
      install_fake_cli('app/bin/claude')
      install_fake_cli('target/bin/claude')

      expect(legs_executed(cli_path: 'claude', env: { PATH: path_with('bin') }))
        .to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
    end

    it 'reports a name that is not on PATH as CLINotFoundError at connect, not at construction' do
      transport = Dir.chdir(app) { described_class.new(options(cli_path: 'claude-that-is-not-installed')) }

      expect { Dir.chdir(app) { transport.connect } }.to raise_error(
        ClaudeAgentSDK::CLINotFoundError, 'Claude Code not found at: claude-that-is-not-installed'
      )
    end

    # A name the SDK could not settle must not reach spawn: spawn searches
    # PATH on its own, in the parent, and then runs a relative hit after
    # chdir-ing into options.cwd.
    it 'never hands an unresolved name to spawn' do
      with_env('PATH' => path_with('bin')) do
        transport = Dir.chdir(app) { described_class.new(options(cli_path: 'late-claude')) }
        install_fake_cli('app/bin/late-claude')
        install_fake_cli('target/bin/late-claude')

        expect { Dir.chdir(app) { transport.connect } }.to raise_error(ClaudeAgentSDK::CLINotFoundError)
      ensure
        transport&.close
      end
      expect(legs).to be_empty
    end
  end

  describe 'discovery (no cli_path)' do
    it 'runs the `which` hit of a relative PATH entry from the process cwd, for the probe and the spawn' do
      install_fake_cli('app/bin/claude')
      install_fake_cli('target/bin/claude')

      with_env('PATH' => path_with('bin')) do
        expect(legs_executed).to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
      end
    end

    it 'runs the `which` hit of a `.` PATH entry from the process cwd' do
      install_fake_cli('app/claude')
      install_fake_cli('target/claude')

      with_env('PATH' => path_with('.')) do
        expect(legs_executed).to eq(%w[probe:app/claude spawn:app/claude])
      end
    end

    # `which` implementations differ (BSD, busybox and Debian's print the
    # relative hit, GNU's prints an absolute one), so pin the relative
    # spelling itself.
    it 'absolutizes a relative `which` hit against the process cwd' do
      install_fake_cli('app/bin/claude')
      allow(Open3).to receive(:capture2).and_call_original
      allow(Open3).to receive(:capture2).with('which', 'claude').and_return(["bin/claude\n", nil])

      transport = Dir.chdir(app) { described_class.new(options) }

      expect(transport.build_command.first).to eq(File.join(app, 'bin', 'claude'))
    end
  end
end
