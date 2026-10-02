# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# The disk reader looks at the first and the last 64 KiB of a transcript (and,
# for the first prompt, at most the first 1 MiB); the store fold sees every
# entry. Same transcript on both sides: written to disk, then imported.
RSpec.describe 'session info from disk and from a store, for one transcript' do
  include_context 'with a Claude config dir'

  let(:session_id) { '8f9a0b1c-2d3e-4f50-8a61-7b8c9d0e1f20' }
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }

  fields = %i[summary custom_title first_prompt git_branch cwd tag created_at]
  padding = 'x' * 1_000

  # +turns+ exchanges of about 2 KiB each, continuing from +parent+.
  filler = lambda do |transcript, parent, turns, name|
    turns.times do |turn|
      transcript.prompt(:"#{name}_q#{turn}", "filler #{turn} #{padding}", parent: parent)
      transcript.assistant(:"#{name}_a#{turn}", transcript.text("reply #{turn} #{padding}"),
                           parent: :"#{name}_q#{turn}", message: "msg_#{name}_#{turn}")
      parent = :"#{name}_a#{turn}"
    end
    parent
  end

  # [disk info, store info] for the transcript the block builds. The session
  # was killed before the CLI wrote its exit-time lines (last-prompt, ...),
  # unless the block adds them.
  def read_both
    transcript = CLITranscript.new(session_id: session_id, cwd: cwd)
    yield transcript
    transcript.write(transcript_path(session_id))
    ClaudeAgentSDK.import_session_to_store(session_id: session_id, session_store: store, directory: cwd)
    [ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd),
     ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd, session_store: store)]
  end

  describe 'fields both paths report alike' do
    {
      'a large SessionStart hook attachment before the first prompt' => [
        lambda do |t|
          t.queue_operations('what does a.rb define?')
          t.attachment(:hook, parent: nil, hook: 'SessionStart', stdout: 'A' * 92_000)
          t.prompt(:prompt, 'what does a.rb define?', parent: :hook)
          t.assistant(:answer, t.text('Foo.'), parent: :prompt)
        end,
        { first_prompt: 'what does a.rb define?', summary: 'what does a.rb define?' }
      ],
      'a slash command in the head and the real prompt beyond it' => [
        lambda do |t|
          t.queue_operations('/model')
          t.prompt(:command, '<command-name>/model</command-name><command-args></command-args>')
          t.attachment(:hook, parent: :command, hook: 'SessionStart', stdout: 'A' * 70_000)
          t.prompt(:prompt, 'the actual question', parent: :hook)
          t.assistant(:answer, t.text('The answer.'), parent: :prompt)
        end,
        { first_prompt: 'the actual question', summary: 'the actual question' }
      ],
      'a branch switched in the middle of a 300 KB session' => [
        lambda do |t|
          t.prompt(:prompt, 'start on main')
          t.assistant(:answer, t.text('Started.'), parent: :prompt)
          last = filler.call(t, :answer, 40, 'early')
          t.git_branch = 'feature/x'
          filler.call(t, last, 60, 'late')
        end,
        { git_branch: 'feature/x', first_prompt: 'start on main' }
      ]
    }.each do |name, (build, expected)|
      it "agrees for #{name}" do
        disk, stored = read_both(&build)

        expect(disk).not_to be_nil
        expect(fields.to_h { |f| [f, disk.public_send(f)] }).to eq(fields.to_h { |f| [f, stored.public_send(f)] })
        expect(fields.to_h { |f| [f, disk.public_send(f)] }).to include(expected)
      end
    end

    # An SDK prompt that inlines a document. The prompt is found by the scan
    # past the head; the entry's own timestamp follows its message on the
    # same line, beyond the head window.
    it 'agrees on the prompt of a 300 KB first line, and has no created_at for it on disk' do
      disk, stored = read_both do |t|
        t.prompt(:prompt, "#{'Q' * 300_000} end")
        t.assistant(:answer, t.text('Read.'), parent: :prompt)
      end

      expect(disk.first_prompt).to eq("#{'Q' * 200}…")
      expect([disk.first_prompt, disk.summary, disk.cwd]).to eq([stored.first_prompt, stored.summary, stored.cwd])
      expect(disk.created_at).to be_nil
      expect(stored.created_at).not_to be_nil
    end
  end

  # An interactive session starts with metadata lines; the snapshot's
  # timestamp is nested, the entry itself has none.
  it 'takes created_at from the first entry with a timestamp of its own, not from a file-history-snapshot' do
    disk, stored = read_both do |t|
      t.mode
      t.file_history_snapshot(timestamp: '2026-09-01T12:34:56.789Z')
      t.prompt(:prompt, 'after the snapshot')
      t.assistant(:answer, t.text('Done.'), parent: :prompt)
    end

    expect(disk.created_at).to eq(stored.created_at)
    expect(Time.at(disk.created_at / 1000).utc.strftime('%F %T')).to eq('2026-09-08 05:19:30')
  end

  # What only a full read would find. The entries below have more than 64 KiB
  # of transcript both before and after them, or sit past the first-prompt
  # scan; the CLI re-appends its own metadata when it resumes a session, an
  # entry the SDK appended while the session was running is not re-appended.
  describe 'fields the disk reader takes from its windows only' do
    {
      'a custom-title entry in the middle of the file' => [
        lambda do |t|
          t.prompt(:prompt, 'first prompt')
          t.assistant(:answer, t.text('Answered.'), parent: :prompt)
          last = filler.call(t, :answer, 40, 'early')
          t.custom_title('Renamed mid-session')
          filler.call(t, last, 60, 'late')
        end,
        :custom_title, nil, 'Renamed mid-session'
      ],
      'a tag entry in the middle of the file' => [
        lambda do |t|
          t.prompt(:prompt, 'first prompt')
          t.assistant(:answer, t.text('Answered.'), parent: :prompt)
          last = filler.call(t, :answer, 40, 'early')
          t.tag('experiment')
          filler.call(t, last, 60, 'late')
        end,
        :tag, nil, 'experiment'
      ],
      'a last-prompt entry at the head of the file only' => [
        lambda do |t|
          t.last_prompt('what I asked last')
          t.prompt(:prompt, 'first prompt')
          t.assistant(:answer, t.text('Answered.'), parent: :prompt)
          filler.call(t, :answer, 100, 'late')
        end,
        :summary, 'first prompt', 'what I asked last'
      ]
    }.each do |name, (build, field, on_disk, in_store)|
      it "differs in #{field} for #{name}" do
        disk, stored = read_both(&build)

        expect(disk.public_send(field)).to eq(on_disk)
        expect(stored.public_send(field)).to eq(in_store)
      end
    end

    it 'does not find a first prompt whose line ends past the first 1 MiB' do
      disk, stored = read_both do |t|
        t.queue_operations('the late question')
        t.attachment(:hook, parent: nil, hook: 'SessionStart', stdout: 'A' * 1_100_000)
        t.prompt(:prompt, 'the late question', parent: :hook)
        t.assistant(:answer, t.text('Answered.'), parent: :prompt)
      end

      expect(disk).to be_nil # no title, no last-prompt, no prompt in reach: not listed
      expect(stored.first_prompt).to eq('the late question')
    end
  end

  describe 'the first-prompt scan past the head' do
    it 'finds a prompt on the last line of a file that does not end with a newline' do
      transcript = CLITranscript.new(session_id: session_id, cwd: cwd)
      transcript.attachment(:hook, parent: nil, hook: 'SessionStart', stdout: 'A' * 92_000)
      transcript.prompt(:prompt, 'cut short', parent: :hook)
      File.binwrite(transcript.write(transcript_path(session_id)), transcript.to_jsonl.chomp)

      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd)&.first_prompt).to eq('cut short')
    end

    it 'keeps the slash command as the fallback when no real prompt follows' do
      disk, stored = read_both do |t|
        t.prompt(:command, '<command-name>/model</command-name><command-args></command-args>')
        t.attachment(:hook, parent: :command, hook: 'SessionStart', stdout: 'A' * 92_000)
        t.assistant(:answer, t.text('Model set.'), parent: :hook)
      end

      expect(disk.first_prompt).to eq('/model')
      expect(stored.first_prompt).to eq('/model')
    end

    it 'does not take a later tool result, meta entry or compact summary for the prompt' do
      disk, stored = read_both do |t|
        t.attachment(:hook, parent: nil, hook: 'SessionStart', stdout: 'A' * 92_000)
        t.meta(:reminder, '<system-reminder>context</system-reminder>', parent: :hook)
        t.assistant(:use_a, t.tool_use('toolu_a'), parent: :reminder)
        t.tool_result(:result_a, 'toolu_a', 'file contents', parent: :use_a)
        t.prompt(:compact, 'This session is being continued from a previous conversation',
                 parent: :result_a, isCompactSummary: true)
        t.prompt(:prompt, 'the real prompt', parent: :compact)
      end

      expect(disk.first_prompt).to eq('the real prompt')
      expect(stored.first_prompt).to eq('the real prompt')
    end
  end
end
