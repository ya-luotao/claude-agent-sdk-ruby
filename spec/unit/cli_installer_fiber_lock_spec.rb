# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# CLIInstaller.install called from two fibers of ONE reactor, into one
# directory. The install lock used to be a blocking flock(LOCK_EX), and
# File#flock has no Fiber-scheduler hook: the second fiber blocked the reactor
# THREAD while the first one — the lock holder — was parked in a
# scheduler-aware wait inside the critical section, so the holder was never
# resumed and neither install returned.
#
# Runs in a child process: when this regresses, the thread that calls install
# blocks forever, which in-process would hang the suite instead of failing it.
RSpec.describe ClaudeAgentSDK::CLIInstaller, 'called from two fibers of one reactor' do
  # The child's own watchdog fires first and says where the reactor thread is
  # stuck; the parent's bound only covers a child that cannot even do that.
  # Both are far above the fraction of a second the installs take.
  child_watchdog_seconds = 30
  parent_bound_seconds = 120

  # ARGV: the install directory and the point inside the critical section
  # where the lock holder waits for the second fiber ('download' or 'resolve').
  # HTTP is replaced at the Http module level, as in cli_installer_spec.rb.
  child_script = <<~RUBY
    require 'async'
    require 'claude_agent_sdk/cli_installer'
    require 'digest'
    require 'json'

    dir, parking_point = ARGV
    installer = ClaudeAgentSDK::CLIInstaller
    body = 'not-really-280MB-of-claude'
    manifest = JSON.generate(
      'platforms' => { 'linux-x64' => { 'checksum' => Digest::SHA256.hexdigest(body), 'size' => body.bytesize } }
    )
    # Closed by the second fiber on its way to the lock. Until then the lock
    # holder is parked on it — a scheduler-aware wait inside the critical
    # section, which is what the real socket read is. Once closed, pop returns
    # at once, so the second fiber never parks here itself.
    gate = Thread::Queue.new
    downloads = 0

    installer::Platform.define_singleton_method(:detect) { 'linux-x64' }
    installer::Http.define_singleton_method(:fetch_text) do |url, limit:|
      if url.end_with?('/stable')
        gate.pop if parking_point == 'resolve'
        "2.1.220\\n"
      elsif url.end_with?('/2.1.220/manifest.json')
        manifest
      else
        raise "unexpected fetch_text(\#{url.inspect})"
      end
    end
    installer::Http.define_singleton_method(:download_to) do |_url, path, max_bytes: nil|
      downloads += 1
      gate.pop if parking_point == 'download'
      File.binwrite(path, body)
      path
    end

    # A regression blocks the reactor thread inside File#flock, which releases
    # the GVL — this thread still runs and can report where the main one is.
    Thread.new do
      sleep #{child_watchdog_seconds}
      warn "DEADLOCK: neither install returned; main thread at \#{Thread.main.backtrace.first(2).join(' <- ')}"
      exit!(3)
    end

    # 'resolve': the pinned version is already installed, and both fibers ask
    # for the dist-tag — nothing needs installing, yet the tag is resolved
    # inside the lock, so the holder still waits on the network there.
    installer.install(version: '2.1.220', dir: dir) if parking_point == 'resolve'
    version = parking_point == 'resolve' ? 'stable' : '2.1.220'

    paths = Async do |task|
      first = task.async { installer.install(version: version, dir: dir) }
      second = task.async do
        gate.close
        installer.install(version: version, dir: dir)
      end
      [first.wait, second.wait]
    end.wait

    puts "paths=\#{paths.inspect} downloads=\#{downloads}"
  RUBY

  around do |example|
    # Created (and removed) here rather than in the child, so a child that is
    # killed mid-install leaves nothing behind.
    Dir.mktmpdir('cli-installer-fibers') do |dir|
      @dir = dir
      example.run
    end
  end

  let(:dir) { @dir }
  let(:binary_path) { File.join(dir, 'claude') }

  define_method(:run_two_fibers) do |parking_point|
    lib_dir = File.expand_path('../../lib', __dir__)
    Open3.popen3(RbConfig.ruby, '-I', lib_dir, '-e', child_script, dir, parking_point) do |stdin, stdout, stderr, waiter|
      stdin.close
      unless waiter.join(parent_bound_seconds)
        Process.kill('KILL', waiter.pid)
        waiter.join
      end
      [stdout.read, stderr.read, waiter.value]
    end
  end

  it 'finishes both installs when the lock holder is parked in its download' do
    out, err, status = run_two_fibers('download')

    expect(status.exitstatus).to eq(0), "child: #{status.inspect}\n#{err}"
    expect(out).to include("paths=#{[binary_path, binary_path].inspect} downloads=1")
    expect(File.binread(binary_path)).to eq('not-really-280MB-of-claude')
    expect(Dir.children(dir)).to contain_exactly('.install.lock', 'VERSION', 'claude')
  end

  it 'finishes both installs of an installed dist-tag while the holder resolves it' do
    out, err, status = run_two_fibers('resolve')

    expect(status.exitstatus).to eq(0), "child: #{status.inspect}\n#{err}"
    # The one download is the setup install; neither fiber needed another.
    expect(out).to include("paths=#{[binary_path, binary_path].inspect} downloads=1")
  end
end
