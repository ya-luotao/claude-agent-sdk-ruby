# frozen_string_literal: true

require 'spec_helper'
require 'async'

RSpec.describe ClaudeAgentSDK::TranscriptMirrorBatcher do
  # Between attempts the batcher slept with Async::Task#sleep when a reactor
  # was running. async deprecated that in favor of Kernel#sleep, which is
  # scheduler-aware, and warns about it when warnings are on (`ruby -w`):
  # one line on stderr per retry.
  describe 'retry backoff' do
    let(:projects) { '/cfg/projects' }
    let(:file_path) { "#{projects}/-Users-dev-app/11111111-1111-4111-8111-111111111111.jsonl" }

    # What `ruby -w` turns on.
    around do |example|
      verbose = $VERBOSE
      deprecated = Warning[:deprecated]
      $VERBOSE = true
      Warning[:deprecated] = true
      example.run
    ensure
      $VERBOSE = verbose
      Warning[:deprecated] = deprecated
    end

    it 'retries inside a reactor without a deprecation warning' do
      stub_const("#{described_class}::MIRROR_APPEND_BACKOFF_S", [0, 0].freeze) # nothing to wait for here
      attempts = 0
      store = Class.new(ClaudeAgentSDK::SessionStore) do
        define_method(:append) do |_key, _entries|
          attempts += 1
          raise IOError, 'connection reset' if attempts == 1
        end

        def load(_key) = nil
      end.new
      batcher = described_class.new(store: store, projects_dir: projects, on_error: ->(_key, _message) {})

      expect do
        Async do
          batcher.enqueue(file_path, [{ type: 'user', uuid: 'a' }])
          batcher.flush
        end.wait
      end.not_to output(/Async::Task#sleep/).to_stderr

      expect(attempts).to eq(2) # the backoff ran: one failure, one retry
    end
  end
end
