# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'

# The offline, idempotent shortcut of CLIInstaller.install in a directory the
# process cannot write: an image built as root and run as another user, or a
# read-only root filesystem. The shortcut sits inside the install lock, and the
# lock file is opened read-write first — so a boot-time install_pinned raised
# EACCES although the pinned binary was installed and intact.
RSpec.describe ClaudeAgentSDK::CLIInstaller, 'in a read-only install directory' do
  let(:base) { 'https://downloads.claude.ai/claude-code-releases' }
  let(:binary_body) { 'not-really-280MB-of-claude' }
  let(:http) { ClaudeAgentSDK::CLIInstaller::Http }
  let(:dir) { @dir }
  let(:binary_path) { File.join(dir, 'claude') }
  let(:lock_path) { File.join(dir, '.install.lock') }

  around do |example|
    Dir.mktmpdir('cli-installer-read-only') do |tmp|
      @dir = File.join(tmp, 'vendor', 'claude')
      example.run
    ensure
      # mktmpdir cannot remove a directory it may not write.
      FileUtils.chmod(0o755, @dir) if File.directory?(@dir)
    end
  end

  # The two GET endpoints, as cli_installer_spec.rb stubs them: no HTTP
  # library, the real Digest / Metadata / rename path.
  def stub_release(version: '2.1.220', platform: 'linux-x64')
    allow(ClaudeAgentSDK::CLIInstaller::Platform).to receive(:detect).and_return(platform)
    allow(http).to receive(:fetch_text) do |url, **|
      case url
      when "#{base}/stable" then "#{version}\n"
      when "#{base}/#{version}/manifest.json"
        entry = { 'checksum' => Digest::SHA256.hexdigest(binary_body), 'size' => binary_body.bytesize }
        JSON.generate('platforms' => { platform => entry })
      else raise "unexpected fetch_text(#{url.inspect})"
      end
    end
    allow(http).to receive(:download_to) do |_url, path, **|
      File.binwrite(path, binary_body)
      path
    end
  end

  def expect_no_network
    expect(http).not_to receive(:fetch_text)
    expect(http).not_to receive(:download_to)
  end

  def expect_permission_failure(error)
    expect(error.message).to include("Failed to install the Claude Code CLI into #{dir}", 'Errno::EACCES')
    expect(error.cause).to be_a(Errno::EACCES)
  end

  before do
    stub_release
    described_class.install(version: '2.1.220', dir: dir)
  end

  # chmod stands in for the foreign owner, so the process must be one that
  # file modes apply to.
  context 'when file modes deny writing' do
    before { skip 'file modes do not restrict root' if Process.uid.zero? }

    # What the runtime user of an image built by another user sees: everything
    # readable and executable, nothing writable.
    def make_read_only(lock_file: :present)
      lock_file == :present ? File.chmod(0o444, lock_path) : File.delete(lock_path)
      File.chmod(0o555, dir)
    end

    it 'returns the installed binary for its concrete version, offline and without the lock' do
      make_read_only
      expect_no_network

      expect(described_class.install(version: '2.1.220', dir: dir)).to eq(binary_path)
    end

    it 'returns the installed binary when the directory has no lock file to open' do
      # The install directory was copied into the image without its dotfile.
      make_read_only(lock_file: :absent)
      expect_no_network

      expect(described_class.install(version: '2.1.220', dir: dir)).to eq(binary_path)
      expect(Dir.children(dir)).to contain_exactly('VERSION', 'claude')
    end

    it 'serves install_pinned the same way' do
      stub_const('ClaudeAgentSDK::CLIInstaller::PINNED_CLI_VERSION', '2.1.220')
      make_read_only
      expect_no_network

      expect(described_class.install_pinned(dir: dir)).to eq(binary_path)
    end

    it 'raises for a dist-tag, which has to be resolved and may have to be published' do
      make_read_only
      expect_no_network

      expect { described_class.install(version: 'stable', dir: dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error| expect_permission_failure(error) }
    end

    it 'raises when the binary no longer matches its recorded checksum' do
      File.binwrite(binary_path, 'truncated-or-swapped')
      make_read_only
      expect_no_network

      expect { described_class.install(version: '2.1.220', dir: dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error| expect_permission_failure(error) }
    end

    it 'raises when another version is requested than the one installed' do
      make_read_only
      expect_no_network

      expect { described_class.install(version: '2.1.226', dir: dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error| expect_permission_failure(error) }
    end

    it 'raises when the binary was installed for another platform' do
      make_read_only
      allow(ClaudeAgentSDK::CLIInstaller::Platform).to receive(:detect).and_return('linux-arm64-musl')
      expect_no_network

      expect { described_class.install(version: '2.1.220', dir: dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error| expect_permission_failure(error) }
    end

    it 'raises when nothing is installed' do
      FileUtils.rm_f([binary_path, File.join(dir, 'VERSION')])
      make_read_only
      expect_no_network

      expect { described_class.install(version: '2.1.220', dir: dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error| expect_permission_failure(error) }
    end
  end

  # Errors chmod cannot produce: a read-only filesystem (EROFS) and a denied
  # operation (EPERM: an immutable file, a sandbox profile). Injected where
  # the kernel would raise them — at the open of the lock file.
  context 'when opening the lock file fails' do
    def fail_lock_open(error)
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(lock_path, any_args).and_raise(error)
    end

    [Errno::EROFS, Errno::EPERM, Errno::EACCES].each do |errno|
      it "returns the installed binary for its concrete version on #{errno}" do
        fail_lock_open(errno.new(lock_path))
        expect_no_network

        expect(described_class.install(version: '2.1.220', dir: dir)).to eq(binary_path)
      end

      it "still raises for a dist-tag on #{errno}" do
        fail_lock_open(errno.new(lock_path))
        expect_no_network

        expect { described_class.install(version: 'stable', dir: dir) }
          .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error| expect(error.cause).to be_a(errno) }
      end
    end

    it 'raises on any other failure to open the lock file, even when the binary is intact' do
      # A symlink planted at the lock path (opened NOFOLLOW) is not a
      # read-only directory, and neither is running out of descriptors.
      [Errno::ELOOP, Errno::EMFILE].each do |errno|
        fail_lock_open(errno.new(lock_path))

        expect { described_class.install(version: '2.1.220', dir: dir) }
          .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error| expect(error.cause).to be_a(errno) }
      end
    end
  end
end
