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
end
