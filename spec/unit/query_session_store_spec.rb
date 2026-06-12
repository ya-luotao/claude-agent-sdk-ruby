# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

# SessionStore wiring on the one-shot ClaudeAgentSDK.query() entry point:
# fail-fast validation, transcript-mirror batcher install, and resume
# materialization + temp-dir cleanup — at parity with ClaudeAgentSDK::Client.
RSpec.describe 'ClaudeAgentSDK.query with session_store' do
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }

  describe 'fail-fast validation (before spawning the CLI)' do
    it 'raises for an invalid session_store_flush' do
      opts = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, session_store_flush: 'bogus')
      expect { ClaudeAgentSDK.query(prompt: 'hi', options: opts) { nil } }
        .to raise_error(ArgumentError, /session_store_flush/)
    end

    it 'raises when session_store is combined with enable_file_checkpointing' do
      opts = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, enable_file_checkpointing: true)
      expect { ClaudeAgentSDK.query(prompt: 'hi', options: opts) { nil } }
        .to raise_error(ArgumentError, /enable_file_checkpointing/)
    end
  end

  describe 'transcript-mirror + resume wiring' do
    # Stub out the subprocess transport and Query handler so query() exercises
    # its session_store wiring without spawning the real CLI.
    let(:transport) do
      instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: nil, write: nil, close: nil)
    end
    let(:query_handler) do
      instance_double(
        ClaudeAgentSDK::Query,
        start: nil, initialize_protocol: nil, wait_for_result_and_end_input: nil,
        receive_messages: nil, close: nil
      )
    end

    before do
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)
      allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
    end

    it 'installs a TranscriptMirrorBatcher on the query handler when session_store is set' do
      captured = nil
      allow(query_handler).to receive(:set_transcript_mirror_batcher) { |b| captured = b }

      ClaudeAgentSDK.query(prompt: 'hi', options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store)) { nil }

      expect(captured).to be_a(ClaudeAgentSDK::TranscriptMirrorBatcher)
    end

    it 'does not install a batcher when no session_store is set' do
      allow(query_handler).to receive(:set_transcript_mirror_batcher)
      ClaudeAgentSDK.query(prompt: 'hi', options: ClaudeAgentSDK::ClaudeAgentOptions.new) { nil }
      expect(query_handler).not_to have_received(:set_transcript_mirror_batcher)
    end

    it 'materializes a store-backed resume and cleans up the temp dir afterward' do
      allow(query_handler).to receive(:set_transcript_mirror_batcher)
      materialized = instance_double(ClaudeAgentSDK::MaterializedResume, cleanup: nil)
      allow(ClaudeAgentSDK::SessionResume).to receive(:materialize_resume_session).and_return(materialized)
      allow(ClaudeAgentSDK::SessionResume).to receive(:apply_materialized_options) { |opts, _m| opts }

      opts = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: SecureRandom.uuid)
      ClaudeAgentSDK.query(prompt: 'hi', options: opts) { nil }

      expect(ClaudeAgentSDK::SessionResume).to have_received(:materialize_resume_session)
      expect(materialized).to have_received(:cleanup) # temp dir removed in the ensure block
    end

    it 'cleans up a materialized resume even when query handler close raises' do
      allow(query_handler).to receive(:set_transcript_mirror_batcher)
      allow(query_handler).to receive(:close).and_raise('close boom')
      materialized = instance_double(ClaudeAgentSDK::MaterializedResume, cleanup: nil)
      allow(ClaudeAgentSDK::SessionResume).to receive(:materialize_resume_session).and_return(materialized)
      allow(ClaudeAgentSDK::SessionResume).to receive(:apply_materialized_options) { |opts, _m| opts }

      opts = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: SecureRandom.uuid)
      expect { ClaudeAgentSDK.query(prompt: 'hi', options: opts) { nil } }.to raise_error(RuntimeError, /close boom/)
      expect(materialized).to have_received(:cleanup)
    end
  end
end
