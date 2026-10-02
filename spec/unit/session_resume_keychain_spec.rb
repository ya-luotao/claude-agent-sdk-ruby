# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'

# The macOS Keychain bridge of store-backed resume. On macOS the CLI keeps its
# OAuth credentials in the Keychain rather than in .credentials.json, so
# materialization copies them (minus the refresh token) into the temp config
# dir the resumed subprocess runs against.
#
# No example here runs the real `security` binary or reads a real Keychain.
# The bridge is reached through materialize_resume_session — a stub of
# read_keychain_credentials would hide a wiring regression — and the layer
# below it, capture_with_timeout, is replaced by a recorder that answers like
# `security find-generic-password -w` does. capture_with_timeout itself is
# exercised against a real child process that is not `security`.
#
# `keychain: true` opts out of a default stub of read_keychain_credentials
# (session_resume_spec.rb installs one).
RSpec.describe ClaudeAgentSDK::SessionResume, keychain: true do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:cwd) { Dir.mktmpdir }
  let(:home) { Dir.mktmpdir }
  let(:sid) { SecureRandom.uuid }
  let(:security_calls) { [] }
  let(:materializations) { [] }

  # What the CLI stores in the Keychain item (values are fake).
  let(:oauth) do
    { 'accessToken' => 'fake-access-token', 'refreshToken' => 'fake-refresh-token',
      'expiresAt' => 1_790_000_000_000, 'scopes' => %w[user:inference user:profile],
      'subscriptionType' => 'max', 'rateLimitTier' => 'default_claude_max_20x' }
  end
  let(:keychain_payload) { JSON.generate('claudeAiOauth' => oauth) }

  # The bridge keys off the environment the CHILD will see, which falls back to
  # the parent's for every key options.env does not set. Pin the ones it reads,
  # so the examples behave the same on any machine: a shell or CI job exporting
  # ANTHROPIC_API_KEY would otherwise skip the bridge altogether.
  around do |example|
    names = %w[CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN USER]
    saved = names.to_h { |name| [name, ENV.fetch(name, nil)] }
    names.each { |name| ENV.delete(name) }
    ENV['USER'] = 'spec-user'
    example.run
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : (ENV[name] = value) }
  end

  before do
    stub_host_os('darwin24') # the bridge is a no-op elsewhere, and CI runs on Linux
    store.append({ 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => sid },
                 [{ 'parentUuid' => nil, 'isSidechain' => false, 'userType' => 'external', 'cwd' => cwd,
                    'sessionId' => sid, 'version' => '2.1.286', 'gitBranch' => 'main', 'type' => 'user',
                    'message' => { 'role' => 'user', 'content' => 'hello' }, 'uuid' => SecureRandom.uuid,
                    'timestamp' => '2026-09-01T12:00:00.000Z' }])
  end

  after do
    materializations.each(&:cleanup)
    [cwd, home].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def stub_host_os(host_os)
    allow(RbConfig::CONFIG).to receive(:[]).and_call_original
    allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return(host_os)
  end

  # Stand-in for `security find-generic-password -w`, which prints the secret
  # and a newline and exits 0 on a hit, and prints nothing and exits non-zero
  # when the item does not exist. +exit_ok+ nil is capture_with_timeout's own
  # answer for a command that timed out or could not be run: [nil, nil].
  def stub_security(stdout, exit_ok)
    status = exit_ok.nil? ? nil : instance_double(Process::Status, success?: exit_ok)
    allow(described_class).to receive(:capture_with_timeout) do |argv, timeout_s|
      security_calls << [argv, timeout_s]
      [stdout, status]
    end
  end

  # Store-backed resume as query() and Client#connect run it. HOME is a
  # scratch directory, so nothing is seeded from the developer's own ~/.claude.
  def materialize(env = {})
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: cwd,
                                                     env: { 'HOME' => home }.merge(env))
    described_class.materialize_resume_session(options).tap { |mat| materializations << mat }
  end

  def seeded_credentials(materialized)
    File.join(materialized.config_dir, '.credentials.json')
  end

  def write_credentials_file(config_dir, access_token)
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, '.credentials.json'),
               JSON.generate('claudeAiOauth' => oauth.merge('accessToken' => access_token)))
  end

  def security_argv(service)
    ['security', 'find-generic-password', '-a', 'spec-user', '-w', '-s', service]
  end

  describe 'with the default config dir' do
    it "reads the CLI's default Keychain entry and seeds it without the refresh token, owner-only" do
      stub_security("#{keychain_payload}\n", true)

      materialized = materialize

      expect(security_calls).to eq([[security_argv('Claude Code-credentials'), described_class::KEYCHAIN_TIMEOUT_SECONDS]])
      seeded = seeded_credentials(materialized)
      expect(JSON.parse(File.read(seeded))).to eq('claudeAiOauth' => oauth.except('refreshToken'))
      expect(File.read(seeded)).not_to include('fake-refresh-token')
      expect(format('%o', File.stat(seeded).mode & 0o777)).to eq('600')
    end

    it 'lets a Keychain hit override ~/.claude/.credentials.json' do
      write_credentials_file(File.join(home, '.claude'), 'from-the-file')
      stub_security("#{keychain_payload}\n", true)

      materialized = materialize

      expect(JSON.parse(File.read(seeded_credentials(materialized))).dig('claudeAiOauth', 'accessToken'))
        .to eq('fake-access-token')
    end

    it 'falls back to ~/.claude/.credentials.json when the Keychain has no entry' do
      write_credentials_file(File.join(home, '.claude'), 'from-the-file')
      stub_security('', false)

      materialized = materialize

      expect(security_calls.length).to eq(1)
      expect(JSON.parse(File.read(seeded_credentials(materialized))))
        .to eq('claudeAiOauth' => oauth.except('refreshToken').merge('accessToken' => 'from-the-file'))
    end

    {
      'the lookup exits non-zero (no such entry)' => ['', false],
      'the entry is empty' => ["\n", true],
      'the lookup times out or cannot be run' => [nil, nil]
    }.each do |outcome, (stdout, exit_ok)|
      it "seeds no credentials file when #{outcome}, and still materializes the transcript" do
        stub_security(stdout, exit_ok)

        materialized = materialize

        expect(security_calls.length).to eq(1)
        expect(File).not_to exist(seeded_credentials(materialized))
        expect(Dir.glob(File.join(materialized.config_dir, 'projects', '*', "#{sid}.jsonl")).length).to eq(1)
      end
    end

    %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN].each do |name|
      it "leaves the Keychain alone when options.env carries #{name}" do
        stub_security("#{keychain_payload}\n", true)

        materialized = materialize(name => 'from-the-env')

        expect(security_calls).to be_empty
        expect(File).not_to exist(seeded_credentials(materialized))
      end

      it "leaves the Keychain alone when the child inherits #{name} from the parent" do
        stub_security("#{keychain_payload}\n", true)
        ENV[name] = 'from-the-env'

        materialize

        expect(security_calls).to be_empty
      end
    end

    it 'leaves the Keychain alone off macOS' do
      stub_host_os('linux-gnu')
      stub_security("#{keychain_payload}\n", true)

      materialized = materialize

      expect(security_calls).to be_empty
      expect(File).not_to exist(seeded_credentials(materialized))
    end
  end

  describe '.capture_with_timeout' do
    # A real child process (never `security`). A child that is expected to exit
    # gets a deadline it cannot plausibly miss — the call returns the moment it
    # exits — so machine load never decides the outcome; only the child that
    # never exits meets a short one.
    let(:ample) { 120 }

    def ruby_child(script)
      [RbConfig.ruby, '--disable-gems', '-e', script]
    end

    def capture(argv, timeout_s)
      described_class.send(:capture_with_timeout, argv, timeout_s)
    end

    it "returns the child's stdout and a successful status" do
      stdout, status = capture(ruby_child('print "from the child"'), ample)

      expect(stdout).to eq('from the child')
      expect(status).to be_success
    end

    it 'returns everything a child wrote, past the size of a pipe buffer' do
      stdout, status = capture(ruby_child('print "x" * 300_000'), ample)

      expect(stdout.bytesize).to eq(300_000)
      expect(status).to be_success
    end

    it 'returns the output and the failed status of a child that exits non-zero' do
      stdout, status = capture(ruby_child('print "partial"; exit 3'), ample)

      expect(stdout).to eq('partial')
      expect(status.exitstatus).to eq(3)
      expect(status).not_to be_success
    end

    it 'kills and reaps a child that outlives the deadline, returning [nil, nil]' do
      waiter = nil
      allow(Open3).to receive(:popen3).and_wrap_original do |original, *argv|
        streams_and_waiter = original.call(*argv)
        waiter = streams_and_waiter.last
        streams_and_waiter
      end

      expect(capture(ruby_child('sleep'), 0.05)).to eq([nil, nil])
      expect(waiter).not_to be_alive # already reaped: no zombie, no stray `security`
      expect(waiter.value.termsig).to eq(Signal.list['KILL'])
    end

    it 'returns [nil, nil] for a command that cannot be spawned' do
      expect(capture([File.join(home, 'no-such-command')], ample)).to eq([nil, nil])
    end
  end
end
