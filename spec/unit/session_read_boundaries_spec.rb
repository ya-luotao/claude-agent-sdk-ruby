# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# Boundary cases of the session readers and mutations, one group per case.
RSpec.describe 'session API boundaries' do
  include_context 'with a Claude config dir'

  let(:session_id) { 'c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f' }

  before { allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees) { |path| [path] } }

  def conversation(directory = cwd)
    transcript = CLITranscript.new(session_id: session_id, cwd: directory)
    transcript.queue_operations('what does a.rb define?')
    transcript.prompt(:prompt, 'what does a.rb define?')
    transcript.assistant(:answer, transcript.text('Foo.'), parent: :prompt)
    transcript.last_prompt('what does a.rb define?', leaf: :answer)
    transcript
  end

  # A config dir path is data, not a pattern: `/Volumes/Data [SSD]/claude`,
  # `/srv/{tenant}/claude`.
  describe 'a config dir whose path contains glob characters' do
    ['cfg [prod]', 'tenant{a,b}'].each do |name|
      it "lists the sessions under #{name.inspect}" do
        ENV['CLAUDE_CONFIG_DIR'] = File.join(config_dir, name)
        conversation.write(File.join(ENV.fetch('CLAUDE_CONFIG_DIR'), 'projects',
                                     ClaudeAgentSDK::Sessions.sanitize_path(cwd), "#{session_id}.jsonl"))

        expect(ClaudeAgentSDK.list_sessions(directory: cwd).map(&:session_id)).to eq([session_id])
        expect(ClaudeAgentSDK.list_sessions.map(&:session_id)).to eq([session_id])
      end
    end
  end

  # created_at (and the store fallback for last_modified) are epoch
  # milliseconds parsed from the ISO timestamps the CLI writes.
  describe 'the millisecond of an ISO timestamp' do
    let(:base) { Time.utc(2026, 9, 8, 5, 19, 30).to_i * 1000 }

    it 'is exact for every millisecond of a second' do
      parsed = (0..999).map do |ms|
        ClaudeAgentSDK::Sessions.parse_iso_timestamp_ms(format('2026-09-08T05:19:30.%03dZ', ms))
      end

      expect(parsed).to eq((0..999).map { |ms| base + ms })
    end

    it 'is exact with a UTC offset, and truncates what is finer than a millisecond' do
      expect(ClaudeAgentSDK::Sessions.parse_iso_timestamp_ms('2026-09-08T13:19:30.933+08:00'))
        .to eq(base + 933)
      expect(ClaudeAgentSDK::Sessions.parse_iso_timestamp_ms('2026-09-08T05:19:30.933999Z'))
        .to eq(base + 933)
    end

    it 'gives a session the created_at of its first entry, on disk and from a store' do
      transcript = CLITranscript.new(session_id: session_id, cwd: cwd, start: Time.utc(2026, 9, 8, 5, 19, 30.683r))
      transcript.prompt(:prompt, 'what does a.rb define?')
      transcript.assistant(:answer, transcript.text('Foo.'), parent: :prompt)
      transcript.write(transcript_path(session_id))
      store = ClaudeAgentSDK::InMemorySessionStore.new
      ClaudeAgentSDK.import_session_to_store(session_id: session_id, session_store: store, directory: cwd)
      exact = base + 933

      expect(transcript.entries.first['timestamp']).to eq('2026-09-08T05:19:30.933Z')
      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd).created_at).to eq(exact)
      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd, session_store: store).created_at)
        .to eq(exact)
    end
  end
end
