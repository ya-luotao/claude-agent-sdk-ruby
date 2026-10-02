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

  # list_subkeys is documented to return Strings. Resume already skips
  # anything else an adapter hands back; the readers called String methods
  # on it.
  describe 'a store whose list_subkeys returns values that are not Strings' do
    let(:agent_id) { 'a1b2c3d4e5f60718' }
    let(:store) do
      Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def list_subkeys(key) = [:'subagents/agent-symbol', nil, 7] + super
      end.new
    end

    before do
      key = { 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id }
      store.append(key, conversation.store_entries)
      subagent = CLITranscript.new(session_id: session_id, cwd: cwd, agent_id: agent_id)
      subagent.prompt(:task, 'Read a.rb')
      subagent.assistant(:report, subagent.text('It defines Foo.'), parent: :task)
      store.append(key.merge('subpath' => "subagents/agent-#{agent_id}"), subagent.store_entries)
    end

    it 'lists the subagents it can name' do
      expect(ClaudeAgentSDK.list_subagents(session_id: session_id, directory: cwd, session_store: store))
        .to eq([agent_id])
    end

    it 'reads a subagent it can name' do
      messages = ClaudeAgentSDK.get_subagent_messages(session_id: session_id, agent_id: agent_id, directory: cwd,
                                                      session_store: store)

      expect(messages.map(&:text)).to eq(['Read a.rb', 'It defines Foo.'])
    end
  end

  # last_modified on the store paths is the adapter's mtime for the session:
  # the value the store listing reports and orders by.
  describe 'last_modified of a session read from a store' do
    let(:key) { { 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id } }

    def info_from(store)
      ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd, session_store: store)
    end

    # A session renamed before it has any timestamped entry in the store:
    # metadata lines carry no timestamp.
    def untimed_entries
      transcript = CLITranscript.new(session_id: session_id, cwd: cwd)
      transcript.ai_title('Reading a.rb')
      transcript.last_prompt('what does a.rb define?')
      transcript.store_entries
    end

    context 'with a store that lists its sessions' do
      let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }

      it 'is the same from get_session_info and from list_sessions' do
        store.append(key, conversation.store_entries)
        listed = ClaudeAgentSDK.list_sessions(directory: cwd, session_store: store).first

        expect(info_from(store).last_modified).to eq(listed.last_modified)
        expect(Time.at(listed.last_modified / 1000).year).to eq(Time.now.year) # the adapter's clock, not the entries'
      end

      it 'is the same for a session whose entries carry no timestamp' do
        store.append(key, untimed_entries)
        listed = ClaudeAgentSDK.list_sessions(directory: cwd, session_store: store).first

        expect(listed.last_modified).to be > 0
        expect(info_from(store).last_modified).to eq(listed.last_modified)
      end
    end

    context 'with a store that only summarizes its sessions' do
      let(:store) do
        Class.new(ClaudeAgentSDK::InMemorySessionStore) { undef_method :list_sessions }.new
      end

      it 'takes the mtime of the summary' do
        store.append(key, conversation.store_entries)
        listed = ClaudeAgentSDK.list_sessions(directory: cwd, session_store: store).first

        expect(info_from(store).last_modified).to eq(listed.last_modified)
      end
    end

    # Only #append and #load are required of an adapter.
    context 'with a store that cannot list' do
      let(:store) do
        Class.new do
          def initialize = @sessions = {}
          def append(key, entries) = (@sessions[key] ||= []).concat(entries)
          def load(key) = @sessions[key]
        end.new
      end

      it 'falls back to the timestamp of the last entry' do
        entries = conversation.store_entries
        store.append(key, entries)

        expect(info_from(store).last_modified)
          .to eq(ClaudeAgentSDK::Sessions.parse_iso_timestamp_ms(entries[-2]['timestamp']))
      end

      it 'is 0 when no entry carries a timestamp' do
        store.append(key, untimed_entries)

        expect(info_from(store).last_modified).to eq(0)
      end
    end
  end
end
