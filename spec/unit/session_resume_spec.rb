# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'
require 'json'
require 'fileutils'

RSpec.describe ClaudeAgentSDK::SessionResume do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:cwd) { Dir.mktmpdir }
  let(:project_key) { ClaudeAgentSDK.project_key_for_directory(cwd) }
  let(:sid) { SecureRandom.uuid }

  after { FileUtils.remove_entry(cwd) if File.directory?(cwd) }

  def entry(text, **extra)
    { 'type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => text } }.merge(extra)
  end

  describe '.safe_subpath?' do
    let(:session_dir) { '/tmp/some-session-dir' }

    {
      'subagents/agent-1' => true,
      'subagents/workflows/run1/agent-2' => true,
      '' => false,
      '/abs/path' => false,
      '\\\\unc\\share' => false,
      'C:foo' => false,
      '../escape' => false,
      'a/../../b' => false,
      'ok/./still' => false,
      # Tilde must not be expanded: '~nosuchuser/x' used to raise ArgumentError
      # out of File.expand_path (aborting the whole resume), and '~root/x' used
      # to be wrongly rejected even though the writer joins it literally under
      # session_dir.
      '~nosuchuser-zz/agent-1' => true,
      '~root/agent-1' => true,
      "embeds\u0000nul" => false
    }.each do |subpath, expected|
      it "returns #{expected} for #{subpath.inspect}" do
        expect(described_class.safe_subpath?(subpath, session_dir)).to eq(expected)
      end
    end
  end

  describe '.write_redacted_credentials' do
    it 'strips claudeAiOauth.refreshToken, keeps other fields, writes mode 0600' do
      dir = Dir.mktmpdir
      dst = File.join(dir, '.credentials.json')
      json = JSON.generate('claudeAiOauth' => { 'accessToken' => 'keep', 'refreshToken' => 'SECRET' })
      described_class.send(:write_redacted_credentials, json, dst)

      written = JSON.parse(File.read(dst))
      expect(written['claudeAiOauth']).not_to have_key('refreshToken')
      expect(written['claudeAiOauth']['accessToken']).to eq('keep')
      expect(format('%o', File.stat(dst).mode & 0o777)).to eq('600')
    ensure
      FileUtils.remove_entry(dir)
    end

    it 'is a no-op when credentials are nil and passes through unparseable JSON' do
      dir = Dir.mktmpdir
      dst = File.join(dir, '.credentials.json')
      described_class.send(:write_redacted_credentials, nil, dst)
      expect(File.exist?(dst)).to be false

      described_class.send(:write_redacted_credentials, 'not json', dst)
      expect(File.read(dst)).to eq('not json')
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe '.copy_auth_files' do
    around do |example|
      previous_config = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
      example.run
    ensure
      previous_config.nil? ? ENV.delete('CLAUDE_CONFIG_DIR') : (ENV['CLAUDE_CONFIG_DIR'] = previous_config)
    end

    it 'reads from the parent ENV config dir when options.env has no override key' do
      source = Dir.mktmpdir
      target = Dir.mktmpdir
      File.write(File.join(source, '.credentials.json'),
                 JSON.generate('claudeAiOauth' => { 'accessToken' => 'keep', 'refreshToken' => 'drop' }))
      File.write(File.join(source, '.claude.json'), JSON.generate('settings' => true))
      ENV['CLAUDE_CONFIG_DIR'] = source

      allow(described_class).to receive(:read_keychain_credentials).and_return(nil)
      described_class.send(:copy_auth_files, target, {})

      creds = JSON.parse(File.read(File.join(target, '.credentials.json')))
      expect(creds['claudeAiOauth']['accessToken']).to eq('keep')
      expect(creds['claudeAiOauth']).not_to have_key('refreshToken')
      expect(File.exist?(File.join(target, '.claude.json'))).to be true
    ensure
      FileUtils.remove_entry(source) if source && File.directory?(source)
      FileUtils.remove_entry(target) if target && File.directory?(target)
    end

    it 'ignores the parent ENV config dir when options.env explicitly unsets CLAUDE_CONFIG_DIR' do
      # An explicit nil/empty override means the transport unsets the var for
      # the child, which then reads ~/.claude — NOT the parent's config dir.
      # Credentials must be sourced from where the child will actually look.
      source = Dir.mktmpdir
      target = Dir.mktmpdir
      File.write(File.join(source, '.credentials.json'), JSON.generate('claudeAiOauth' => { 'accessToken' => 'k' }))
      ENV['CLAUDE_CONFIG_DIR'] = source

      allow(described_class).to receive(:read_keychain_credentials).and_return(nil)
      allow(described_class).to receive(:read_file_if_present).and_return(nil)
      allow(described_class).to receive(:copy_if_present).and_return(nil)
      described_class.send(:copy_auth_files, target, 'CLAUDE_CONFIG_DIR' => '')

      default_dir = File.join(Dir.home, '.claude')
      expect(described_class).to have_received(:read_file_if_present)
        .with(File.join(default_dir, '.credentials.json'))
      expect(described_class).not_to have_received(:read_file_if_present)
        .with(File.join(source, '.credentials.json'))
    ensure
      FileUtils.remove_entry(source) if source && File.directory?(source)
      FileUtils.remove_entry(target) if target && File.directory?(target)
    end
  end

  describe '.rmtree_with_retry' do
    it 'removes an existing directory and is a no-op for a missing path' do
      dir = Dir.mktmpdir
      File.write(File.join(dir, 'f'), 'x')
      described_class.rmtree_with_retry(dir)
      expect(File.exist?(dir)).to be false
      expect { described_class.rmtree_with_retry(dir) }.not_to raise_error
    end
  end

  describe '.apply_materialized_options' do
    it 'repoints env CLAUDE_CONFIG_DIR, sets resume, and clears continue_conversation' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, continue_conversation: true,
                                                       env: { 'FOO' => 'bar' })
      materialized = ClaudeAgentSDK::MaterializedResume.new(config_dir: '/tmp/mat', resume_session_id: sid)
      applied = described_class.apply_materialized_options(options, materialized)

      expect(applied.env['CLAUDE_CONFIG_DIR']).to eq('/tmp/mat')
      expect(applied.env['FOO']).to eq('bar') # preserves existing env
      expect(applied.resume).to eq(sid)
      expect(applied.continue_conversation).to be false
      expect(options.resume).to be_nil # original options unchanged
    end
  end

  describe '.materialize_resume_session' do
    it 'returns nil when no materialization applies' do
      expect(described_class.materialize_resume_session(
               ClaudeAgentSDK::ClaudeAgentOptions.new(resume: sid, cwd: cwd)
             )).to be_nil
      expect(described_class.materialize_resume_session(
               ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: 'not-a-uuid', cwd: cwd)
             )).to be_nil
      expect(described_class.materialize_resume_session(
               ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, cwd: cwd)
             )).to be_nil
    end

    it 'writes the session transcript and subagent transcript+meta to a temp config dir' do
      store.append({ 'project_key' => project_key, 'session_id' => sid }, [entry('hi', 'timestamp' => '2024-01-01T00:00:00Z')])
      store.append({ 'project_key' => project_key, 'session_id' => sid, 'subpath' => 'subagents/agent-x' },
                   [{ 'type' => 'agent_metadata', 'agentId' => 'x' }, entry('sub')])

      mat = described_class.materialize_resume_session(
        ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: cwd)
      )
      begin
        expect(mat.resume_session_id).to eq(sid)
        base = File.join(mat.config_dir, 'projects', project_key)
        expect(File.exist?(File.join(base, "#{sid}.jsonl"))).to be true
        sub = File.join(base, sid, 'subagents', 'agent-x.jsonl')
        expect(File.exist?(sub)).to be true
        expect(File.read(sub)).not_to include('agent_metadata') # synthetic entry excluded from transcript
        expect(File.exist?(File.join(base, sid, 'subagents', 'agent-x.meta.json'))).to be true
      ensure
        mat.cleanup
      end
      expect(File.exist?(mat.config_dir)).to be false # cleanup removed it
    end

    it 'removes the credential-bearing temp dir when materialization fails after mkdtemp' do
      store.append({ 'project_key' => project_key, 'session_id' => sid }, [entry('hi')])
      # A store that writes the main transcript fine but explodes in list_subkeys,
      # i.e. AFTER Dir.mktmpdir + transcript/credentials are written. The rescue
      # Exception path must remove tmp_base so no temp dir (holding a credential
      # copy) is leaked.
      exploding = Class.new(ClaudeAgentSDK::SessionStore) do
        def initialize(inner)
          super()
          @inner = inner
        end

        def append(key, entries) = @inner.append(key, entries)
        def load(key) = @inner.load(key)
        def list_subkeys(_key) = raise('boom in list_subkeys')
      end.new(store)

      before = Dir.glob(File.join(Dir.tmpdir, 'claude-resume-*'))
      expect do
        described_class.materialize_resume_session(
          ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: exploding, resume: sid, cwd: cwd)
        )
      end.to raise_error(StandardError)
      leaked = Dir.glob(File.join(Dir.tmpdir, 'claude-resume-*')) - before
      expect(leaked).to eq([]) # temp dir (and its .credentials.json copy) was cleaned up
    end

    it 'for continue_conversation picks the newest non-sidechain session' do
      old_sid = SecureRandom.uuid
      new_sid = SecureRandom.uuid
      side_sid = SecureRandom.uuid
      store.append({ 'project_key' => project_key, 'session_id' => old_sid }, [entry('old')])
      sleep 0.002
      store.append({ 'project_key' => project_key, 'session_id' => new_sid }, [entry('new')])
      sleep 0.002
      # Newest by mtime, but a sidechain — must be skipped.
      store.append({ 'project_key' => project_key, 'session_id' => side_sid }, [entry('side', 'isSidechain' => true)])

      mat = described_class.materialize_resume_session(
        ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, continue_conversation: true, cwd: cwd)
      )
      begin
        expect(mat.resume_session_id).to eq(new_sid)
      ensure
        mat&.cleanup
      end
    end

    # Regression (H4): the contract says mtime is an epoch-ms Numeric, but a
    # SQL-timestamp-through-JSON adapter naturally returns ISO-8601 Strings.
    # Unary minus on a String is String#-@ (frozen dedup), so String mtimes
    # sorted lexicographically ASCENDING and --continue silently resumed the
    # OLDEST session; mixed Integer/String lists raised a bare ArgumentError.
    it 'for continue_conversation orders String mtimes chronologically (ISO-8601 and numeric strings)' do
      old_sid = SecureRandom.uuid
      new_sid = SecureRandom.uuid
      mid_sid = SecureRandom.uuid
      store.append({ 'project_key' => project_key, 'session_id' => old_sid }, [entry('old')])
      store.append({ 'project_key' => project_key, 'session_id' => new_sid }, [entry('new')])
      store.append({ 'project_key' => project_key, 'session_id' => mid_sid }, [entry('mid')])

      string_mtime_store = Class.new(ClaudeAgentSDK::SessionStore) do
        def initialize(inner, mtimes)
          super()
          @inner = inner
          @mtimes = mtimes
        end

        def append(key, entries) = @inner.append(key, entries)
        def load(key) = @inner.load(key)
        def list_subkeys(key) = @inner.list_subkeys(key)

        def list_sessions(project_key)
          @inner.list_sessions(project_key).map { |s| s.merge('mtime' => @mtimes.fetch(s['session_id'])) }
        end
      end.new(store, {
                old_sid => '2024-01-01T00:00:00Z',
                new_sid => '2024-06-01T00:00:00Z',
                mid_sid => (Time.utc(2024, 3, 1).to_f * 1000).to_i # mixed types must not raise
              })

      mat = described_class.materialize_resume_session(
        ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: string_mtime_store, continue_conversation: true, cwd: cwd)
      )
      begin
        expect(mat.resume_session_id).to eq(new_sid)
      ensure
        mat&.cleanup
      end
    end

    it 'enforces load_timeout_ms even without an Async reactor (hung adapter raises)' do
      slow = Class.new(ClaudeAgentSDK::SessionStore) do
        def append(_key, _entries); end

        def load(_key)
          sleep 2
          [{ 'type' => 'user', 'uuid' => 'x' }]
        end
      end.new

      expect(Fiber.scheduler).to be_nil # this example runs outside any reactor
      expect do
        described_class.materialize_resume_session(
          ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: slow, resume: sid, cwd: cwd, load_timeout_ms: 50)
        )
      end.to raise_error(RuntimeError, /timed out after 50ms/)
    end
  end

  describe 'Client resume gating' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: cwd) }

    before do
      store.append({ 'project_key' => project_key, 'session_id' => sid }, [entry('hi')])
    end

    it 'materializes for the default subprocess transport' do
      client = ClaudeAgentSDK::Client.new(options: options)
      result = client.send(:materialize_resume, options)
      materialized = client.instance_variable_get(:@materialized)
      begin
        expect(materialized).to be_a(ClaudeAgentSDK::MaterializedResume)
        expect(result.resume).to eq(sid)
        expect(result.env['CLAUDE_CONFIG_DIR']).to eq(materialized.config_dir.to_s)
      ensure
        materialized&.cleanup
      end
    end

    it 'skips materialization for a custom transport class' do
      custom = Class.new(ClaudeAgentSDK::Transport)
      client = ClaudeAgentSDK::Client.new(options: options, transport_class: custom)
      result = client.send(:materialize_resume, options)
      expect(result).to be(options) # unchanged
      expect(client.instance_variable_get(:@materialized)).to be_nil
    end

    it 'cleans up the materialized temp dir when connect fails with a non-StandardError' do
      # Async::Stop (reactor cancellation) is an Exception, NOT a StandardError.
      # `rescue StandardError` would let it skip disconnect and leak the temp dir
      # (with its .credentials.json copy); `rescue Exception` cleans it up.
      client = ClaudeAgentSDK::Client.new(options: options)
      # Intentionally NOT a StandardError: this is what reactor cancellation
      # (Async::Stop) looks like, the exact case `rescue StandardError` misses.
      cancellation = Class.new(Exception) # rubocop:disable Lint/InheritException
      allow(client).to receive(:connect_inner).and_raise(cancellation)

      before = Dir.glob(File.join(Dir.tmpdir, 'claude-resume-*'))
      expect { client.connect }.to raise_error(cancellation)
      leaked = Dir.glob(File.join(Dir.tmpdir, 'claude-resume-*')) - before
      expect(leaked).to eq([]) # materialized temp dir removed despite the non-StandardError
      expect(client.instance_variable_get(:@materialized)).to be_nil
    end
  end
end
