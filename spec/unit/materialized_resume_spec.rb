# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'stringio'

RSpec.describe ClaudeAgentSDK::MaterializedResume do
  # When the mirror dropped batches the materialized config dir is kept, since
  # it holds the only copy of the dropped turns. It must then hold nothing but
  # those transcripts.
  describe '#preserve_transcripts' do
    let(:config_dir) { Dir.mktmpdir('claude-resume-') }
    let(:outside) { Dir.mktmpdir }
    let(:sid) { '11111111-1111-4111-8111-111111111111' }

    # What the SDK seeds from the caller's .claude.json: it can carry MCP
    # header secrets.
    let(:claude_json) do
      JSON.generate('oauthAccount' => { 'emailAddress' => 'user@example.invalid' },
                    'mcpServers' => { 'internal' => { 'type' => 'http', 'url' => 'https://mcp.example.invalid',
                                                      'headers' => { 'Authorization' => 'Bearer MCP-HEADER-SECRET' } } })
    end

    # The four files the SDK seeds, then what a real CLI (2.1.286) left beside
    # them after a store-backed resume — at startup it saves the seeded
    # .claude.json as backups/.claude.json.backup.<epoch ms> before rewriting
    # it — and a file name nobody has heard of yet.
    let(:secrets) do
      {
        '.credentials.json' => '{"claudeAiOauth":{"accessToken":"ACCESS-TOKEN"}}',
        '.claude.json' => claude_json,
        'settings.json' => '{"env":{"INTERNAL_API_KEY":"SETTINGS-SECRET"}}',
        'cowork_settings.json' => '{"env":{"INTERNAL_API_KEY":"SETTINGS-SECRET"}}',
        'backups/.claude.json.backup.1790881328533' => claude_json,
        'cache/model-catalog/x-cc.json' => '{}',
        'written-by-a-later-cli.json' => claude_json
      }
    end
    let(:transcripts) do
      {
        "projects/-proj/#{sid}.jsonl" => %({"type":"user","uuid":"u1","sessionId":"#{sid}"}\n),
        "projects/-proj/#{sid}/subagents/agent-a1.jsonl" => %({"type":"user","uuid":"s1","isSidechain":true}\n),
        "projects/-proj/#{sid}/subagents/agent-a1.meta.json" => '{"agentType":"worker"}'
      }
    end

    before do
      secrets.merge(transcripts).each do |relative, content|
        path = File.join(config_dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      Dir.mkdir(File.join(config_dir, 'sessions')) # the CLI leaves this one empty
      File.write(File.join(outside, 'not-ours.txt'), 'keep me')
      File.symlink(outside, File.join(config_dir, 'linked-elsewhere'))
    end

    after do
      [config_dir, outside].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
    end

    def preserve
      described_class.new(config_dir: config_dir, resume_session_id: sid).preserve_transcripts
    end

    def stderr_of
      original = $stderr
      $stderr = StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = original
    end

    def files_under(dir)
      Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).select { |relative| File.file?(File.join(dir, relative)) }
    end

    it 'keeps projects/ and deletes every other entry, known or not' do
      expect { preserve }.to output(/transcript mirror dropped batches.*#{Regexp.escape(File.join(config_dir, 'projects'))}/).to_stderr

      expect(Dir.children(config_dir)).to eq(['projects'])
      expect(files_under(config_dir).to_h { |relative| [relative, File.read(File.join(config_dir, relative))] })
        .to eq(transcripts)
    end

    it 'removes a symlink without following it' do
      expect { preserve }.to output.to_stderr

      expect(File.symlink?(File.join(config_dir, 'linked-elsewhere'))).to be(false)
      expect(File.read(File.join(outside, 'not-ours.txt'))).to eq('keep me')
    end

    it 'still reports the incomplete store copy, without raising, when the directory is already gone' do
      FileUtils.remove_entry(config_dir)

      expect { preserve }.to output(/transcript mirror dropped batches/).to_stderr
    end

    # An entry that cannot be removed must not pass for scrubbed: backups/ can
    # hold the seeded .claude.json, MCP header secrets included.
    context 'when an entry resists deletion' do
      let(:backups) { File.join(config_dir, 'backups') }

      it 'makes a read-only directory of its own writable and removes it' do
        File.chmod(0o500, backups) # listable, not writable: its file cannot be unlinked

        warning = stderr_of { preserve }

        expect(Dir.children(config_dir)).to eq(['projects'])
        expect(warning).to match(/Preserving the session transcript/)
        expect(warning).not_to match(/Scrubbing failed/)
      ensure
        File.chmod(0o700, backups) if File.directory?(backups)
      end

      it 'neither follows nor changes a symlink while it makes a directory writable' do
        File.symlink(outside, File.join(backups, 'elsewhere'))
        File.chmod(0o555, outside)
        File.chmod(0o500, backups)

        stderr_of { preserve }

        expect(Dir.children(config_dir)).to eq(['projects'])
        expect(format('%o', File.stat(outside).mode & 0o777)).to eq('555')
        expect(File.read(File.join(outside, 'not-ours.txt'))).to eq('keep me')
      ensure
        File.chmod(0o700, backups) if File.directory?(backups)
        File.chmod(0o700, outside)
      end

      it 'says scrubbing failed, and names what is left, when it still cannot remove it' do
        allow(FileUtils).to receive(:remove_entry).and_call_original
        allow(FileUtils).to receive(:remove_entry).with(backups).and_raise(Errno::EACCES, backups)

        warning = stderr_of { preserve }

        expect(Dir.children(config_dir).sort).to eq(%w[backups projects])
        expect(warning).to match(/Preserving the session transcript.* Scrubbing failed: could not remove backups \(Permission denied/)
      end
    end

    # Anything that knows CLAUDE_CONFIG_DIR can replace the temp dir before
    # teardown. "Delete every entry but projects/" must then delete nothing,
    # rather than the entries of whatever the path leads to now.
    #
    # The original directory is always renamed aside, never deleted, before
    # its replacement appears: a freshly created directory may otherwise reuse
    # its inode number and look like the same directory.
    context 'when the directory is no longer the one the SDK created' do
      let(:unrelated) { Dir.mktmpdir }
      let(:aside) { "#{config_dir}-aside" }
      let(:refusal) { /no longer the directory the SDK created.*deleted nothing in it/ }

      before do
        { 'projects/-elsewhere/x.jsonl' => "{}\n", 'innocent/keep.txt' => 'synthetic', '.claude.json' => '{}' }
          .each do |relative, content|
            path = File.join(unrelated, relative)
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, content)
          end
      end

      after do
        [unrelated, aside].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
      end

      it 'deletes nothing through a root that has become a symlink' do
        materialized = described_class.new(config_dir: config_dir, resume_session_id: sid)
        File.rename(config_dir, aside)
        File.symlink(unrelated, config_dir)
        before_scrub = files_under(unrelated).sort

        warning = stderr_of { materialized.preserve_transcripts }

        expect(files_under(unrelated).sort).to eq(before_scrub)
        expect(File.symlink?(config_dir)).to be(true)
        expect(warning).to match(refusal)
      end

      it 'deletes nothing in a different directory at the same path' do
        materialized = described_class.new(config_dir: config_dir, resume_session_id: sid)
        File.rename(config_dir, aside)
        FileUtils.cp_r(unrelated, config_dir)
        before_scrub = files_under(config_dir).sort

        warning = stderr_of { materialized.preserve_transcripts }

        expect(files_under(config_dir).sort).to eq(before_scrub)
        expect(warning).to match(refusal)
      end

      it 'refuses a symlink it is handed as the directory' do
        link = File.join(outside, 'replaced-config')
        File.symlink(unrelated, link)
        before_scrub = files_under(unrelated).sort

        warning = stderr_of { described_class.new(config_dir: link, resume_session_id: sid).preserve_transcripts }

        expect(files_under(unrelated).sort).to eq(before_scrub)
        expect(warning).to match(refusal)
      end

      # What counts is the directory materialize_resume_session created, not
      # whatever is at the path by the time the MaterializedResume is built.
      it 'compares with the directory as created, even if it was replaced during materialization' do
        created = []
        allow(Dir).to receive(:mktmpdir).and_wrap_original do |original, *args, &block|
          original.call(*args, &block).tap { |dir| created << dir if File.basename(dir).start_with?('claude-resume-') }
        end
        replace_temp_dir = lambda do
          File.rename(created.last, "#{created.last}-aside")
          FileUtils.cp_r(unrelated, created.last)
        end
        store = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
          define_method(:list_subkeys) do |_key|
            replace_temp_dir.call # runs after the transcript and the seed files are written
            []
          end
        end.new
        project_dir = File.join(outside, 'project')
        FileUtils.mkdir_p(project_dir)
        store.append({ 'project_key' => ClaudeAgentSDK.project_key_for_directory(project_dir), 'session_id' => sid },
                     [{ 'type' => 'user', 'uuid' => 'u1', 'sessionId' => sid, 'message' => { 'role' => 'user', 'content' => 'hi' } }])
        caller_config_dir = File.join(outside, 'caller-config') # empty: nothing seeded from the developer's own
        FileUtils.mkdir_p(caller_config_dir)

        materialized = ClaudeAgentSDK::SessionResume.materialize_resume_session(
          ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: project_dir,
                                                 env: { 'CLAUDE_CONFIG_DIR' => caller_config_dir })
        )
        before_scrub = files_under(materialized.config_dir).sort

        warning = stderr_of { materialized.preserve_transcripts }

        expect(files_under(materialized.config_dir).sort).to eq(before_scrub)
        expect(warning).to match(refusal)
      ensure
        created&.each { |dir| [dir, "#{dir}-aside"].each { |path| FileUtils.rm_rf(path) } }
      end
    end
  end
end
