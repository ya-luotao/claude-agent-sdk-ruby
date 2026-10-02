# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'json'
require 'tmpdir'

# Durability of CLIInstaller's publish step. rename() is atomic for concurrent
# readers and across a process crash, but across a power loss it only orders
# metadata: unless the bytes were fsynced first, the published name can come
# back pointing at an empty or partial file — a zero-length executable
# `claude` beside a VERSION that names it, which lock-free discovery then
# hands out. Nothing was fsynced before.
#
# A power cut cannot be staged in a spec, so these examples spy on fsync and
# rename and check that the syncs happen, and where in the sequence.
RSpec.describe ClaudeAgentSDK::CLIInstaller, 'durability of the publish step' do
  let(:base) { 'https://downloads.claude.ai/claude-code-releases' }
  let(:http) { ClaudeAgentSDK::CLIInstaller::Http }
  let(:metadata) { ClaudeAgentSDK::CLIInstaller::Metadata }
  let(:dir) { @dir }
  let(:binary_path) { File.join(dir, 'claude') }
  # [:fsync, name, size at that moment], [:fsync_failed, name] and
  # [:rename, from, to], in order; the random part of a temp name is replaced
  # by <hex>.
  let(:events) { [] }

  around do |example|
    Dir.mktmpdir('cli-installer-durability') do |tmp|
      @dir = File.join(tmp, 'vendor', 'claude')
      example.run
    end
  end

  def label(path)
    return 'the install directory' if File.expand_path(path) == dir

    File.basename(path).sub(/[0-9a-f]{16}/, '<hex>')
  end

  # Records every fsync and every rename, then lets the real one run.
  # +failing+ maps a label to the error its fsync raises instead.
  def spy_on_syncs_and_renames(failing: {})
    spy_on_fsync(failing)
    log = events
    labeller = method(:label)
    allow(File).to receive(:rename).and_wrap_original do |original, from, to|
      original.call(from, to)
      log << [:rename, labeller.call(from), labeller.call(to)]
      0
    end
  end

  def spy_on_fsync(failing)
    log = events
    labeller = method(:label)
    allow_any_instance_of(File).to receive(:fsync).and_wrap_original do |original, *args|
      path = original.receiver.path
      name = labeller.call(path)
      if failing.key?(name)
        log << [:fsync_failed, name]
        raise failing[name]
      end

      original.call(*args).tap { log << [:fsync, name, File.directory?(path) ? nil : File.size(path)] }
    end
  end

  # The manifest GET is stubbed at Http.fetch_text; the binary comes through
  # the real Http.download_to (only the response is canned), so the file is
  # written and synced by the code under test.
  def stub_release(version:, body:)
    allow(ClaudeAgentSDK::CLIInstaller::Platform).to receive(:detect).and_return('linux-x64')
    allow(http).to receive(:fetch_text).with("#{base}/#{version}/manifest.json", any_args).and_return(
      JSON.generate('platforms' => { 'linux-x64' => { 'checksum' => Digest::SHA256.hexdigest(body),
                                                      'size' => body.bytesize } })
    )
    response = Object.new
    response.define_singleton_method(:read_body) { |&chunk| body.scan(/.{1,7}/m).each(&chunk) }
    allow(http).to receive(:with_response) { |_url, &handler| handler.call(response) }
  end

  it 'syncs the download and the metadata before their renames, and the directory after the last one' do
    body = 'not-really-280MB-of-claude'
    stub_release(version: '2.1.220', body: body)
    spy_on_syncs_and_renames

    expect(described_class.install(version: '2.1.220', dir: dir)).to eq(binary_path)

    metadata_size = "2.1.220\n#{Digest::SHA256.hexdigest(body)}\nlinux-x64\n".bytesize
    expect(events).to eq(
      [
        [:fsync, 'claude.download.<hex>', body.bytesize],
        [:fsync, 'VERSION.<hex>.tmp', metadata_size],
        [:rename, 'VERSION.<hex>.tmp', 'VERSION'],
        [:rename, 'claude.download.<hex>', 'claude'],
        [:fsync, 'the install directory', nil]
      ]
    )
  end

  it 'syncs nothing on the idempotent shortcut, which writes nothing' do
    stub_release(version: '2.1.220', body: 'not-really-280MB-of-claude')
    described_class.install(version: '2.1.220', dir: dir)
    spy_on_syncs_and_renames

    described_class.install(version: '2.1.220', dir: dir)

    expect(events).to be_empty
  end

  # After the rename nothing may fail the install: the binary is published and
  # VERSION vouches for it. Platforms and filesystems that cannot fsync a
  # directory say so in different ways.
  [Errno::EINVAL, Errno::EACCES, Errno::EBADF, Errno::ENOTSUP, IOError, NotImplementedError].each do |error|
    it "still succeeds when the directory cannot be synced (#{error})" do
      stub_release(version: '2.1.220', body: 'not-really-280MB-of-claude')
      spy_on_syncs_and_renames(failing: { 'the install directory' => error })

      expect(described_class.install(version: '2.1.220', dir: dir)).to eq(binary_path)
      expect(File.binread(binary_path)).to eq('not-really-280MB-of-claude')
      expect(events.last(2)).to eq([[:rename, 'claude.download.<hex>', 'claude'],
                                    [:fsync_failed, 'the install directory']])
    end
  end

  it 'still succeeds when the directory cannot even be opened for the sync' do
    stub_release(version: '2.1.220', body: 'not-really-280MB-of-claude')
    spy_on_syncs_and_renames
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(dir, File::RDONLY).and_raise(Errno::EACCES.new(dir))

    expect(described_class.install(version: '2.1.220', dir: dir)).to eq(binary_path)
    expect(File).to have_received(:open).with(dir, File::RDONLY)
    expect(events.last).to eq([:rename, 'claude.download.<hex>', 'claude'])
  end

  context 'with a working install in place' do
    before do
      stub_release(version: '2.1.220', body: 'the installed build')
      described_class.install(version: '2.1.220', dir: dir)
      stub_release(version: '2.1.226', body: 'a newer build')
    end

    def expect_previous_install_intact
      expect(File.binread(binary_path)).to eq('the installed build')
      expect(metadata.read(dir)).to include(version: '2.1.220')
      expect(Dir.children(dir)).to contain_exactly('.install.lock', 'VERSION', 'claude')
    end

    it 'fails the upgrade, publishing nothing, when the download cannot be synced' do
      spy_on_syncs_and_renames(failing: { 'claude.download.<hex>' => Errno::EIO })

      expect { described_class.install(version: '2.1.226', dir: dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Errno::EIO/)

      expect(events).to eq([[:fsync_failed, 'claude.download.<hex>']])
      expect_previous_install_intact
    end

    it 'fails the upgrade, publishing nothing, when the metadata cannot be synced' do
      spy_on_syncs_and_renames(failing: { 'VERSION.<hex>.tmp' => Errno::EIO })

      expect { described_class.install(version: '2.1.226', dir: dir) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /Errno::EIO/)

      expect(events).to eq([[:fsync, 'claude.download.<hex>', 'a newer build'.bytesize],
                            [:fsync_failed, 'VERSION.<hex>.tmp']])
      expect_previous_install_intact
    end
  end
end
