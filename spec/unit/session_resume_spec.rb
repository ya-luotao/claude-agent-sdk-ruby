# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'timeout'

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
      "embeds\u0000nul" => false,
      # Non-String subkeys from an adapter are a contract violation: reject
      # them (never coerce) instead of raising NoMethodError mid-resume.
      :'subagents/agent-1' => false,
      42 => false
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

    it 'seeds no credentials file when the redacted result cannot be re-serialized' do
      # JSON.parse accepts illegal UTF-8 bytes inside an otherwise well-formed
      # document, so redaction can succeed and only fail at JSON.generate.
      # Writing the original bytes through would restore the un-redacted
      # refreshToken; raising would abort a resume every other seed file is
      # careful not to abort. Seed nothing instead.
      dir = Dir.mktmpdir
      dst = File.join(dir, '.credentials.json')
      creds = %({"claudeAiOauth":{"refreshToken":"rt","note":"lat\xE9in"}}).dup.force_encoding(Encoding::UTF_8)

      expect { described_class.send(:write_redacted_credentials, creds, dst) }
        .to output(/cannot redact credentials/).to_stderr
      expect(File).not_to exist(dst)
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
      allow(described_class).to receive(:read_if_present).and_return(nil)
      allow(described_class).to receive(:copy_if_present).and_return(nil)
      described_class.send(:copy_auth_files, target, 'CLAUDE_CONFIG_DIR' => '')

      default_dir = File.join(Dir.home, '.claude')
      expect(described_class).to have_received(:read_if_present)
        .with(File.join(default_dir, '.credentials.json'))
      expect(described_class).not_to have_received(:read_if_present)
        .with(File.join(source, '.credentials.json'))
    ensure
      FileUtils.remove_entry(source) if source && File.directory?(source)
      FileUtils.remove_entry(target) if target && File.directory?(target)
    end

    context 'without a resolvable home directory (#82)' do
      around do |example|
        previous_home = ENV.fetch('HOME', nil) # rubocop:disable Style/EnvHome -- raw value; nil when unset
        example.run
      ensure
        previous_home.nil? ? ENV.delete('HOME') : (ENV['HOME'] = previous_home)
      end

      # HOME unset with no passwd entry for the uid (docker --user in a
      # minimal image): Dir.home raises ArgumentError. Stubbed because the
      # host's passwd fallback would otherwise resolve a home.
      before do
        ENV.delete('HOME')
        allow(Dir).to receive(:home).and_raise(ArgumentError, "couldn't find home for uid `4242'")
        allow(described_class).to receive(:read_keychain_credentials).and_return(nil)
      end

      it 'skips the home-relative sources instead of raising' do
        ENV.delete('CLAUDE_CONFIG_DIR')
        target = Dir.mktmpdir
        allow(described_class).to receive(:read_if_present).and_call_original
        allow(described_class).to receive(:copy_if_present).and_call_original

        expect do
          described_class.send(:copy_auth_files, target, 'ANTHROPIC_API_KEY' => 'sk-test')
        end.not_to raise_error
        expect(described_class).not_to have_received(:read_if_present)
        expect(described_class).not_to have_received(:copy_if_present)
        expect(Dir.children(target)).to eq([])
      ensure
        FileUtils.remove_entry(target) if target && File.directory?(target)
      end

      it 'still seeds from an explicit CLAUDE_CONFIG_DIR, which needs no home' do
        source = Dir.mktmpdir
        target = Dir.mktmpdir
        File.write(File.join(source, '.credentials.json'), JSON.generate('claudeAiOauth' => { 'accessToken' => 'k' }))
        File.write(File.join(source, '.claude.json'), JSON.generate('settings' => true))

        described_class.send(:copy_auth_files, target, 'CLAUDE_CONFIG_DIR' => source)

        expect(File.exist?(File.join(target, '.credentials.json'))).to be true
        expect(File.exist?(File.join(target, '.claude.json'))).to be true
      ensure
        FileUtils.remove_entry(source) if source && File.directory?(source)
        FileUtils.remove_entry(target) if target && File.directory?(target)
      end

      it 'skips the home-relative sources when HOME is not absolute' do
        # Dir.home returns HOME verbatim: "" would read /.claude/… and a
        # relative HOME would read relative to the process cwd — neither is
        # where the CLI looks.
        allow(Dir).to receive(:home).and_call_original
        ENV['HOME'] = ''
        ENV.delete('CLAUDE_CONFIG_DIR')
        target = Dir.mktmpdir
        allow(described_class).to receive(:read_if_present).and_call_original
        allow(described_class).to receive(:copy_if_present).and_call_original

        described_class.send(:copy_auth_files, target, 'ANTHROPIC_API_KEY' => 'sk-test')

        expect(described_class).not_to have_received(:read_if_present)
        expect(described_class).not_to have_received(:copy_if_present)
      ensure
        FileUtils.remove_entry(target) if target && File.directory?(target)
      end
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

    it 'proceeds on a host without a resolvable home directory under API-key auth (#82)' do
      # HOME unset with no passwd entry for the uid (docker --user in a minimal
      # image): Dir.home raises ArgumentError, which escaped copy_auth_files
      # through the rescue-Exception cleanup and aborted the resume. Stubbed
      # because the host's passwd fallback would otherwise resolve a home.
      previous_home = ENV.fetch('HOME', nil) # rubocop:disable Style/EnvHome -- raw value; nil when unset
      previous_config = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
      ENV.delete('HOME')
      ENV.delete('CLAUDE_CONFIG_DIR')
      allow(Dir).to receive(:home).and_raise(ArgumentError, "couldn't find home for uid `4242'")
      store.append({ 'project_key' => project_key, 'session_id' => sid }, [entry('hi')])
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: cwd,
                                                       env: { 'ANTHROPIC_API_KEY' => 'sk-test' })

      mat = described_class.materialize_resume_session(options)
      expect(mat.resume_session_id).to eq(sid)
      expect(File.exist?(File.join(mat.config_dir, 'projects', project_key, "#{sid}.jsonl"))).to be true
      # The rest of the store-resume path: the mirror batcher resolves its
      # projects dir from the materialized CLAUDE_CONFIG_DIR, not from ~.
      applied = described_class.apply_materialized_options(options, mat)
      expect do
        described_class.build_mirror_batcher(store: store, env: applied.env, on_error: ->(*) {})
      end.not_to raise_error
    ensure
      mat&.cleanup
      previous_home.nil? ? ENV.delete('HOME') : (ENV['HOME'] = previous_home)
      previous_config.nil? ? ENV.delete('CLAUDE_CONFIG_DIR') : (ENV['CLAUDE_CONFIG_DIR'] = previous_config)
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
      # InMemorySessionStore stamps strictly increasing mtimes per append
      # (session_store_spec), so append order is mtime order — no sleeps.
      store.append({ 'project_key' => project_key, 'session_id' => old_sid }, [entry('old')])
      store.append({ 'project_key' => project_key, 'session_id' => new_sid }, [entry('new')])
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

    # Improvement 8: with a summary sidecar available, --continue skips
    # sidechain candidates without downloading their full transcripts
    # (previously O(sum of transcript sizes) when the newest keys were
    # sidechains — common, since subagents finish last).
    it 'for continue_conversation skips sidechain candidates without loading them (summary fast path)' do
      main_sid = SecureRandom.uuid
      side_sid = SecureRandom.uuid
      store.append({ 'project_key' => project_key, 'session_id' => main_sid }, [entry('main')])
      store.append({ 'project_key' => project_key, 'session_id' => side_sid }, [entry('side', 'isSidechain' => true)])

      loads = []
      counting = Class.new(ClaudeAgentSDK::SessionStore) do
        def initialize(inner, loads)
          super()
          @inner = inner
          @loads = loads
        end

        def append(key, entries) = @inner.append(key, entries)
        def list_sessions(project_key) = @inner.list_sessions(project_key)
        def list_session_summaries(project_key) = @inner.list_session_summaries(project_key)
        def list_subkeys(key) = @inner.list_subkeys(key)

        def load(key)
          @loads << key['session_id']
          @inner.load(key)
        end
      end.new(store, loads)

      mat = described_class.materialize_resume_session(
        ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: counting, continue_conversation: true, cwd: cwd)
      )
      begin
        expect(mat.resume_session_id).to eq(main_sid)
        expect(loads).not_to include(side_sid) # skipped via the sidecar, not via a full load
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

    # Poisoned entries are served by a duck-typed store: they cannot be seeded
    # through InMemorySessionStore, whose append folds a summary over them.
    # Later sessions in +main+ are newer (mtime = insertion index).
    context 'with store entries or subkeys an adapter should never return' do
      let(:fixed_store_class) do
        Class.new do
          def initialize(main, subs = {})
            @main = main
            @subs = subs
          end

          def append(_key, _entries); end

          def load(key)
            key['subpath'] ? @subs.fetch(key['session_id'], {})[key['subpath']] : @main[key['session_id']]
          end

          def list_sessions(_project_key)
            @main.keys.each_with_index.map { |s, i| { 'session_id' => s, 'mtime' => i } }
          end

          def list_subkeys(key) = @subs.fetch(key['session_id'], {}).keys
        end
      end

      let(:good) { [entry('first', 'timestamp' => '2024-01-01T00:00:00Z'), entry('second')] }

      def poisoned_entries
        circular = { 'uuid' => 'poison-circular' }
        circular['self'] = circular
        [
          { 'uuid' => 'poison-nan', 'x' => Float::NAN },
          circular,
          { 'uuid' => 'poison-utf8', 'text' => (+"\xFF\xFE").force_encoding('UTF-8') },
          Float::INFINITY # not even a Hash: the warning must not assume one
        ]
      end

      def main_jsonl(mat, session_id)
        File.join(mat.config_dir, 'projects', project_key, "#{session_id}.jsonl")
      end

      before { allow(described_class).to receive(:copy_auth_files) }

      it 'skips unserializable entries (warning with their uuid) and writes the rest unchanged' do
        p1, p2, p3, p4 = poisoned_entries
        fixed = fixed_store_class.new(sid => [good[0], p1, p2, p3, p4, good[1]])

        mat = nil
        expect do
          mat = described_class.materialize_resume_session(
            ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: fixed, resume: sid, cwd: cwd)
          )
        end.to output(a_string_including('poison-nan', 'poison-circular', 'poison-utf8')).to_stderr
        begin
          expect(mat.resume_session_id).to eq(sid)
          expect(File.read(main_jsonl(mat, sid))).to eq("#{JSON.generate(good[0])}\n#{JSON.generate(good[1])}\n")
        ensure
          mat&.cleanup
        end
      end

      it 'treats a session whose entries are all unserializable like an empty one (nil, no temp dir leaked)' do
        fixed = fixed_store_class.new(sid => poisoned_entries)

        before = Dir.glob(File.join(Dir.tmpdir, 'claude-resume-*'))
        mat = :unset
        expect do
          mat = described_class.materialize_resume_session(
            ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: fixed, resume: sid, cwd: cwd)
          )
        end.to output(/poison-nan/).to_stderr
        expect(mat).to be_nil
        expect(Dir.glob(File.join(Dir.tmpdir, 'claude-resume-*')) - before).to eq([])
      end

      it 'for continue_conversation passes over an all-unserializable newest session' do
        older = SecureRandom.uuid
        fixed = fixed_store_class.new(older => good, sid => poisoned_entries)

        mat = nil
        expect do
          mat = described_class.materialize_resume_session(
            ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: fixed, continue_conversation: true, cwd: cwd)
          )
        end.to output(/poison-nan/).to_stderr
        begin
          expect(mat.resume_session_id).to eq(older)
        ensure
          mat&.cleanup
        end
      end

      # The sidechain check must classify from the first SURVIVING object entry:
      # reading the raw head let a poisoned (or non-Hash) first entry hide the
      # isSidechain flag carried by the rest, so --continue resumed a subagent.
      {
        'an unserializable Hash' => { 'uuid' => 'poison-head', 'x' => Float::NAN },
        'an unserializable non-Hash' => Float::INFINITY,
        'a serializable non-Hash' => 'not-an-object'
      }.each do |label, head|
        it "for continue_conversation still skips a sidechain whose first entry is #{label}" do
          main = SecureRandom.uuid
          side = [head, entry('side', 'isSidechain' => true), entry('side2', 'isSidechain' => true)]
          fixed = fixed_store_class.new(main => good, sid => side) # sid is newest

          mat = nil
          expect do
            mat = described_class.materialize_resume_session(
              ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: fixed, continue_conversation: true, cwd: cwd)
            )
          end.to output(anything).to_stderr
          begin
            expect(mat.resume_session_id).to eq(main)
          ensure
            mat&.cleanup
          end
        end
      end

      it 'skips unserializable subagent entries and an unserializable metadata sidecar' do
        fixed = fixed_store_class.new(
          { sid => good },
          { sid => {
            'subagents/agent-x' => [{ 'type' => 'agent_metadata', 'agentId' => 'x', 'n' => Float::NAN },
                                    entry('sub'), poisoned_entries[0]],
            'subagents/agent-y' => [poisoned_entries[0]]
          } }
        )

        mat = nil
        expect do
          mat = described_class.materialize_resume_session(
            ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: fixed, resume: sid, cwd: cwd)
          )
        end.to output(a_string_including('poison-nan', 'metadata')).to_stderr
        begin
          subagents = File.join(mat.config_dir, 'projects', project_key, sid, 'subagents')
          lines = File.readlines(File.join(subagents, 'agent-x.jsonl'))
          expect(lines.map { |l| JSON.parse(l)['message']['content'] }).to eq(['sub'])
          expect(File.exist?(File.join(subagents, 'agent-x.meta.json'))).to be false # unusable sidecar = absent
          expect(File.exist?(File.join(subagents, 'agent-y.jsonl'))).to be false # nothing usable, no empty file
        ensure
          mat&.cleanup
        end
      end

      it 'skips a non-String subkey instead of aborting the resume' do
        fixed = fixed_store_class.new(
          { sid => good },
          { sid => { :'subagents/agent-sym' => [entry('sym')], 'subagents/agent-ok' => [entry('ok')] } }
        )

        mat = nil
        expect do
          mat = described_class.materialize_resume_session(
            ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: fixed, resume: sid, cwd: cwd)
          )
        end.to output(/unsafe subpath.*agent-sym/).to_stderr
        begin
          subagents = File.join(mat.config_dir, 'projects', project_key, sid, 'subagents')
          expect(Dir.children(subagents)).to eq(['agent-ok.jsonl'])
        ensure
          mat&.cleanup
        end
      end
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

  # M16: when the mirror dropped batches, the materialized temp dir holds the
  # only copy of those turns (the store copy is incomplete) — teardown must
  # --- User settings seeded into the temp config dir (Python PR #1197) ---
  #
  # settings.json carries apiKeyHelper (a fourth auth mechanism alongside
  # .credentials.json / Keychain / env vars) plus env/hooks/permissions; an
  # apiKeyHelper-only host used to fail with "Not logged in" on every
  # store-backed resume because the file was never seeded.
  describe 'user settings seeding' do
    let(:source) { Dir.mktmpdir }

    around do |example|
      previous_config = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
      example.run
    ensure
      previous_config.nil? ? ENV.delete('CLAUDE_CONFIG_DIR') : (ENV['CLAUDE_CONFIG_DIR'] = previous_config)
    end

    after { FileUtils.remove_entry(source) if File.directory?(source) }

    def materialize(env: {})
      store.append({ 'project_key' => project_key, 'session_id' => sid }, [entry('hi')])
      mat = described_class.materialize_resume_session(
        ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: cwd, env: env)
      )
      expect(mat).not_to be_nil
      mat
    end

    def mode_of(path)
      format('%o', File.stat(path).mode & 0o777)
    end

    it 'seeds settings.json and cowork_settings.json byte-for-byte at 0600 inside the 0700 temp dir' do
      settings = JSON.generate('apiKeyHelper' => '/bin/print-key', 'env' => { 'FOO' => 'bar' })
      described_class::SEEDED_SETTINGS_FILES.each { |name| File.write(File.join(source, name), settings) }
      File.write(File.join(source, '.claude.json'), '{"theme":"dark"}')
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = materialize
      begin
        # Nothing to strip -> bytes copied through untouched.
        described_class::SEEDED_SETTINGS_FILES.each do |name|
          expect(File.binread(File.join(mat.config_dir, name))).to eq(settings)
        end
        expect(mode_of(mat.config_dir)).to eq('700')
        (described_class::SEEDED_SETTINGS_FILES + ['.claude.json']).each do |name|
          expect(mode_of(File.join(mat.config_dir, name))).to eq('600'), name
        end
      ensure
        mat.cleanup
      end
    end

    it 'skips a FIFO where settings.json is expected instead of blocking on it' do
      skip 'requires File.mkfifo' unless File.respond_to?(:mkfifo)

      File.mkfifo(File.join(source, 'settings.json'))
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = nil
      expect do
        Timeout.timeout(5) { mat = materialize }
      end.to output(/skipping/).to_stderr
      begin
        expect(File).not_to exist(File.join(mat.config_dir, 'settings.json'))
      ensure
        mat.cleanup
      end
    end

    it 'reads settings from the options.env config dir in preference to the parent ENV one' do
      decoy = Dir.mktmpdir
      File.write(File.join(decoy, 'settings.json'), '{"apiKeyHelper":"/from/decoy"}')
      File.write(File.join(source, 'settings.json'), '{"apiKeyHelper":"/from/options"}')
      ENV['CLAUDE_CONFIG_DIR'] = decoy

      mat = materialize(env: { 'CLAUDE_CONFIG_DIR' => source })
      begin
        expect(JSON.parse(File.read(File.join(mat.config_dir, 'settings.json'))))
          .to eq('apiKeyHelper' => '/from/options')
      ensure
        mat.cleanup
        FileUtils.remove_entry(decoy)
      end
    end

    it 'reads settings from the parent ENV config dir when options.env has no override' do
      File.write(File.join(source, 'settings.json'), '{"apiKeyHelper":"/from/env"}')
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = materialize
      begin
        expect(JSON.parse(File.read(File.join(mat.config_dir, 'settings.json'))))
          .to eq('apiKeyHelper' => '/from/env')
      ensure
        mat.cleanup
      end
    end

    it 'writes nothing when the source settings files are absent' do
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = materialize
      begin
        (described_class::SEEDED_SETTINGS_FILES + ['.claude.json']).each do |name|
          expect(File).not_to exist(File.join(mat.config_dir, name))
        end
      ensure
        mat.cleanup
      end
    end

    it 'strips plugin declarations and env.CLAUDE_CONFIG_DIR, tolerating a UTF-8 BOM' do
      original = {
        'apiKeyHelper' => '/bin/print-key',
        'enabledPlugins' => { 'p@m' => true },
        'extraKnownMarketplaces' => { 'm' => { 'source' => 'github', 'repo' => 'o/r' } },
        'env' => { 'CLAUDE_CONFIG_DIR' => '/elsewhere', 'KEEP' => '1' },
        'permissions' => { 'allow' => ['Bash(ls)'] }
      }
      described_class::SEEDED_SETTINGS_FILES.each do |name|
        File.binwrite(File.join(source, name), "\xEF\xBB\xBF".b + JSON.generate(original))
      end
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = materialize
      begin
        described_class::SEEDED_SETTINGS_FILES.each do |name|
          expect(JSON.parse(File.read(File.join(mat.config_dir, name)))).to eq(
            'apiKeyHelper' => '/bin/print-key',
            'env' => { 'KEEP' => '1' },
            'permissions' => { 'allow' => ['Bash(ls)'] }
          ), name
        end
      ensure
        mat.cleanup
      end
    end

    it 'copies malformed, non-object, and non-object-env settings through byte-for-byte' do
      File.binwrite(File.join(source, 'settings.json'), '{not json')
      File.binwrite(File.join(source, 'cowork_settings.json'), '{"env": "nope", "a": 1}')
      File.binwrite(File.join(source, '.claude.json'), '[1, 2]')
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = materialize
      begin
        expect(File.binread(File.join(mat.config_dir, 'settings.json'))).to eq('{not json')
        expect(File.binread(File.join(mat.config_dir, 'cowork_settings.json'))).to eq('{"env": "nope", "a": 1}')
        expect(File.binread(File.join(mat.config_dir, '.claude.json'))).to eq('[1, 2]')
      ensure
        mat.cleanup
      end
    end

    it 'falls back to the original bytes when a stripped settings file cannot be re-serialized' do
      # 1e999 is valid JSON that parses to Infinity; re-serializing it would
      # emit a bare Infinity token the CLI rejects, so the transform gives up.
      raw = '{"enabledPlugins": {"p@m": true}, "threshold": 1e999}'
      File.binwrite(File.join(source, 'settings.json'), raw)
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = materialize
      begin
        expect(File.binread(File.join(mat.config_dir, 'settings.json'))).to eq(raw)
      ensure
        mat.cleanup
      end
    end

    it 'does not abort the resume when the credentials file holds illegal UTF-8 bytes' do
      File.binwrite(File.join(source, '.credentials.json'),
                    %({"claudeAiOauth":{"refreshToken":"rt","note":"lat\xE9in"}}))
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = nil
      expect { mat = materialize }.to output(/cannot redact credentials/).to_stderr
      begin
        expect(File).not_to exist(File.join(mat.config_dir, '.credentials.json'))
        expect(File).to exist(File.join(mat.config_dir, 'projects', project_key, "#{sid}.jsonl"))
      ensure
        mat.cleanup
      end
    end

    it 'still strips plugin declarations from settings carrying a lone surrogate escape' do
      # Ruby's JSON parser rejects lone surrogate escapes that Python's accepts.
      # Bailing out to a byte-for-byte copy would leave enabledPlugins in place
      # and let the resumed CLI network-install every declared marketplace —
      # the exact behavior this seeding exists to prevent.
      File.binwrite(File.join(source, 'settings.json'),
                    '{"enabledPlugins":{"p@m":true},"weird":"\ud800","keep":1}')
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = materialize
      begin
        # The surrogate escape survives verbatim; only the plugin key is gone.
        expect(File.binread(File.join(mat.config_dir, 'settings.json')))
          .to eq('{"weird":"\ud800","keep":1}')
      ensure
        mat.cleanup
      end
    end

    it 'leaves an escaped-backslash "\\uXXXX" literal alone while stripping' do
      # "c:\\ud800x" is an escaped backslash followed by the literal text
      # ud800 — not an escape sequence, and it must not be masked.
      File.binwrite(File.join(source, 'settings.json'),
                    '{"enabledPlugins":{"a":1},"lit":"c:\\\\ud800x"}')
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = materialize
      begin
        expect(JSON.parse(File.read(File.join(mat.config_dir, 'settings.json'))))
          .to eq('lit' => 'c:\\ud800x')
      ensure
        mat.cleanup
      end
    end

    it 'does not abort the resume when the seed files are unreadable' do
      # Directories where files are expected: these are best-effort enrichment,
      # so they are logged and skipped rather than raising out of the resume.
      ['settings.json', '.credentials.json', '.claude.json'].each { |n| Dir.mkdir(File.join(source, n)) }
      ENV['CLAUDE_CONFIG_DIR'] = source

      mat = nil
      expect { mat = materialize }.to output(/skipping/).to_stderr
      begin
        ['settings.json', '.credentials.json', '.claude.json'].each do |name|
          expect(File).not_to exist(File.join(mat.config_dir, name))
        end
        # The transcript itself was still materialized.
        expect(File).to exist(File.join(mat.config_dir, 'projects', project_key, "#{sid}.jsonl"))
      ensure
        mat.cleanup
      end
    end
  end

  # not delete it. It keeps the transcripts but scrubs the credential copies.
  describe 'MaterializedResume#preserve_transcripts' do
    it 'removes credential copies, keeps transcripts, warns, and never rmtrees' do
      Dir.mktmpdir do |dir|
        transcript = File.join(dir, 'projects', 'pk', 'sid.jsonl')
        FileUtils.mkdir_p(File.dirname(transcript))
        File.write(transcript, "{}\n")
        # settings.json / cowork_settings.json are seeded from the caller's
        # config dir too, and their env blocks routinely carry API keys — the
        # scrub must cover them, not just the credential files.
        ['.credentials.json', '.claude.json', 'settings.json', 'cowork_settings.json'].each do |name|
          File.write(File.join(dir, name), '{}')
        end

        materialized = ClaudeAgentSDK::MaterializedResume.new(config_dir: dir, resume_session_id: 'sid')
        expect { materialized.preserve_transcripts }.to output(/[Pp]reserving/).to_stderr

        ['.credentials.json', '.claude.json', 'settings.json', 'cowork_settings.json'].each do |name|
          expect(File).not_to exist(File.join(dir, name))
        end
        expect(File).to exist(transcript)
      end
    end
  end
end
