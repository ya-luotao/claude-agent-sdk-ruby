# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'json'
require 'tmpdir'

RSpec.describe ClaudeAgentSDK::CLIInstaller do
  let(:base) { 'https://downloads.claude.ai/claude-code-releases' }
  let(:binary_body) { 'not-really-280MB-of-claude' }
  let(:checksum) { Digest::SHA256.hexdigest(binary_body) }
  let(:tmp_dir) { @tmp_dir }
  # The seams the specs stub instead of pulling in an HTTP stubbing library:
  # Http does every network call, Platform every host probe.
  let(:http) { ClaudeAgentSDK::CLIInstaller::Http }
  let(:platform_module) { ClaudeAgentSDK::CLIInstaller::Platform }
  let(:metadata) { ClaudeAgentSDK::CLIInstaller::Metadata }
  let(:binary_path) { File.join(tmp_dir, 'claude') }
  let(:version_path) { File.join(tmp_dir, 'VERSION') }
  let(:lock_path) { File.join(tmp_dir, '.install.lock') }

  around do |example|
    # Every filesystem side effect stays inside a throwaway directory — the
    # repo's real vendor/ must never gain state that leaks into later runs.
    Dir.mktmpdir('cli-installer-spec') do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  # Routes the two GET endpoints the installer uses. `download_to` writes the
  # fixture body so the real Digest/chmod/rename path still runs.
  # +manifest_size+ defaults to the fixture's own size (the real manifest
  # carries one); pass nil to model a manifest entry without a size field.
  def stub_http(version: '2.1.220', platform: 'darwin-arm64', manifest_checksum: nil,
                body: binary_body, manifest_size: :auto, tags: { 'stable' => '2.1.220', 'latest' => '2.1.226' })
    manifest_size = body.bytesize if manifest_size == :auto
    manifest_checksum ||= Digest::SHA256.hexdigest(body)
    allow(platform_module).to receive(:detect).and_return(platform)
    allow(http).to receive(:fetch_text) do |url, **|
      case url
      when "#{base}/stable", "#{base}/latest"
        "#{tags.fetch(url.split('/').last)}\n"
      when "#{base}/#{version}/manifest.json"
        entry = { 'checksum' => manifest_checksum }
        entry['size'] = manifest_size unless manifest_size.nil?
        JSON.generate('platforms' => { platform => entry })
      else
        raise "unexpected fetch_text(#{url.inspect})"
      end
    end
    allow(http).to receive(:download_to) do |url, path, **|
      expect(url).to eq("#{base}/#{version}/#{platform}/claude")
      File.binwrite(path, body)
      path
    end
  end

  def recorded_version(dir = tmp_dir)
    File.read(File.join(dir, 'VERSION')).lines.first.to_s.strip
  end

  def recorded_checksum(dir = tmp_dir)
    File.read(File.join(dir, 'VERSION')).lines[1].to_s.strip
  end

  describe '.default_dir' do
    it 'resolves vendor/claude against the current working directory at call time' do
      Dir.chdir(tmp_dir) do
        expect(described_class.default_dir).to eq(File.join(File.realpath(tmp_dir), 'vendor', 'claude'))
      end
    end
  end

  describe '.install version resolution' do
    it "resolves the 'stable' dist-tag through its endpoint" do
      stub_http(version: '2.1.220')

      described_class.install(dir: tmp_dir)

      expect(recorded_version).to eq('2.1.220')
    end

    it "resolves the 'latest' dist-tag through its endpoint" do
      stub_http(version: '2.1.226')

      described_class.install(version: 'latest', dir: tmp_dir)

      expect(recorded_version).to eq('2.1.226')
    end

    it 'uses a concrete version without hitting a dist-tag endpoint' do
      stub_http(version: '2.1.100')

      described_class.install(version: '2.1.100', dir: tmp_dir)

      expect(http).not_to have_received(:fetch_text).with("#{base}/stable", any_args)
      expect(recorded_version).to eq('2.1.100')
    end

    it 'accepts a pre-release version suffix' do
      stub_http(version: '2.1.220-rc1')

      expect(described_class.install(version: '2.1.220-rc1', dir: tmp_dir)).to eq(binary_path)
    end

    it 'raises on a malformed version without creating anything' do
      expect { described_class.install(version: '../../etc/passwd', dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Invalid Claude Code CLI version/)

      expect(Dir.children(tmp_dir)).to be_empty
    end

    it 'raises when the dist-tag endpoint returns an HTML error page' do
      allow(http).to receive(:fetch_text).and_return("<!DOCTYPE html>\n<html><body>nope</body></html>")

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /did not return a version string/)
    end
  end

  describe 'platform detection' do
    def platform_for(ruby_platform, rosetta: false)
      allow(platform_module).to receive(:ruby_platform).and_return(ruby_platform)
      allow(platform_module).to receive(:rosetta?).and_return(rosetta)
      platform_module.detect
    end

    it 'maps Apple Silicon to darwin-arm64' do
      expect(platform_for('arm64-darwin24')).to eq('darwin-arm64')
    end

    it 'maps Intel macOS to darwin-x64' do
      expect(platform_for('x86_64-darwin23')).to eq('darwin-x64')
    end

    it 'maps Intel macOS under Rosetta 2 to darwin-arm64' do
      expect(platform_for('x86_64-darwin23', rosetta: true)).to eq('darwin-arm64')
    end

    it 'maps glibc Linux to linux-x64' do
      expect(platform_for('x86_64-linux')).to eq('linux-x64')
    end

    it 'maps arm64 Linux to linux-arm64' do
      expect(platform_for('aarch64-linux')).to eq('linux-arm64')
    end

    it 'maps musl Linux to the musl variant' do
      expect(platform_for('x86_64-linux-musl')).to eq('linux-x64-musl')
      expect(platform_for('aarch64-linux-musl')).to eq('linux-arm64-musl')
    end

    it 'never applies the Rosetta override on Linux' do
      expect(platform_for('x86_64-linux', rosetta: true)).to eq('linux-x64')
    end

    it 'raises on Windows' do
      expect { platform_for('x64-mingw-ucrt') }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Windows is not supported/)
    end

    it 'raises on an unsupported CPU architecture' do
      expect { platform_for('powerpc64-linux') }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Unsupported CPU architecture/)
    end
  end

  describe 'manifest handling' do
    it 'raises when the manifest has no entry for the platform' do
      allow(platform_module).to receive(:detect).and_return('linux-arm64-musl')
      allow(http).to receive(:fetch_text) do |url, **|
        if url.end_with?('manifest.json')
          JSON.generate('platforms' => { 'linux-x64' => { 'checksum' => checksum } })
        else
          "2.1.220\n"
        end
      end

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /no entry for platform linux-arm64-musl.*available: linux-x64/m)
    end

    it 'raises when the checksum is not a 64-character hex digest' do
      stub_http(manifest_checksum: 'deadbeef')

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /no valid sha256 checksum/)
    end

    it 'raises when the manifest is not JSON' do
      allow(platform_module).to receive(:detect).and_return('darwin-arm64')
      allow(http).to receive(:fetch_text) do |url, **|
        url.end_with?('manifest.json') ? '<html>503</html>' : "2.1.220\n"
      end

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /malformed JSON/)
    end
  end

  describe 'download and verification' do
    it 'installs an executable binary and records version + checksum' do
      stub_http

      path = described_class.install(dir: tmp_dir)

      expect(path).to eq(binary_path)
      expect(File.binread(path)).to eq(binary_body)
      expect(File.executable?(path)).to be true
      expect(File.stat(path).mode & 0o777).to eq(0o755)
      expect(recorded_version).to eq('2.1.220')
      expect(recorded_checksum).to eq(checksum)
    end

    it 'creates the install directory when it does not exist' do
      stub_http
      nested = File.join(tmp_dir, 'vendor', 'claude')

      expect(described_class.install(dir: nested)).to eq(File.join(nested, 'claude'))
    end

    it 'raises and leaves no binary or metadata behind on a checksum mismatch' do
      stub_http(manifest_checksum: Digest::SHA256.hexdigest('some other build'))

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Checksum mismatch/)

      expect(File.exist?(binary_path)).to be false
      expect(File.exist?(version_path)).to be false
      # Only the lock file, i.e. no temp download left behind.
      expect(Dir.children(tmp_dir)).to contain_exactly('.install.lock')
    end

    it 'downloads to an unpredictable temp name, never a fixed one' do
      stub_http
      paths = []
      allow(http).to receive(:download_to) do |_url, path, **|
        paths << path
        File.binwrite(path, binary_body)
        path
      end

      described_class.install(dir: tmp_dir)
      described_class.install(dir: File.join(tmp_dir, 'second'))

      expect(paths.map { |p| File.basename(p) }).to all(match(/\Aclaude\.download\.[0-9a-f]{16}\z/))
      expect(paths.uniq.size).to eq(2)
    end

    it 'passes the manifest size to the downloader as a hard byte bound' do
      stub_http

      described_class.install(dir: tmp_dir)

      expect(http).to have_received(:download_to)
        .with("#{base}/2.1.220/darwin-arm64/claude", anything, max_bytes: binary_body.bytesize)
    end

    it 'passes no bound when the manifest entry has no size' do
      stub_http(manifest_size: nil)

      described_class.install(dir: tmp_dir)

      expect(http).to have_received(:download_to).with(anything, anything, max_bytes: nil)
    end

    it 'ignores a size that is not a positive Integer' do
      stub_http(manifest_size: -1)

      described_class.install(dir: tmp_dir)

      expect(http).to have_received(:download_to).with(anything, anything, max_bytes: nil)
    end
  end

  describe 'Http.download_to' do
    # Yields a canned response so the real File-opening path runs without HTTP.
    def stub_response(*chunks)
      response = Object.new
      response.define_singleton_method(:read_body) { |&blk| chunks.each { |chunk| blk.call(chunk) } }
      allow(http).to receive(:with_response) { |_url, &blk| blk.call(response) }
    end

    it 'refuses to write through a symlink planted at the temp path (O_EXCL)' do
      stub_response('payload')
      victim = File.join(tmp_dir, 'victim')
      File.write(victim, 'original')
      link = File.join(tmp_dir, 'claude.download.decoy')
      File.symlink(victim, link)

      expect { http.download_to('https://example.com/claude', link) }.to raise_error(Errno::EEXIST)
      expect(File.read(victim)).to eq('original')
    end

    it 'refuses to overwrite an existing regular file' do
      stub_response('payload')
      existing = File.join(tmp_dir, 'existing')
      File.write(existing, 'keep me')

      expect { http.download_to('https://example.com/claude', existing) }.to raise_error(Errno::EEXIST)
      expect(File.read(existing)).to eq('keep me')
    end

    it 'streams chunks to a fresh file' do
      stub_response('abc', 'def')
      target = File.join(tmp_dir, 'fresh')

      expect(http.download_to('https://example.com/claude', target)).to eq(target)
      expect(File.binread(target)).to eq('abcdef')
    end

    it 'aborts mid-stream once max_bytes is exceeded' do
      stub_response('a' * 4, 'b' * 4)
      target = File.join(tmp_dir, 'too-big')

      expect { http.download_to('https://example.com/claude', target, max_bytes: 5) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /exceeds the expected 5 bytes/)
    end

    it 'accepts a stream exactly at max_bytes' do
      stub_response('abcde')
      target = File.join(tmp_dir, 'exact')

      expect(http.download_to('https://example.com/claude', target, max_bytes: 5)).to eq(target)
      expect(File.binread(target)).to eq('abcde')
    end

    it 'does not bound the stream when max_bytes is nil' do
      stub_response('a' * 1000)
      target = File.join(tmp_dir, 'unbounded')

      expect(http.download_to('https://example.com/claude', target, max_bytes: nil)).to eq(target)
      expect(File.size(target)).to eq(1000)
    end
  end

  describe 'Http.fetch_text response caps' do
    def stub_response(*chunks)
      response = Object.new
      response.define_singleton_method(:read_body) { |&blk| chunks.each { |chunk| blk.call(chunk) } }
      allow(http).to receive(:with_response) { |_url, &blk| blk.call(response) }
    end

    it 'raises once the buffered body exceeds the limit' do
      stub_response('x' * 600, 'y' * 600)

      expect { http.fetch_text('https://example.com/stable', limit: 1024) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /exceeds the 1024-byte limit/)
    end

    it 'returns the body when it fits' do
      stub_response('2.1.220')

      expect(http.fetch_text('https://example.com/stable', limit: 1024)).to eq('2.1.220')
    end

    it 'caps the version endpoint at 1KB and the manifest at 5MB' do
      stub_http

      described_class.install(dir: tmp_dir)

      expect(http).to have_received(:fetch_text).with("#{base}/stable", limit: 1024)
      expect(http).to have_received(:fetch_text).with("#{base}/2.1.220/manifest.json", limit: 5 * 1024 * 1024)
    end
  end

  describe 'idempotency' do
    it 'does not download when the installed binary matches the recorded version and checksum' do
      stub_http
      described_class.install(dir: tmp_dir)

      # Counts only calls made after this expectation is set, so the first
      # install's legitimate download does not trip it.
      expect(http).not_to receive(:download_to)

      expect(described_class.install(dir: tmp_dir)).to eq(binary_path)
    end

    it 'reinstalls when the recorded version differs' do
      stub_http
      described_class.install(dir: tmp_dir)

      stub_http(version: '2.1.226', tags: { 'stable' => '2.1.226' })
      described_class.install(dir: tmp_dir)

      expect(recorded_version).to eq('2.1.226')
    end

    it 'reinstalls when the VERSION file is missing' do
      stub_http
      described_class.install(dir: tmp_dir)
      FileUtils.rm_f(version_path)

      described_class.install(dir: tmp_dir)

      expect(http).to have_received(:download_to).twice
    end

    it 'reinstalls when the binary no longer matches the recorded checksum' do
      stub_http
      described_class.install(dir: tmp_dir)
      File.binwrite(binary_path, 'truncated-or-swapped')

      described_class.install(dir: tmp_dir)

      expect(http).to have_received(:download_to).twice
      expect(File.binread(binary_path)).to eq(binary_body)
    end

    it 'reinstalls when VERSION predates the checksum line (old single-line format)' do
      stub_http
      described_class.install(dir: tmp_dir)
      File.write(version_path, "2.1.220\n")

      described_class.install(dir: tmp_dir)

      expect(http).to have_received(:download_to).twice
      expect(recorded_checksum).to eq(checksum)
    end

    it 'never touches the network on the shortcut path (offline re-boot)' do
      stub_http
      described_class.install(version: '2.1.220', dir: tmp_dir)

      expect(http).not_to receive(:fetch_text)
      expect(http).not_to receive(:download_to)

      expect(described_class.install(version: '2.1.220', dir: tmp_dir)).to eq(binary_path)
    end
  end

  describe 'concurrency' do
    it 'holds an exclusive lock on .install.lock for the whole install' do
      stub_http
      held_elsewhere = nil
      allow(http).to receive(:download_to) do |_url, path, **|
        # flock is per open file description, so a second open in this same
        # process contends exactly like another process would.
        held_elsewhere = File.open(lock_path, 'r') { |f| f.flock(File::LOCK_EX | File::LOCK_NB) }
        File.binwrite(path, binary_body)
        path
      end

      described_class.install(dir: tmp_dir)

      expect(held_elsewhere).to be false
      # Released once install returns.
      expect(File.open(lock_path, 'r') { |f| f.flock(File::LOCK_EX | File::LOCK_NB) }).to eq(0)
    end

    it 'serializes concurrent installs so only one download happens' do
      stub_http
      downloads = 0
      counter_mutex = Mutex.new
      allow(http).to receive(:download_to) do |_url, path, **|
        counter_mutex.synchronize { downloads += 1 }
        sleep 0.15 # keep the lock held long enough for the other thread to contend
        File.binwrite(path, binary_body)
        path
      end

      threads = Array.new(2) { Thread.new { described_class.install(dir: tmp_dir) } }
      threads.each { |thread| expect(thread.join(20)).not_to be_nil }

      expect(downloads).to eq(1)
      expect(threads.map(&:value)).to all(eq(binary_path))
      expect(recorded_checksum).to eq(checksum)
    end
  end

  describe 'failure containment' do
    it 'publishes nothing when recording metadata fails on a first install' do
      stub_http
      allow(metadata).to receive(:write).and_raise(Errno::EACCES.new(version_path))

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Failed to install the Claude Code CLI/)

      expect(File.exist?(binary_path)).to be false
      expect(File.exist?(version_path)).to be false
      expect(Dir.children(tmp_dir)).to contain_exactly('.install.lock')
    end

    it 'leaves an existing install untouched when an upgrade cannot record metadata' do
      stub_http
      described_class.install(dir: tmp_dir)

      stub_http(version: '2.1.226', body: 'a newer build', tags: { 'stable' => '2.1.226' })
      allow(metadata).to receive(:write).and_raise(Errno::EACCES.new(version_path))

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Failed to install the Claude Code CLI/)

      # The working install is exactly as it was — binary, metadata and all.
      expect(File.binread(binary_path)).to eq(binary_body)
      expect(recorded_version).to eq('2.1.220')
      expect(recorded_checksum).to eq(checksum)
      expect(Dir.children(tmp_dir)).to contain_exactly('.install.lock', 'VERSION', 'claude')

      # ...and it still satisfies the idempotency shortcut.
      allow(metadata).to receive(:write).and_call_original
      stub_http
      expect(http).not_to receive(:download_to)
      expect(described_class.install(version: '2.1.220', dir: tmp_dir)).to eq(binary_path)
    end

    it 'keeps the old binary runnable when the final rename fails, and reinstalls next time' do
      stub_http
      described_class.install(dir: tmp_dir)

      stub_http(version: '2.1.226', body: 'a newer build', tags: { 'stable' => '2.1.226' })
      allow(File).to receive(:rename).and_call_original
      # Only the binary swap fails; Metadata.write's own rename still works.
      allow(File).to receive(:rename).with(anything, binary_path).and_raise(Errno::EXDEV)

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Errno::EXDEV/)

      # The previously installed binary is intact and still runnable, so
      # find_cli keeps working through a failed upgrade.
      expect(File.binread(binary_path)).to eq(binary_body)
      expect(File.executable?(binary_path)).to be true
      # Metadata already names the new version, whose checksum the old binary
      # cannot match — so the shortcut correctly reports "not installed".
      expect(recorded_version).to eq('2.1.226')

      allow(File).to receive(:rename).and_call_original
      described_class.install(dir: tmp_dir)

      expect(File.binread(binary_path)).to eq('a newer build')
      expect(recorded_checksum).to eq(Digest::SHA256.hexdigest('a newer build'))
    end

    it 'aborts an oversized download and leaves no temp file behind' do
      # The real download_to runs here (only the response is canned), so the
      # byte bound is enforced end to end.
      allow(platform_module).to receive(:detect).and_return('darwin-arm64')
      allow(http).to receive(:fetch_text) do |url, **|
        if url.end_with?('manifest.json')
          JSON.generate('platforms' => { 'darwin-arm64' => { 'checksum' => checksum, 'size' => 5 } })
        else
          "2.1.220\n"
        end
      end
      response = Object.new
      response.define_singleton_method(:read_body) { |&blk| 10.times { blk.call('0123456789') } }
      allow(http).to receive(:with_response) { |_url, &blk| blk.call(response) }

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /exceeds the expected 5 bytes/)

      expect(Dir.children(tmp_dir)).to contain_exactly('.install.lock')
    end

    it 'wraps filesystem errors in CLIInstallError while preserving the cause' do
      stub_http
      allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES.new(tmp_dir))

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error|
          expect(error.message).to include('Failed to install the Claude Code CLI into', 'Errno::EACCES')
          expect(error.cause).to be_a(Errno::EACCES)
        }
    end

    it 'wraps a mid-download IO failure' do
      stub_http
      allow(http).to receive(:download_to).and_raise(Errno::ENOSPC.new('device full'))

      expect { described_class.install(dir: tmp_dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Errno::ENOSPC/)

      expect(File.exist?(binary_path)).to be false
    end
  end

  describe '.installed_path' do
    it 'returns the path when an executable binary is present' do
      stub_http
      described_class.install(dir: tmp_dir)

      expect(described_class.installed_path(dir: tmp_dir)).to eq(binary_path)
    end

    it 'returns nil when nothing is installed' do
      expect(described_class.installed_path(dir: tmp_dir)).to be_nil
    end

    it 'returns nil when the binary exists but is not executable' do
      File.write(binary_path, 'x')
      File.chmod(0o644, binary_path)

      expect(described_class.installed_path(dir: tmp_dir)).to be_nil
    end

    it 'defaults to vendor/claude under the current working directory' do
      Dir.chdir(tmp_dir) do
        stub_http
        described_class.install(dir: File.join(tmp_dir, 'vendor', 'claude'))

        expect(described_class.installed_path).to eq(File.join(File.realpath(tmp_dir), 'vendor', 'claude', 'claude'))
      end
    end
  end

  describe 'Metadata' do
    it 'writes atomically via an unpredictable temp file and leaves none behind' do
      FileUtils.mkdir_p(tmp_dir)

      metadata.write(tmp_dir, '2.1.220', checksum)

      expect(File.read(version_path)).to eq("2.1.220\n#{checksum}\n")
      expect(Dir.children(tmp_dir)).to contain_exactly('VERSION')
    end

    it 'round-trips version and checksum' do
      metadata.write(tmp_dir, '2.1.220', checksum)

      expect(metadata.read(tmp_dir)).to eq({ version: '2.1.220', checksum: checksum })
    end

    it 'reads nil for a missing, legacy or corrupt file' do
      expect(metadata.read(tmp_dir)).to be_nil

      File.write(version_path, "2.1.220\n")
      expect(metadata.read(tmp_dir)).to be_nil

      File.write(version_path, "2.1.220\nnot-a-sha\n")
      expect(metadata.read(tmp_dir)).to be_nil

      File.write(version_path, "<html>\n#{checksum}\n")
      expect(metadata.read(tmp_dir)).to be_nil
    end
  end
end
