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
  # developer machine) out of the discovery examples.
  before { allow(ClaudeAgentSDK::CLIInstaller).to receive(:installed_path).and_return(nil) }

  # The examples assert on the marker line the probe leg writes. The fakes
  # answer `-v` at once, but on a starved machine "at once" can exceed the
  # probe's 2 s deadline, which would silently drop that line.
  before { stub_const("#{described_class}::VERSION_CHECK_TIMEOUT_SECONDS", 60) }

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
  def legs_executed(transport_class = described_class, **values)
    Dir.chdir(app) do
      transport = transport_class.new(options(**values))
      begin
        transport.connect
        transport.read_messages { |_frame| nil }
      ensure
        transport.close
      end
    end
    legs
  end

  # `link` -> `real/sub`, so `link/..` is `real` on the filesystem but the
  # root itself when collapsed as text. Fakes on both sides tell them apart.
  def symlinked_dotdot(name)
    FileUtils.mkdir_p(File.join(root, 'real', 'sub'))
    File.symlink(File.join(root, 'real', 'sub'), File.join(root, 'link'))
    install_fake_cli("real/bin/#{name}")
    install_fake_cli("bin/#{name}")
    File.join(root, 'link', '..', 'bin')
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

  # Names no host has on PATH: if the lookup regressed, an example must fail
  # with CLINotFoundError, not fall through to the developer's real `claude`
  # (which would then wait for a prompt on stdin and hang the run).
  describe 'an explicit bare name' do
    it 'is found through a relative PATH entry in the process cwd, for the probe and the spawn' do
      install_fake_cli('app/bin/fake-claude-cli')
      install_fake_cli('target/bin/fake-claude-cli')

      with_env('PATH' => path_with('bin')) do
        expect(legs_executed(cli_path: 'fake-claude-cli'))
          .to eq(%w[probe:app/bin/fake-claude-cli spawn:app/bin/fake-claude-cli])
      end
    end

    it 'treats `.` and an empty PATH entry as the process cwd' do
      install_fake_cli('app/fake-claude-cli')
      install_fake_cli('target/fake-claude-cli')

      aggregate_failures do
        ['.', ''].each do |entry|
          FileUtils.rm_f(marker)
          with_env('PATH' => path_with(entry)) do
            expect(legs_executed(cli_path: 'fake-claude-cli'))
              .to eq(%w[probe:app/fake-claude-cli spawn:app/fake-claude-cli]), "PATH entry #{entry.inspect}: #{legs.inspect}"
          end
        end
      end
    end

    # Ruby's spawn tests for an executable regular file; a directory of the
    # same name earlier on PATH (executable? is true for directories) is
    # passed over.
    it 'takes the first executable regular file on PATH, not a directory of that name' do
      FileUtils.mkdir_p(File.join(root, 'dirs', 'fake-claude-cli'))
      install_fake_cli('tools/fake-claude-cli')
      search = [File.join(root, 'dirs'), File.join(root, 'tools'), ENV.fetch('PATH')].join(File::PATH_SEPARATOR)

      with_env('PATH' => search) do
        expect(legs_executed(cli_path: 'fake-claude-cli'))
          .to eq(%w[probe:tools/fake-claude-cli spawn:tools/fake-claude-cli])
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

    # As spawn's own lookup did for a bare name: a `~/` entry is the home
    # directory (HOME is the tmp root here), not `~` under the cwd. The same
    # rule as for discovery, pinned there too.
    it 'expands a `~/` PATH entry against HOME, not against the process cwd' do
      install_fake_cli('app/~/bin/fake-claude-cli')
      install_fake_cli('bin/fake-claude-cli')

      with_env('PATH' => path_with('~/bin'), 'HOME' => root) do
        expect(legs_executed(cli_path: 'fake-claude-cli'))
          .to eq(%w[probe:bin/fake-claude-cli spawn:bin/fake-claude-cli])
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
      install_fake_cli('app/bin/fake-claude-cli')
      install_fake_cli('target/bin/fake-claude-cli')

      expect(legs_executed(cli_path: 'fake-claude-cli', env: { PATH: path_with('bin') }))
        .to eq(%w[probe:app/bin/fake-claude-cli spawn:app/bin/fake-claude-cli])
    end

    it 'reports a name that is not on PATH as CLINotFoundError at connect, not at construction' do
      transport = Dir.chdir(app) { described_class.new(options(cli_path: 'claude-that-is-not-installed')) }

      expect { Dir.chdir(app) { transport.connect } }.to raise_error(
        ClaudeAgentSDK::CLINotFoundError, 'Claude Code not found at: claude-that-is-not-installed'
      )
    end

    # A name the SDK could not settle must not reach spawn: spawn searches
    # PATH on its own, in the parent, and then runs a relative hit after
    # chdir-ing into options.cwd. Here the SDK's lookup is made to miss the
    # process-cwd file (File.file? is its test); spawn's own lookup, done in
    # C, would still find it and run target/bin/unsettled-claude.
    it 'never hands an unresolved name to spawn' do
      install_fake_cli('app/bin/unsettled-claude')
      install_fake_cli('target/bin/unsettled-claude')
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(File.join(app, 'bin', 'unsettled-claude')).and_return(false)

      with_env('PATH' => path_with('bin')) do
        transport = Dir.chdir(app) { described_class.new(options(cli_path: 'unsettled-claude')) }

        expect { Dir.chdir(app) { transport.connect } }.to raise_error(ClaudeAgentSDK::CLINotFoundError)
      ensure
        transport&.close
      end
      expect(legs).to be_empty
    end

    it 'is looked up again at connect, as spawn did: a CLI installed after construction is found' do
      with_env('PATH' => path_with(File.join(root, 'tools'))) do
        transport = Dir.chdir(app) { described_class.new(options(cli_path: 'claude-installed-later')) }
        install_fake_cli('tools/claude-installed-later')

        begin
          Dir.chdir(app) do
            transport.connect
            transport.read_messages { |_frame| nil }
          end
        ensure
          transport.close
        end
      end

      expect(legs).to eq(%w[probe:tools/claude-installed-later spawn:tools/claude-installed-later])
    end
  end

  # Discovery looks for `claude` itself, on the process's PATH. HOME at the
  # tmp root keeps the well-known `~/...` install locations empty, so a
  # regression in the PATH step fails here instead of reaching the
  # developer's real CLI.
  describe 'discovery (no cli_path)' do
    it 'runs the hit of a relative PATH entry from the process cwd, for the probe and the spawn' do
      install_fake_cli('app/bin/claude')
      install_fake_cli('target/bin/claude')

      with_env('PATH' => path_with('bin'), 'HOME' => root) do
        expect(legs_executed).to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
      end
    end

    it 'runs the hit of a `.` PATH entry from the process cwd' do
      install_fake_cli('app/claude')
      install_fake_cli('target/claude')

      with_env('PATH' => path_with('.'), 'HOME' => root) do
        expect(legs_executed).to eq(%w[probe:app/claude spawn:app/claude])
      end
    end

    # An empty entry is the current directory to a PATH lookup, and the easy
    # one to lose in a lookup written by hand (a split that drops empty
    # strings is enough). The first entry names nothing, so only the
    # trailing empty one can find `claude` here.
    it 'treats a trailing empty PATH entry as the process cwd' do
      install_fake_cli('app/claude')
      install_fake_cli('target/claude')
      search = "#{File.join(root, 'no-such-directory')}#{File::PATH_SEPARATOR}"

      with_env('PATH' => search, 'HOME' => root) do
        expect(legs_executed).to eq(%w[probe:app/claude spawn:app/claude])
      end
    end

    # A PATH entry that is `~` or starts with `~/` is the home directory to
    # Ruby's own command lookup (system, spawn, Open3; sh and bash agree),
    # not a directory called `~` under the cwd — only `which` and execvp read
    # it literally. The SDK spawns through Open3, so it resolves the name the
    # way Ruby would: on purpose, this is not one of the relative entries
    # anchored to the process cwd. HOME is the tmp root here.
    it "expands a `~/` PATH entry against HOME, as Ruby's own lookup does" do
      install_fake_cli('app/~/bin/claude')
      install_fake_cli('bin/claude')
      search = ['~/bin', '/usr/bin', '/bin'].join(File::PATH_SEPARATOR)

      with_env('PATH' => search, 'HOME' => root) do
        expect(legs_executed).to eq(%w[probe:bin/claude spawn:bin/claude])
      end
    end

    # `which` is a program like any other: looked up on PATH — here through
    # the relative `bin` entry — and free to answer anything. This one names
    # the binary inside options.cwd. Discovery searches PATH itself, so it
    # neither runs `which` nor has an answer to believe.
    it 'does not run or believe a `which` found on PATH' do
      install_fake_cli('app/bin/claude')
      install_fake_cli('target/bin/claude')
      lying_which = File.join(app, 'bin', 'which')
      File.write(lying_which, <<~SH)
        #!/bin/sh
        echo 'which-ran' >> '#{marker}'
        echo '#{File.join(target, 'bin', 'claude')}'
      SH
      File.chmod(0o755, lying_which)
      search = ['bin', '/usr/bin', '/bin'].join(File::PATH_SEPARATOR)

      with_env('PATH' => search, 'HOME' => root) do
        expect(legs_executed).to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
      end
    end

    # A PATH in options.env is the session's. Discovery searches the PATH
    # `which claude` used to see, the process's; only an explicit bare
    # cli_path is looked up on the session's.
    it 'searches the process PATH, not the one options.env gives the session' do
      install_fake_cli('app/bin/claude')
      install_fake_cli('tools/claude')
      session_env = { 'PATH' => path_with(File.join(root, 'tools')) }

      with_env('PATH' => path_with('bin'), 'HOME' => root) do
        expect(legs_executed(env: session_env)).to eq(%w[probe:app/bin/claude spawn:app/bin/claude])
      end
    end

    it 'puts the anchored absolute path in the argv before connecting' do
      install_fake_cli('app/bin/claude')

      transport = with_env('PATH' => path_with('bin'), 'HOME' => root) do
        Dir.chdir(app) { described_class.new(options) }
      end

      expect(transport.build_command.first).to eq(File.join(app, 'bin', 'claude'))
    end
  end

  # #build_command is not public API, but a transport that runs the CLI
  # through another program (docker exec, ssh) has no other hook, and its
  # cli_path names a file on the far side. The refusal to spawn an unsettled
  # path is about the SDK's own argv; an argv like this is spawned as built.
  describe 'a subclass that wraps the CLI in another program' do
    it 'still spawns its argv when cli_path is a bare name this host does not have' do
      wrapper = File.join(root, 'wrapper')
      File.write(wrapper, "#!/bin/sh\necho \"wrapped:$1\" >> '#{marker}'\n")
      File.chmod(0o755, wrapper)
      wrapping = Class.new(described_class) do
        define_method(:build_command) { [wrapper, *super()] }
      end
      transport = Dir.chdir(app) { wrapping.new(options(cli_path: 'claude-on-the-far-side')) }

      begin
        transport.connect
        transport.read_messages { |_frame| nil }
      ensure
        transport.close
      end

      expect(legs).to eq(['wrapped:claude-on-the-far-side'])
    end
  end

  # spawn resolved `link/..` through the filesystem; a path rewritten as
  # text (File.expand_path) would name another file when `link` is a
  # symlink. Paths are anchored, never normalized.
  describe 'a symlink followed by `..`' do
    it 'runs an absolute cli_path the way the filesystem resolves it' do
      bin = symlinked_dotdot('fake-claude-cli')

      expect(legs_executed(cli_path: File.join(bin, 'fake-claude-cli')))
        .to eq(%w[probe:real/bin/fake-claude-cli spawn:real/bin/fake-claude-cli])
    end

    it 'searches a PATH entry the way the filesystem resolves it' do
      bin = symlinked_dotdot('fake-claude-cli')

      with_env('PATH' => path_with(bin)) do
        expect(legs_executed(cli_path: 'fake-claude-cli'))
          .to eq(%w[probe:real/bin/fake-claude-cli spawn:real/bin/fake-claude-cli])
      end
    end

    it 'discovers `claude` through such a PATH entry and keeps the entry as written' do
      bin = symlinked_dotdot('claude')

      # HOME at the tmp root: no well-known install location to fall back on.
      transport = with_env('PATH' => path_with(bin), 'HOME' => root) do
        Dir.chdir(app) { described_class.new(options) }
      end

      expect(transport.build_command.first).to eq(File.join(bin, 'claude'))
    end
  end

  describe 'inputs that worked before this resolution existed' do
    it 'treats any falsy cli_path as "discover"', rbs_incompatible: 'cli_path: false is outside the signature' do
      env_cli = install_fake_cli('tools/claude-from-env')

      with_env('CLAUDE_CLI_PATH' => env_cli) do
        expect(legs_executed(cli_path: false)).to eq(%w[probe:tools/claude-from-env spawn:tools/claude-from-env])
      end
    end

    it "settles a bare name from a subclass's #find_cli like an explicit cli_path" do
      install_fake_cli('tools/claude-from-subclass')
      discovering = Class.new(described_class) { define_method(:find_cli) { 'claude-from-subclass' } }

      with_env('PATH' => path_with(File.join(root, 'tools'))) do
        expect(legs_executed(discovering))
          .to eq(%w[probe:tools/claude-from-subclass spawn:tools/claude-from-subclass])
      end
    end

    it 'searches a PATH that is not valid UTF-8 byte by byte' do
      install_fake_cli('tools/claude-bytewise')
      not_utf8 = "#{root}/\xFFdir".force_encoding(Encoding::UTF_8)
      env = { 'PATH' => "#{not_utf8}#{File::PATH_SEPARATOR}#{File.join(root, 'tools')}" }

      expect(legs_executed(cli_path: 'claude-bytewise', env: env))
        .to eq(%w[probe:tools/claude-bytewise spawn:tools/claude-bytewise])
    end

    it 'reports a cli_path with a NUL byte as a CLIConnectionError, not a raw ArgumentError' do
      transport = Dir.chdir(app) { described_class.new(options(cli_path: "bin/cl\0aude")) }

      expect { Dir.chdir(app) { transport.connect } }.to raise_error(ClaudeAgentSDK::CLIConnectionError)
    end
  end
end
