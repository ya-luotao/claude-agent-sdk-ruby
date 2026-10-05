# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'fileutils'
require 'securerandom'
require 'timeout'
require 'tmpdir'

# ClaudeAgentSDK.query and ClaudeAgentSDK::Client run the same session: the
# difference between them is lifecycle, not protocol. This runs one scenario
# through both — query() on one side, Client.open + #query + #receive_messages
# + disconnect on the other — against the same in-memory CLI, the same
# store-backed resume and the same kind of recording observer, and compares
# what each did: what the caller got, what the block was given, what the
# observer was told and what became of the materialized resume dir.
#
# They must agree on all of it, in every scenario, under both callback
# scheduling modes. Where they are meant to differ is spelled out at the end,
# and nowhere else.
RSpec.describe 'entry point parity' do
  let(:fake_cli) { EntryPointHarness::FakeCLI }
  let(:created) { [] }
  let(:disposals) { [] }
  let(:preserved) { [] }
  let(:wrapped) { [] }
  let(:session_tasks) { [] }
  let(:block_error) { Class.new(StandardError) }

  let(:cwd) { Dir.mktmpdir('parity-cwd-') }
  let(:user_config_dir) { Dir.mktmpdir('parity-config-') } # keeps the developer's own config out of it
  let(:session_id) { SecureRandom.uuid }
  let(:store) do
    ClaudeAgentSDK::InMemorySessionStore.new.tap do |store|
      store.append({ 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id },
                   [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => 'hi' } }])
    end
  end

  # A regression here tends to be a wait that never ends; fail instead.
  around do |example|
    Timeout.timeout(30) { example.run }
  end

  # Record what becomes of every materialized resume dir: removed (:cleanup)
  # or kept because the mirror dropped batches (:preserve; not carried out).
  before do
    allow(ClaudeAgentSDK::SessionResume).to receive(:materialize_resume_session).and_wrap_original do |original, options|
      original.call(options).tap do |materialized|
        allow(materialized).to receive(:cleanup).and_wrap_original do |cleanup|
          disposals << :cleanup
          cleanup.call
        end
        allow(materialized).to receive(:preserve_transcripts) do
          disposals << :preserve
          preserved << materialized.config_dir
        end
      end
    end
  end

  after do
    [cwd, user_config_dir, *preserved].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # Both entry points construct their transport from SubprocessCLITransport
  # (so both materialize the resume): hand them a FakeCLI instead.
  def stub_transport(**switches)
    note_session_task = ->(_cli) { session_tasks << Async::Task.current }
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |transport_options|
      fake_cli.new(transport_options, on_connect: note_session_task, **switches).tap { |cli| created << cli }
    end
  end

  def result_frame(turns)
    EntryPointHarness::RESULT_FRAME.merge(num_turns: turns)
  end

  # What the caller got from the call: [:returned, value], or the exception.
  def outcome_of
    [:returned, yield]
  rescue Exception => e # rubocop:disable Lint/RescueException -- a deadline may be a bare Exception
    e
  end

  shared_examples 'the same session through both entry points' do |scheduling|
    let(:wrapper) do
      lambda do |invocation|
        wrapped << true
        invocation.call
      end
    end

    define_method(:options_with) do |observer|
      ClaudeAgentSDK::ClaudeAgentOptions.new(
        session_store: store, resume: session_id, cwd: cwd, env: { 'CLAUDE_CONFIG_DIR' => user_config_dir },
        observers: [observer], callback_scheduling: scheduling, callback_wrapper: wrapper
      )
    end

    # One run through an entry point, reduced to what must not differ.
    def trace(observer, delivered, outcome)
      { outcome: outcome.is_a?(Exception) ? [outcome.class, outcome.message] : outcome,
        delivered: delivered.map(&:class),
        notified: observer.names,
        on_message: observer.payloads(:on_message).map(&:class),
        errors: observer.payloads(:on_error).map(&:class),
        disposal: disposals.last }
    end

    # query(), with a block that reacts to each message with +reaction+.
    def one_shot(reaction = :continue, **observer_reactions)
      observer = EntryPointHarness::RecordingObserver.new(**observer_reactions)
      delivered = []
      error = block_error
      outcome = outcome_of do
        ClaudeAgentSDK.query(prompt: 'hello', options: options_with(observer)) do |message|
          delivered << message
          raise error, 'block boom' if reaction == :raise
          break :stopped if reaction == :break
        end
      end
      trace(observer, delivered, outcome)
    end

    # Client.open + #query + #receive_messages (+ the disconnect of .open),
    # with the same block.
    def session(reaction = :continue, **observer_reactions)
      observer = EntryPointHarness::RecordingObserver.new(**observer_reactions)
      delivered = []
      error = block_error
      outcome = outcome_of do
        ClaudeAgentSDK::Client.open(options: options_with(observer)) do |client|
          client.query('hello')
          client.receive_messages do |message|
            delivered << message
            raise error, 'block boom' if reaction == :raise
            break :stopped if reaction == :break
          end
        end
      end
      trace(observer, delivered, outcome)
    end

    it 'a run that completes' do
      stub_transport(hang_up_after: 1)

      expect(session).to eq(one_shot)
      expect(one_shot).to include(
        outcome: [:returned, nil],
        delivered: [ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage],
        notified: %i[on_user_prompt on_message on_message on_close],
        on_message: [ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage],
        disposal: :cleanup
      )
      expect(created).to all(be_closed)
      expect(wrapped).not_to be_empty
    end

    it 'a run with several results: every message is delivered' do
      stub_transport(replies: [EntryPointHarness::ASSISTANT_FRAME, result_frame(1), EntryPointHarness::ASSISTANT_FRAME,
                               result_frame(2)], hang_up_after: 1)

      expect(session).to eq(one_shot)
      expect(one_shot[:delivered]).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage] * 2)
    end

    it 'on_user_prompt is notified before the prompt is written' do
      order = []
      stub_transport(hang_up_after: 1, on_write: ->(frame, _cli) { order << :written if frame[:type] == 'user' })
      noting = { on_user_prompt: ->(_prompt) { order << :notified } }

      one_shot(**noting)
      session(**noting)

      expect(order).to eq(%i[notified written notified written])
    end

    it 'a stream that dies after one message' do
      stub_transport(replies: [EntryPointHarness::ASSISTANT_FRAME, ClaudeAgentSDK::CLIConnectionError.new('CLI crashed')])

      expect(session).to eq(one_shot)
      expect(one_shot).to include(
        outcome: [ClaudeAgentSDK::CLIConnectionError, 'CLI crashed'],
        delivered: [ClaudeAgentSDK::AssistantMessage],
        notified: %i[on_user_prompt on_message on_error on_close],
        errors: [ClaudeAgentSDK::CLIConnectionError],
        disposal: :cleanup
      )
    end

    it 'a block that raises' do
      stub_transport(hang_up_after: 1)

      expect(session(:raise)).to eq(one_shot(:raise))
      expect(one_shot(:raise)).to include(
        outcome: [block_error, 'block boom'],
        delivered: [ClaudeAgentSDK::AssistantMessage],
        notified: %i[on_user_prompt on_message on_error on_close],
        errors: [block_error],
        disposal: :cleanup
      )
    end

    it 'a block that breaks: the value of the break is returned, and no error is notified' do
      stub_transport(hang_up_after: 1)

      one_shot_trace = one_shot(:break)
      session_trace = session(:break)

      expect(session_trace.except(:outcome)).to eq(one_shot_trace.except(:outcome))
      expect(one_shot_trace).to include(outcome: %i[returned stopped], delivered: [ClaudeAgentSDK::AssistantMessage],
                                        notified: %i[on_user_prompt on_message on_close], disposal: :cleanup)
      # Client.open returns the value of its own block: #receive_messages' value.
      expect(session_trace[:outcome]).to eq(%i[returned stopped])
    end

    it 'a mirror that dropped batches: the materialized resume dir is preserved' do
      stub_transport(hang_up_after: 1)
      dropping = Struct.new(:dropped) do
        def enqueue(*); end
        def flush; end
        def close; end
        def batches_dropped? = dropped
      end
      allow(ClaudeAgentSDK::SessionResume).to receive(:build_mirror_batcher).and_return(dropping.new(true))

      expect(session).to eq(one_shot)
      expect(disposals).to eq(%i[preserve preserve])
    end

    # A deadline that expires on the task driving the session while it is in
    # on_message. Delivered once the observer has signalled that it is
    # running, the way an expired task.with_timeout delivers it. With :thread
    # the task waits for the observer's thread and the expiry surfaces as an
    # error of the run; with :inline it lands inside the observer, which
    # contains it, and the run carries on.
    describe 'an observer interrupted by a deadline' do
      def interrupted
        entered = Thread::Queue.new
        release = Thread::Queue.new
        blocking = { on_message: lambda do |_message|
          next if entered.closed?

          entered << true
          entered.close
          release.pop
        end }
        Sync do |task|
          result = nil
          runner = task.async { result = yield blocking }
          raise 'on_message was never entered' unless entered.pop(timeout: 5)

          EntryPointHarness.expire_deadline_on(session_tasks.last)
          runner.wait
          result
        ensure
          release.close
        end
      end

      it 'does the same in both' do
        stub_transport(hang_up_after: 1)

        one_shot_trace = interrupted { |blocking| one_shot(**blocking) }
        session_trace = interrupted { |blocking| session(**blocking) }

        expect(session_trace).to eq(one_shot_trace)
        expect(one_shot_trace).to include(disposal: :cleanup)
        expect(created).to all(be_closed)
        if scheduling == :thread
          expect(one_shot_trace).to include(outcome: [Async::TimeoutError, 'execution expired'],
                                            delivered: [],
                                            notified: %i[on_user_prompt on_message on_error on_close],
                                            errors: [Async::TimeoutError])
        else
          expect(one_shot_trace).to include(outcome: [:returned, nil],
                                            delivered: [ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage],
                                            notified: %i[on_user_prompt on_message on_message on_close],
                                            errors: [])
        end
      end
    end

    # The differences that are meant to be there: the lifecycle each entry
    # point documents. Everything above holds apart from these.
    describe 'the expected differences' do
      it "session_id on the wire: '' from query(), 'default' from Client#query" do
        stub_transport(hang_up_after: 1)

        one_shot
        session

        expect(created.map { |cli| cli.user_writes.map { |frame| frame[:session_id] } }).to eq([[''], ['default']])
      end

      it 'L2: stdin is closed after the prompt by query() only' do
        stub_transport(hang_up_after: 1)

        one_shot
        session

        expect(created.map(&:input_ended?)).to eq([true, false])
      end

      it 'L8: on_close follows on_error after a failed connect from query() only' do
        stub_transport(connect_error: IOError.new('no route'))

        one_shot_trace = one_shot
        session_trace = session

        expect(one_shot_trace).to include(outcome: [IOError, 'no route'], notified: %i[on_error on_close])
        expect(session_trace).to include(outcome: [IOError, 'no route'], notified: %i[on_error])
        expect(session_trace.except(:notified)).to eq(one_shot_trace.except(:notified))
        expect(disposals).to eq(%i[cleanup cleanup])
      end

      it 'a close that raises after a failed connect: query() raises the close error, Client the connect error' do
        allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |transport_options|
          fake_cli.new(transport_options, connect_error: IOError.new('no route'),
                                          close_errors: [ArgumentError.new('close failed')]).tap { |cli| created << cli }
        end

        one_shot_trace = one_shot
        session_trace = nil
        expect { session_trace = session }.to output(/cleanup after failed connect raised: close failed/).to_stderr

        expect(one_shot_trace[:outcome]).to eq([ArgumentError, 'close failed'])
        expect(session_trace[:outcome]).to eq([IOError, 'no route'])
        expect(disposals).to eq(%i[cleanup cleanup])
      end

      it 'a query handler whose close raises: both raise it, and only Client closes the transport again' do
        allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |transport_options|
          fake_cli.new(transport_options, hang_up_after: 1, close_errors: [IOError.new('reap failed')])
                  .tap { |cli| created << cli }
        end

        one_shot_trace = one_shot
        session_trace = session

        expect(session_trace).to eq(one_shot_trace)
        expect(one_shot_trace).to include(outcome: [IOError, 'reap failed'], disposal: :cleanup)
        expect(created.map(&:close_calls)).to eq([1, 2])
        expect(created.map(&:closed?)).to eq([false, true])
      end
    end
  end

  %i[thread inline].each do |scheduling|
    context "with callback_scheduling: #{scheduling} and a callback_wrapper" do
      it_behaves_like 'the same session through both entry points', scheduling
    end
  end

  # Client#receive_response and ask are not counterparts of anything on the
  # other side: one stops at the first result, the other returns the last.
  describe 'the two ways to wait for a result' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new }

    before do
      stub_transport(replies: [EntryPointHarness::ASSISTANT_FRAME, result_frame(1), EntryPointHarness::ASSISTANT_FRAME,
                               result_frame(2)], hang_up_after: 1)
    end

    it 'Client#receive_response stops at the first ResultMessage, and the rest is still there to receive' do
      first = []
      rest = []

      ClaudeAgentSDK::Client.open(options: options) do |client|
        client.query('hello')
        client.receive_response { |message| first << message }
        client.receive_messages { |message| rest << message }
      end

      expect(first.map(&:class)).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(first.last.num_turns).to eq(1)
      expect(rest.map(&:class)).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
    end

    it 'ask consumes the whole run and returns the last ResultMessage' do
      seen = []

      result = ClaudeAgentSDK.ask('hello', options: options) { |message| seen << message.class }

      expect(result.num_turns).to eq(2)
      expect(seen).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage] * 2)
    end
  end
end
