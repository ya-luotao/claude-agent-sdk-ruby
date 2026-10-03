# frozen_string_literal: true

require 'spec_helper'
require 'delegate'
require 'claude_agent_sdk/testing/session_store_conformance'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# Only #append and #load are required of a SessionStore. An optional method
# the adapter does not implement can still LOOK implemented: behind a
# delegating wrapper every stub inherited from SessionStore answers
# respond_to?, and an adapter may opt out of one at run time by raising
# NotImplementedError itself. NotImplementedError is a ScriptError, so it
# passes every `rescue StandardError`.
RSpec.describe 'a session store whose optional methods raise NotImplementedError' do
  include_context 'with a Claude config dir'

  let(:session_id) { 'e5f6a7b8-c9d0-4e1f-8a2b-3c4d5e6f7a8b' }
  let(:agent_id) { 'c3d4e5f6a7b8c9d0' }
  let(:key) { { 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id } }

  # An adapter with the two required methods, the optional ones inherited.
  let(:minimal_store_class) do
    Class.new(ClaudeAgentSDK::SessionStore) do
      def initialize
        super
        @sessions = {}
      end

      def append(key, entries)
        (@sessions[key] ||= []).concat(entries) unless entries.empty?
      end

      def load(key) = @sessions[key]
    end
  end

  def conversation
    transcript = CLITranscript.new(session_id: session_id, cwd: cwd)
    transcript.queue_operations('what does a.rb define?')
    transcript.prompt(:prompt, 'what does a.rb define?')
    transcript.assistant(:answer, transcript.text('Foo.'), parent: :prompt)
    transcript.last_prompt('what does a.rb define?', leaf: :answer)
    transcript.store_entries
  end

  def subagent_conversation
    transcript = CLITranscript.new(session_id: session_id, cwd: cwd, agent_id: agent_id)
    transcript.prompt(:task, 'Read a.rb')
    transcript.assistant(:report, transcript.text('It defines Foo.'), parent: :task)
    transcript.store_entries
  end

  def seed(store)
    store.append(key, conversation)
    store.append(key.merge('subpath' => "subagents/agent-#{agent_id}"), subagent_conversation)
    store
  end

  # A metrics or tenancy decorator around a minimal adapter.
  context 'with a delegating wrapper around an adapter that implements only append and load' do
    let(:store) { seed(SimpleDelegator.new(minimal_store_class.new)) }

    it 'looks as if it implemented every optional method' do
      project_key = key['project_key']
      { list_sessions: project_key, list_session_summaries: project_key, delete: key,
        list_subkeys: key }.each do |method, argument|
        expect(ClaudeAgentSDK::SessionStore.implements?(store, method)).to be(true)
        expect { store.public_send(method, argument) }.to raise_error(NotImplementedError)
      end
    end

    it 'delete_session is the no-op it is for a store without #delete' do
      expect(ClaudeAgentSDK.delete_session(session_id: session_id, directory: cwd, session_store: store)).to be_nil
      expect(store.load(key).length).to eq(conversation.length)
    end

    it 'list_sessions raises the ArgumentError of a store that cannot list' do
      expect { ClaudeAgentSDK.list_sessions(directory: cwd, session_store: store) }
        .to raise_error(ArgumentError, /implements neither list_session_summaries nor list_sessions/)
    end

    it 'list_subagents raises the ArgumentError of a store without list_subkeys' do
      expect { ClaudeAgentSDK.list_subagents(session_id: session_id, directory: cwd, session_store: store) }
        .to raise_error(ArgumentError, /does not implement list_subkeys/)
    end

    it 'get_subagent_messages reads the direct subagent path' do
      messages = ClaudeAgentSDK.get_subagent_messages(session_id: session_id, agent_id: agent_id, directory: cwd,
                                                      session_store: store)

      expect(messages.map(&:text)).to eq(['Read a.rb', 'It defines Foo.'])
    end

    it 'get_session_info falls back to the timestamp of the last entry for last_modified' do
      info = ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd, session_store: store)

      expect(info.summary).to eq('what does a.rb define?')
      expect(info.last_modified).to eq(ClaudeAgentSDK::Sessions.parse_iso_timestamp_ms(conversation[-2]['timestamp']))
    end

    it 'resume materializes the main transcript' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: session_id, cwd: cwd,
                                                       env: { 'CLAUDE_CONFIG_DIR' => config_dir })

      materialized = ClaudeAgentSDK::SessionResume.materialize_resume_session(options)
      begin
        transcript = File.join(materialized.config_dir, 'projects', key['project_key'], "#{session_id}.jsonl")
        expect(File.readlines(transcript).length).to eq(conversation.length)
      ensure
        materialized&.cleanup
      end
    end
  end

  # An adapter that has the method and declines it at run time.
  context 'with an adapter that raises NotImplementedError from one optional method' do
    def opting_out_of(method)
      seed(Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        define_method(method) { |*| raise NotImplementedError, "#{method} is disabled for this tenant" }
      end.new)
    end

    it 'list_sessions falls back from list_session_summaries to list_sessions' do
      store = opting_out_of(:list_session_summaries)

      expect(ClaudeAgentSDK.list_sessions(directory: cwd, session_store: store).map(&:session_id)).to eq([session_id])
    end

    it 'list_sessions uses the summaries without the listing' do
      store = opting_out_of(:list_sessions)

      expect(ClaudeAgentSDK.list_sessions(directory: cwd, session_store: store).map(&:session_id)).to eq([session_id])
    end

    it 'get_session_info takes last_modified from the summaries when the listing is declined' do
      store = opting_out_of(:list_sessions)
      listed = ClaudeAgentSDK.list_sessions(directory: cwd, session_store: store).first

      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd, session_store: store).last_modified)
        .to eq(listed.last_modified)
    end

    it 'delete_session is a no-op' do
      store = opting_out_of(:delete)

      expect(ClaudeAgentSDK.delete_session(session_id: session_id, directory: cwd, session_store: store)).to be_nil
      expect(store.load(key)).not_to be_nil
    end

    it 'resume continues the newest session without the summaries' do
      store = opting_out_of(:list_session_summaries)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, continue_conversation: true, cwd: cwd,
                                                       env: { 'CLAUDE_CONFIG_DIR' => config_dir })

      materialized = ClaudeAgentSDK::SessionResume.materialize_resume_session(options)
      begin
        expect(materialized.resume_session_id).to eq(session_id)
      ensure
        materialized&.cleanup
      end
    end
  end

  # list_subkeys works; the REQUIRED load fails for the subagent it lists.
  # That is not "list_subkeys is not implemented": the resume must fail, and
  # leave nothing behind, rather than hand over a session without its
  # subagent.
  context 'when the required load fails for a subagent that list_subkeys names' do
    let(:store) do
      seed(Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def load(key)
          raise NotImplementedError, 'load is not available for subpaths' if key['subpath']

          super
        end
      end.new)
    end
    # The resume materializes into Dir.tmpdir: a private one shows what is left.
    let(:tmpdir) { File.join(cwd, 'tmp').tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:options) do
      ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: session_id, cwd: cwd,
                                             cli_path: File.join(cwd, 'no-such-claude'),
                                             env: { 'CLAUDE_CONFIG_DIR' => config_dir })
    end

    around do |example|
      saved = ENV.fetch('TMPDIR', nil)
      ENV['TMPDIR'] = tmpdir
      example.run
    ensure
      saved.nil? ? ENV.delete('TMPDIR') : ENV['TMPDIR'] = saved
    end

    it 'lets the NotImplementedError surface from the resume materialization and removes its directory' do
      expect { ClaudeAgentSDK::SessionResume.materialize_resume_session(options) }
        .to raise_error(NotImplementedError, 'load is not available for subpaths')
      expect(Dir.children(tmpdir)).to eq([])
    end

    # The public path: query() materializes the resume before it starts a CLI
    # (there is none at cli_path, and it is never looked for).
    it 'lets it surface from query() with resume: and session_store:' do
      expect { ClaudeAgentSDK.query(prompt: 'continue', options: options) { |_message| nil } }
        .to raise_error(NotImplementedError, 'load is not available for subpaths')
      expect(Dir.children(tmpdir)).to eq([])
    end
  end

  it 'still lets a NotImplementedError from a required method through' do
    store = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
      def load(_key) = raise(NotImplementedError, 'load is not available')
    end.new

    expect { ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd, session_store: store) }
      .to raise_error(NotImplementedError)
  end

  describe 'the conformance suite' do
    it 'skips the contracts of an optional method the adapter declines at run time' do
      adapter = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def list_session_summaries(_project_key) = raise(NotImplementedError, 'summaries are disabled for this tenant')
      end

      expect(ClaudeAgentSDK::Testing.run_session_store_conformance(-> { adapter.new })).to be_nil
    end

    it 'runs the required contracts only for a delegating wrapper around a minimal adapter' do
      make_store = -> { SimpleDelegator.new(minimal_store_class.new) }

      expect(ClaudeAgentSDK::Testing.run_session_store_conformance(make_store)).to be_nil
    end

    it 'still fails an adapter whose optional method breaks a contract' do
      adapter = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def list_subkeys(_key) = ['subagents/agent-of-another-session']
      end

      expect { ClaudeAgentSDK::Testing.run_session_store_conformance(-> { adapter.new }) }
        .to raise_error(ClaudeAgentSDK::Testing::ConformanceError)
    end
  end
end
