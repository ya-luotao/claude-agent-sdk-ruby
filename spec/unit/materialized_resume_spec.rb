# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'stringio'

RSpec.describe ClaudeAgentSDK::MaterializedResume do
  # When the mirror dropped batches the materialized config dir is kept, since
  # it holds the only copy of the dropped turns. It must then hold nothing but
  # those transcripts, and getting there must not delete or change anything
  # outside it, whatever is done to the directory in the meantime: the CLI's
  # tools can write into it, sandboxed ones included.
  describe '#preserve_transcripts' do
    # One scratch directory per example holds the temp config dir, the private
    # directory the SDK moves it into (created next to it) and the directories
    # nothing may touch. Nothing lands in the real $TMPDIR.
    let(:scratch) { Dir.mktmpdir('preserve-spec-') }
    let(:config_dir) { File.join(scratch, 'claude-resume-under-test') }
    let(:outside) { File.join(scratch, 'outside') }
    let(:sid) { '11111111-1111-4111-8111-111111111111' }
    let(:materialized) { described_class.new(config_dir: config_dir, resume_session_id: sid) }

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
      Dir.mkdir(config_dir, 0o700)
      write_tree(config_dir, secrets.merge(transcripts))
      Dir.mkdir(File.join(config_dir, 'sessions')) # the CLI leaves this one empty
      write_tree(outside, 'not-ours.txt' => 'keep me')
      File.symlink(outside, File.join(config_dir, 'linked-elsewhere'))
      materialized # built now, like the SDK does: it records which directory this is
    end

    # Stubs are still in place while this runs. A wrapper that waits for a
    # call its example never got to must not make its swap now, in the middle
    # of the teardown: the scratch directory would stay behind in $TMPDIR.
    after do
      { File => %i[lstat open rename unlink], Dir => %i[children rmdir] }.each do |receiver, wrapped|
        wrapped.each { |name| allow(receiver).to receive(name).and_call_original }
      end
      unlock(scratch)
      FileUtils.remove_entry(scratch)
    end

    def write_tree(root, files)
      files.each do |relative, content|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
    end

    # Give every real directory under +path+ its owner bits back (never
    # through a symlink), so the scratch tree can be removed whatever an
    # example left read-only.
    def unlock(path)
      return unless File.lstat(path).directory?

      File.chmod(0o700, path)
      Dir.children(path).each { |name| unlock(File.join(path, name)) }
    end

    def stderr_of
      original = $stderr
      $stderr = StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = original
    end

    # relative path => content, for every regular file under +dir+.
    def tree(dir)
      files = Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).select { |relative| File.file?(File.join(dir, relative)) }
      files.sort.to_h { |relative| [relative, File.read(File.join(dir, relative))] }
    end

    def mode_of(path)
      format('%o', File.stat(path).mode & 0o777)
    end

    # Runs preserve_transcripts and returns its warning.
    def preserve
      stderr_of { materialized.preserve_transcripts }
    end

    # Runs preserve_transcripts while +method+ of +receiver+ raises something
    # that is not a StandardError — what a cancellation (Async::Stop) or a
    # signal looks like — and returns the warning. The wrapper is disarmed
    # afterwards: the examples and the teardown use the same methods.
    def preserve_interrupted_at(receiver, method)
      cancellation = Class.new(Exception) # rubocop:disable Lint/InheritException -- see above
      interrupting = true
      allow(receiver).to receive(method).and_wrap_original do |original, *args|
        raise cancellation if interrupting

        original.call(*args)
      end
      stderr_of { expect { materialized.preserve_transcripts }.to raise_error(cancellation) }
    ensure
      interrupting = false
    end

    # Where the directory lives once it was moved, and the private directory
    # it was moved into.
    def preserved
      materialized.config_dir
    end

    def staging
      File.dirname(preserved)
    end

    let(:skipped) { /transcript mirror dropped batches.*Scrubbing was skipped and nothing was deleted/ }

    it 'moves the directory into a private one next to it, keeps projects/ and deletes every other entry' do
      warning = preserve

      expect(File.symlink?(config_dir) || File.exist?(config_dir)).to be(false)
      expect(File.basename(staging)).to start_with('claude-preserved-resume-')
      expect(Dir.children(scratch)).to contain_exactly(File.basename(staging), 'outside')
      expect(mode_of(staging)).to eq('700')
      expect(Dir.children(staging)).to eq(['claude-resume-under-test'])
      expect(Dir.children(preserved)).to eq(['projects'])
      expect(tree(preserved)).to eq(transcripts)
      expect(warning).to match(/transcript mirror dropped batches.*Preserving the session transcript under /)
      expect(warning).to match(/under #{Regexp.escape(File.join(preserved, 'projects'))} .*then remove #{Regexp.escape(staging)}\./)
      expect(warning).not_to match(/Scrubbing/)
    end

    it 'removes a symlink without following it' do
      preserve

      expect(Dir.children(preserved)).to eq(['projects'])
      expect(tree(outside)).to eq('not-ours.txt' => 'keep me')
    end

    it 'still reports the incomplete store copy, without raising, when the directory is already gone' do
      FileUtils.remove_entry(config_dir)

      expect(preserve).to match(skipped)
      expect(Dir.children(scratch)).to eq(['outside']) # and leaves no empty private directory behind
    end

    it 'deletes nothing, and leaves no empty directory behind, when the directory cannot be moved' do
      allow(File).to receive(:rename).and_raise(Errno::EACCES, config_dir)

      warning = preserve

      expect(tree(config_dir)).to eq(secrets.merge(transcripts))
      expect(Dir.children(scratch)).to contain_exactly('claude-resume-under-test', 'outside')
      expect(warning).to match(skipped)
      expect(warning).to include("#{config_dir} could not be moved aside (Permission denied")
    end

    # Cut short by something that is not a StandardError (a cancellation, a
    # signal), it still has to say what to do: #cleanup leaves the directory
    # alone from then on. Where the transcript is, that copies which were not
    # removed yet may be left, and which directory to remove once the
    # transcript is imported — the private one if the directory was moved
    # there, the temp dir itself if it was not. (Its parent would be $TMPDIR.)
    context 'when it is interrupted' do
      # The whole interrupted notice, for a transcript under +transcript_dir+
      # and +to_remove+ as the directory the user is told to remove.
      def interrupted(transcript_dir, to_remove)
        to_remove = Regexp.escape(to_remove)
        Regexp.new(
          'transcript mirror dropped batches.* Scrubbing was interrupted; the session transcript is under ' \
          "#{Regexp.escape(File.join(transcript_dir, 'projects'))}\\. " \
          "Copies of your credentials and settings .* may be left under #{to_remove} — " \
          "import the transcript into your session store, then remove #{to_remove}\\.$"
        )
      end

      it 'names the private directory to remove once the directory was moved there' do
        warning = preserve_interrupted_at(File, :unlink)

        expect(tree(preserved).slice(*transcripts.keys)).to eq(transcripts)
        expect(File.basename(staging)).to start_with('claude-preserved-resume-')
        expect(warning).to match(interrupted(preserved, staging))
        expect(warning).not_to match(/remove #{Regexp.escape(preserved)}\./)
      end

      it 'names the temp dir itself when the directory had not been moved yet' do
        warning = preserve_interrupted_at(File, :lstat)

        expect(preserved).to eq(config_dir)
        expect(Dir.children(scratch)).to contain_exactly('claude-resume-under-test', 'outside')
        expect(warning).to match(interrupted(config_dir, config_dir))
        expect(warning).not_to match(/remove #{Regexp.escape(scratch)}\./)
      end
    end

    # A teardown can run twice. Client#disconnect lets go of its
    # MaterializedResume only once preserve_transcripts returned; cut short, a
    # later disconnect finds the query handler gone — nothing remembers that
    # the mirror dropped batches — and calls #cleanup on the same object. What
    # was kept is the only copy of the dropped turns.
    context 'when #cleanup is called afterwards' do
      it 'leaves the preserved directory alone' do
        preserve

        materialized.cleanup

        expect(tree(preserved)).to eq(transcripts)
      end

      it 'leaves the transcript in place when the scrub had been interrupted' do
        preserve_interrupted_at(File, :unlink)

        materialized.cleanup

        expect(tree(preserved).slice(*transcripts.keys)).to eq(transcripts)
      end

      it 'deletes nothing when it had been interrupted before the directory was moved' do
        preserve_interrupted_at(File, :lstat)

        materialized.cleanup

        expect(preserved).to eq(config_dir)
        expect(tree(config_dir)).to eq(secrets.merge(transcripts))
      end
    end

    # An entry that cannot be removed must not pass for scrubbed: backups/ can
    # hold the seeded .claude.json, MCP header secrets included.
    context 'when an entry resists deletion' do
      let(:backups) { File.join(config_dir, 'backups') }

      it 'makes a read-only directory of its own writable and removes it' do
        File.chmod(0o500, backups) # listable, not writable: it cannot be moved, its file cannot be unlinked

        warning = preserve

        expect(Dir.children(preserved)).to eq(['projects'])
        expect(Dir.children(staging)).to eq(['claude-resume-under-test'])
        expect(warning).to match(/Preserving the session transcript/)
        expect(warning).not_to match(/Scrubbing failed/)
      end

      it 'makes a directory accessible that it could take out but not empty' do
        File.chmod(0o600, backups) # writable, so it can be moved; not searchable, so nothing in it can be

        warning = preserve

        expect(Dir.children(preserved)).to eq(['projects'])
        expect(Dir.children(staging)).to eq(['claude-resume-under-test'])
        expect(warning).not_to match(/Scrubbing failed/)
      end

      it 'neither follows nor changes a symlink while it makes a directory writable' do
        File.symlink(outside, File.join(backups, 'elsewhere'))
        File.chmod(0o555, outside)
        File.chmod(0o500, backups)

        preserve

        expect(Dir.children(preserved)).to eq(['projects'])
        expect(mode_of(outside)).to eq('555')
        expect(tree(outside)).to eq('not-ours.txt' => 'keep me')
      end

      it 'does not chmod a directory that another user owns' do
        File.chmod(0o500, backups)
        allow_any_instance_of(File::Stat).to receive(:owned?).and_return(false)

        warning = preserve

        expect(mode_of(File.join(preserved, 'backups'))).to eq('500')
        expect(warning).to match(/Scrubbing failed: could not remove backups \(Operation not permitted/)
      end

      it 'says scrubbing failed, and names what is left, when it cannot take an entry out' do
        allow(File).to receive(:rename).and_wrap_original do |original, from, to|
          raise Errno::EACCES, from if File.basename(from) == 'backups'

          original.call(from, to)
        end

        warning = preserve

        expect(Dir.children(preserved)).to contain_exactly('backups', 'projects')
        expect(tree(preserved).slice(*transcripts.keys)).to eq(transcripts)
        expect(warning).to match(/Preserving the session transcript.* Scrubbing failed: could not remove backups \(Permission denied/)
        expect(warning).to match(/What is left is under #{Regexp.escape(staging)}/)
      end

      it 'names an entry it had already taken out but could not finish removing' do
        taken = nil
        allow(File).to receive(:rename).and_wrap_original do |original, from, to|
          taken = to if File.basename(from) == 'backups'
          original.call(from, to)
        end
        refusing = true
        allow(Dir).to receive(:rmdir).and_wrap_original do |original, path|
          raise Errno::EACCES, path if refusing && path == taken

          original.call(path)
        end

        warning = preserve
        refusing = false

        expect(Dir.children(preserved)).to eq(['projects']) # it is no longer next to the transcript ...
        expect(File).to exist(taken) # ... but it is not gone either
        expect(warning).to match(/Scrubbing failed: could not remove backups \(Permission denied.*What is left is under #{Regexp.escape(staging)}/)
      end
    end

    # Something that still holds a directory open can write into it after it
    # was moved into the trash.
    it 'takes out what arrives in a directory while it is being emptied' do
      arrived = false
      allow(Dir).to receive(:children).and_wrap_original do |original, path|
        names = original.call(path)
        if !arrived && File.basename(File.dirname(path)).start_with?('scrub-')
          arrived = true
          File.write(File.join(path, 'late.json'), claude_json)
        end
        names
      end

      warning = preserve

      expect(arrived).to be(true)
      expect(Dir.children(preserved)).to eq(['projects'])
      expect(Dir.children(staging)).to eq(['claude-resume-under-test'])
      expect(warning).not_to match(/Scrubbing/)
    end

    # Teardown runs on the reactor, and a fiber's stack is small. A scrub that
    # recursed once per directory level ran out of it a few hundred levels
    # down — one `mkdir -p` makes such a tree — and SystemStackError is not a
    # StandardError: it left preserve_transcripts.
    context 'when a tree is very deep' do
      # A path can only be so long, so the chain is built in pieces of at most
      # 150 levels: each new piece takes the chain so far under its deepest
      # directory. Returns the top of the chain.
      def deep_chain(levels)
        chain = nil
        levels.fdiv(150).ceil.times do |index|
          top = File.join(scratch, "piece-#{index}")
          deepest = File.join(top, Array.new([150, levels - (index * 150)].min - 1, 'd'))
          FileUtils.mkdir_p(deepest)
          chain ? File.rename(chain, File.join(deepest, 'd')) : File.write(File.join(deepest, 'secret.json'), claude_json)
          chain = top
        end
        chain
      end

      # The teardown above cannot take such a tree down: unlock and FileUtils
      # recurse, and the paths get too long. So whatever a failing example left
      # is removed here first, without either: every entry is renamed to the
      # top of the scratch directory before it is looked at.
      after do
        flattened = 0
        pending = Dir.children(scratch).map { |name| File.join(scratch, name) }
        until pending.empty?
          path = pending.pop
          next File.unlink(path) unless File.lstat(path).directory?

          Dir.children(path).each do |child|
            pending << File.join(scratch, "flat-#{flattened += 1}")
            File.rename(File.join(path, child), pending.last)
          end
          Dir.rmdir(path)
        end
      end

      it 'scrubs a chain of 1000 directories on the reactor' do
        File.rename(deep_chain(1000), File.join(config_dir, 'deep'))

        warning = Sync { preserve }

        expect(Dir.children(preserved)).to eq(['projects'])
        expect(Dir.children(staging)).to eq(['claude-resume-under-test']) # and nothing is left in the trash
        expect(tree(preserved)).to eq(transcripts)
        expect(warning).not_to match(/Scrubbing/)
      end
    end

    # A read-only root cannot be moved. Skipping the scrub would leave the
    # credential copies behind, so the root is repaired first — through a
    # handle that has to be the directory the SDK created.
    context 'when the directory itself is read-only' do
      it 'makes it writable, moves it and scrubs it' do
        File.chmod(0o500, config_dir)

        warning = preserve

        expect(Dir.children(preserved)).to eq(['projects'])
        expect(tree(preserved)).to eq(transcripts)
        expect(warning).to match(/Preserving the session transcript/)
        expect(warning).not_to match(/Scrubbing/)
      end

      it 'skips the scrub, deleting nothing, when it cannot be made writable' do
        skip 'a superuser can open any directory' if Process.euid.zero?

        File.chmod(0o300, config_dir) # its owner cannot even open it

        warning = preserve

        File.chmod(0o700, config_dir)
        expect(tree(config_dir)).to eq(secrets.merge(transcripts))
        expect(Dir.children(scratch)).to contain_exactly('claude-resume-under-test', 'outside')
        expect(warning).to match(skipped)
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
      let(:unrelated) { File.join(scratch, 'unrelated') }
      let(:aside) { File.join(scratch, 'the-sdk-directory-moved-aside') }

      before do
        write_tree(unrelated, 'projects/-elsewhere/x.jsonl' => "{}\n", 'innocent/keep.txt' => 'synthetic',
                              '.claude.json' => '{}')
      end

      it 'deletes nothing when the path has become a symlink: it moves the link, not its target' do
        File.rename(config_dir, aside)
        File.symlink(unrelated, config_dir)
        File.chmod(0o555, unrelated)
        before_scrub = tree(unrelated)

        warning = preserve

        expect(tree(unrelated)).to eq(before_scrub)
        expect(mode_of(unrelated)).to eq('555')
        expect(tree(aside)).to eq(secrets.merge(transcripts))
        expect(File.symlink?(preserved)).to be(true)
        expect(File.readlink(preserved)).to eq(unrelated)
        expect(warning).to match(skipped)
        expect(warning).to include(preserved)
      end

      it 'deletes nothing in a different directory at the same path' do
        File.rename(config_dir, aside)
        FileUtils.cp_r(unrelated, config_dir)
        before_scrub = tree(config_dir)

        warning = preserve

        expect(tree(preserved)).to eq(before_scrub)
        expect(warning).to match(skipped)
      end

      it 'does not make a read-only directory writable when it is not the one the SDK created' do
        File.rename(config_dir, aside)
        FileUtils.cp_r(unrelated, config_dir)
        File.chmod(0o500, config_dir)

        warning = preserve

        expect(mode_of(config_dir)).to eq('500') # still where it was, as it was
        expect(Dir.children(scratch)).to contain_exactly('claude-resume-under-test', 'outside', 'unrelated',
                                                         File.basename(aside))
        expect(warning).to match(skipped)
      end

      it 'deletes nothing when it is handed a symlink as the directory' do
        link = File.join(scratch, 'replaced-config')
        File.symlink(unrelated, link)
        handed_a_link = described_class.new(config_dir: link, resume_session_id: sid)
        before_scrub = tree(unrelated)

        warning = stderr_of { handed_a_link.preserve_transcripts }

        expect(tree(unrelated)).to eq(before_scrub)
        expect(warning).to match(skipped)
      end

      # What counts is the directory materialize_resume_session created, not
      # whatever is at the path by the time the MaterializedResume is built.
      it 'compares with the directory as created, even if it was replaced during materialization' do
        created = []
        allow(Dir).to receive(:mktmpdir).and_wrap_original do |original, *args, **options, &block|
          next original.call(*args, **options, &block) unless args == ['claude-resume-']

          original.call('claude-resume-', scratch).tap { |dir| created << dir }
        end
        replace_temp_dir = lambda do
          File.rename(created.last, aside)
          FileUtils.cp_r(unrelated, created.last)
        end
        store = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
          define_method(:list_subkeys) do |_key|
            replace_temp_dir.call # runs after the transcript and the seed files are written
            []
          end
        end.new
        project_dir = File.join(scratch, 'project')
        caller_config_dir = File.join(scratch, 'caller-config') # empty: nothing seeded from the developer's own
        [project_dir, caller_config_dir].each { |dir| FileUtils.mkdir_p(dir) }
        store.append({ 'project_key' => ClaudeAgentSDK.project_key_for_directory(project_dir), 'session_id' => sid },
                     [{ 'type' => 'user', 'uuid' => 'u1', 'sessionId' => sid, 'message' => { 'role' => 'user', 'content' => 'hi' } }])

        from_the_store = ClaudeAgentSDK::SessionResume.materialize_resume_session(
          ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: project_dir,
                                                 env: { 'CLAUDE_CONFIG_DIR' => caller_config_dir })
        )
        before_scrub = tree(from_the_store.config_dir)

        warning = stderr_of { from_the_store.preserve_transcripts }

        expect(tree(from_the_store.config_dir)).to eq(before_scrub)
        expect(warning).to match(skipped)
      end
    end

    # The same, with the swap timed against the cleanup itself. Each example
    # puts it between two steps of preserve_transcripts by wrapping the call
    # that comes next; nothing depends on a clock or on another thread.
    context 'when something is swapped while the cleanup runs' do
      let(:unrelated) { File.join(scratch, 'unrelated') }
      let(:aside) { File.join(scratch, 'the-sdk-directory-moved-aside') }
      let(:backups) { File.join(config_dir, 'backups') }

      before do
        # An entry for every name the scrub lists, whatever order it walks
        # them in, and for what is inside backups/: each one deleted through
        # a swapped path would be a file the SDK never wrote.
        names = Dir.children(config_dir) - %w[projects linked-elsewhere]
        write_tree(unrelated, names.to_h { |name| [name == 'backups' ? 'backups/kept.txt' : name, 'synthetic'] }
                                   .merge('.claude.json.backup.1790881328533' => 'synthetic'))
      end

      # Dir.children answers in the filesystem's order. Putting backups/ first
      # lets an example see that the scrub stopped at it, in what it never got to.
      def scrub_backups_first
        allow(Dir).to receive(:children).and_wrap_original do |original, path|
          names = original.call(path)
          next names unless File.basename(path) == 'claude-resume-under-test'

          names.partition { |name| name == 'backups' }.flatten
        end
      end

      it 'deletes nothing when the directory becomes a symlink right before it is moved' do
        swapped = false
        allow(File).to receive(:rename).and_wrap_original do |original, from, to|
          if from == config_dir && !swapped
            swapped = true
            original.call(config_dir, aside)
            File.symlink(unrelated, config_dir)
          end
          original.call(from, to)
        end
        before_scrub = tree(unrelated)

        warning = preserve

        expect(swapped).to be(true)
        expect(tree(unrelated)).to eq(before_scrub)
        expect(tree(aside)).to eq(secrets.merge(transcripts))
        expect(warning).to match(skipped)
      end

      it 'never follows a symlink planted at the old path once the directory was moved' do
        planted = false
        allow(File).to receive(:rename).and_wrap_original do |original, from, to|
          if File.basename(File.dirname(to)).start_with?('scrub-') && !planted # right before the first removal
            planted = true
            File.symlink(unrelated, config_dir)
          end
          original.call(from, to)
        end
        before_scrub = tree(unrelated)

        warning = preserve

        expect(planted).to be(true)
        expect(tree(unrelated)).to eq(before_scrub)
        expect(Dir.children(preserved)).to eq(['projects'])
        expect(tree(preserved)).to eq(transcripts)
        expect(warning).to match(/Preserving the session transcript under #{Regexp.escape(File.join(preserved, 'projects'))}/)
        expect(warning).not_to match(/Scrubbing/)
      end

      it 'unlinks, and does not follow, an entry that becomes a symlink right before it is removed' do
        swapped = false
        allow(File).to receive(:rename).and_wrap_original do |original, from, to|
          if File.basename(from) == 'backups' && !swapped
            swapped = true
            original.call(from, "#{from}-aside")
            File.symlink(unrelated, from)
          end
          original.call(from, to)
        end
        before_scrub = tree(unrelated)

        warning = preserve

        expect(swapped).to be(true)
        expect(tree(unrelated)).to eq(before_scrub)
        expect(tree(preserved).slice(*transcripts.keys)).to eq(transcripts)
        # The real backups/ is still there under its new name, and the warning says so.
        expect(Dir.children(preserved)).to contain_exactly('backups-aside', 'projects')
        expect(warning).to match(/Scrubbing failed: could not remove backups-aside/)
      end

      # A read-only backups/ has to be made writable. Between the look at it
      # and the chmod it is swapped for a symlink to a directory elsewhere:
      # that directory must keep its mode and its files.
      it 'leaves an outside directory alone when backups/ is swapped between the lstat and the chmod' do
        File.chmod(0o500, backups)
        File.chmod(0o555, outside)
        scrub_backups_first
        swapped = false
        allow(File).to receive(:lstat).and_wrap_original do |original, path|
          stat = original.call(path)
          if !swapped && File.basename(path) == 'backups' && stat.directory? && stat.mode.nobits?(0o200)
            swapped = true
            File.rename(path, "#{path}-aside")
            File.symlink(outside, path)
          end
          stat
        end

        warning = preserve

        expect(swapped).to be(true)
        expect(mode_of(outside)).to eq('555')
        expect(tree(outside)).to eq('not-ours.txt' => 'keep me')
        expect(tree(preserved).slice(*transcripts.keys)).to eq(transcripts)
        expect(warning).to match(/Preserving the session transcript.* Scrubbing failed: could not remove .*backups/)
        expect(warning).to match(/backups became a symlink/)
        # It stopped there: backups/ came first, nothing after it was touched.
        expect(Dir.children(preserved)).to include(*(secrets.keys.map { |key| key.split('/').first }.uniq - ['backups']))
      end

      it 'stops, leaving an outside directory alone, when backups/ is swapped right after the chmod' do
        File.chmod(0o500, backups)
        File.chmod(0o555, outside)
        scrub_backups_first
        swapped = false
        allow(File).to receive(:open).and_wrap_original do |original, *args, **options, &block|
          result = original.call(*args, **options, &block)
          if !swapped && File.basename(args.first.to_s) == 'backups'
            swapped = true
            File.rename(args.first, "#{args.first}-aside")
            File.symlink(outside, args.first)
          end
          result
        end

        warning = preserve

        expect(swapped).to be(true)
        expect(mode_of(outside)).to eq('555')
        expect(tree(outside)).to eq('not-ours.txt' => 'keep me')
        expect(tree(preserved).slice(*transcripts.keys)).to eq(transcripts)
        expect(warning).to match(/Scrubbing failed: could not remove .*backups/)
        expect(warning).to match(/backups was replaced while it was being made writable/)
        expect(Dir.children(preserved)).to include(*(secrets.keys.map { |key| key.split('/').first }.uniq - ['backups']))
      end
    end
  end
end
