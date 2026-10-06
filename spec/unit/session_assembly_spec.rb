# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'securerandom'

# SessionAssembly is the implementation ClaudeAgentSDK.query and Client share
# for acquiring a session's resources, writing prompts, delivering messages
# and disposing of the resources. These examples are the one place the
# mapping from options to the Query is spelled out in full, and the one place
# each step of acquisition and disposal is failed in turn.
#
# Only its own methods are called; what it did is read off the transport, the
# Query and the materialized resume it was given.
RSpec.describe ClaudeAgentSDK::SessionAssembly do
  let(:observer) { EntryPointHarness::RecordingObserver.new }
  let(:dispatch) { ClaudeAgentSDK::Dispatch.new([observer], scheduling: :thread, wrapper: nil) }
  let(:cli) { EntryPointHarness::FakeCLI.new }
  let(:handler) do
    instance_double(ClaudeAgentSDK::Query, start: nil, initialize_protocol: nil, close: nil,
                                           set_transcript_mirror_batcher: nil, mirror_batches_dropped?: false)
  end
  let(:query_kwargs) { [] }
  let(:materialized) do
    instance_double(ClaudeAgentSDK::MaterializedResume, cleanup: nil, preserve_transcripts: nil,
                                                        config_dir: '/nonexistent/claude-resume-x',
                                                        resume_session_id: SecureRandom.uuid)
  end
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }

  def options_with(**attributes)
    ClaudeAgentSDK::ClaudeAgentOptions.new(**attributes)
  end

  def assembly(options = options_with, source: { instance: cli }, with: dispatch)
    described_class.new(options, dispatch: with, transport_source: source)
  end

  # Query.new hands back the +handler+ double and records what it was given.
  def stub_query
    allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
      query_kwargs << kwargs
      handler
    end
  end

  # The keywords one #connect built its Query with.
  def kwargs_for(options = options_with, **assembly_args)
    stub_query
    assembly(options, **assembly_args).connect
    query_kwargs.fetch(-1)
  end

  def resume_options(**extra)
    options_with(session_store: store, resume: materialized.resume_session_id, **extra)
  end

  def stub_materialization(result = materialized)
    allow(ClaudeAgentSDK::SessionResume).to receive(:materialize_resume_session).and_return(result)
  end

  describe '#initialize' do
    it 'acquires nothing' do
      created = []
      stub_materialization
      session = assembly(resume_options, source: { class: EntryPointHarness::FakeCLI.subprocess_class(created), args: {} })

      expect(session.query_handler).to be_nil
      expect(created).to be_empty
      expect(ClaudeAgentSDK::SessionResume).not_to have_received(:materialize_resume_session)
    end
  end

  describe '#connect: the Query it builds' do
    it 'builds exactly one, with these fifteen keywords, on the transport' do
      kwargs = kwargs_for

      expect(query_kwargs.length).to eq(1)
      expect(kwargs.keys).to contain_exactly(
        :transport, :is_streaming_mode, :can_use_tool, :hooks, :sdk_mcp_servers, :agents, :exclude_dynamic_sections,
        :system_prompt_snapshot, :skills, :forward_subagent_text, :agent_progress_summaries, :callback_scheduling,
        :callback_wrapper, :verbatim_prompts, :run_end_ceiling_ms
      )
      expect(kwargs).to include(transport: cli, is_streaming_mode: true)
    end

    it 'makes it the query_handler' do
      stub_query
      session = assembly

      expect { session.connect }.to change(session, :query_handler).from(nil).to(handler)
    end

    it 'passes can_use_tool as it is, and nil without one' do
      callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }

      expect(kwargs_for(options_with(can_use_tool: callback, permission_prompt_tool_name: 'stdio'))[:can_use_tool]).to be(callback)
      expect(kwargs_for.fetch(:can_use_tool)).to be_nil
    end

    describe 'hooks' do
      let(:callback) { ->(*) { {} } }

      it 'omits nil and empty lists, keeps matcher, callbacks and timeout, and leaves the caller Hash alone' do
        matcher = ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [callback], timeout: 7)
        hooks = { 'PostToolUse' => nil, 'Stop' => [], PreToolUse: [matcher] }

        expect(kwargs_for(options_with(hooks: hooks))[:hooks])
          .to eq('PreToolUse' => [{ matcher: 'Bash', hooks: [callback], timeout: 7 }])
        expect(hooks).to eq('PostToolUse' => nil, 'Stop' => [], PreToolUse: [matcher])
      end

      it 'passes nil when no active hook list remains, and when there are no hooks' do
        expect(kwargs_for(options_with(hooks: { 'PreToolUse' => [], 'PostToolUse' => nil })).fetch(:hooks)).to be_nil
        expect(kwargs_for.fetch(:hooks)).to be_nil
      end
    end

    it 'passes the live SDK MCP server instances, by name, and none of the other servers' do
      server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: [])
      mcp_servers = { 'calc' => server, 'files' => { type: 'stdio', command: 'files-server' } }

      expect(kwargs_for(options_with(mcp_servers: mcp_servers))[:sdk_mcp_servers]).to eq('calc' => server[:instance])
      expect(kwargs_for.fetch(:sdk_mcp_servers)).to eq({})
    end

    it 'passes agents and skills as they are' do
      agents = { 'reviewer' => ClaudeAgentSDK::AgentDefinition.new(description: 'Reviews', prompt: 'Review it') }
      kwargs = kwargs_for(options_with(agents: agents, skills: %w[pdf docx]))

      expect(kwargs[:agents]).to be(agents)
      expect(kwargs[:skills]).to eq(%w[pdf docx])
      expect(kwargs_for).to include(agents: nil, skills: nil)
    end

    # Only a genuine true/false of a preset system prompt is forwarded.
    {
      'a SystemPromptPreset with the flag on' =>
        [-> { ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', exclude_dynamic_sections: true) }, true],
      'a preset Hash with the flag on' =>
        [-> { { type: 'preset', preset: 'claude_code', exclude_dynamic_sections: true } }, true],
      'a preset Hash with the flag off' =>
        [-> { { type: 'preset', preset: 'claude_code', exclude_dynamic_sections: false } }, false],
      'a preset Hash without the flag' => [-> { { type: 'preset', preset: 'claude_code' } }, nil],
      'a plain String' => [-> { 'You are a helper' }, nil],
      'no system prompt' => [-> {}, nil]
    }.each do |label, (system_prompt, expected)|
      it "passes exclude_dynamic_sections #{expected.inspect} for #{label}" do
        expect(kwargs_for(options_with(system_prompt: system_prompt.call)).fetch(:exclude_dynamic_sections)).to be(expected)
      end
    end

    # Python #1268: the snapshot travels only for the preset and custom
    # forms, and a false value survives the trip.
    {
      'a custom Hash with snapshot false' => [-> { { type: 'custom', prompt: 'Be helpful', snapshot: false } }, false],
      'a preset Hash with snapshot true' => [-> { { type: 'preset', preset: 'claude_code', snapshot: true } }, true],
      'a preset Hash with String keys and snapshot false' =>
        [-> { { 'type' => 'preset', 'preset' => 'claude_code', 'snapshot' => false } }, false],
      'a preset Hash without snapshot' => [-> { { type: 'preset', preset: 'claude_code' } }, nil],
      'a file Hash (snapshot ignored)' => [-> { { type: 'file', path: '/p.md', snapshot: false } }, nil],
      'a custom Hash with a snapshot that is not a Boolean' =>
        [-> { { type: 'custom', prompt: 'x', snapshot: 'yes' } }, nil],
      'a SystemPromptCustom with snapshot false' =>
        [-> { ClaudeAgentSDK::SystemPromptCustom.new(prompt: 'Be helpful', snapshot: false) }, false],
      'a SystemPromptPreset with snapshot true' =>
        [-> { ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', snapshot: true) }, true],
      'a plain String' => [-> { 'Be helpful' }, nil],
      'no system prompt' => [-> {}, nil]
    }.each do |label, (system_prompt, expected)|
      it "passes system_prompt_snapshot #{expected.inspect} for #{label}" do
        expect(kwargs_for(options_with(system_prompt: system_prompt.call)).fetch(:system_prompt_snapshot)).to be(expected)
      end
    end

    it 'passes forward_subagent_text as a Boolean' do
      expect([true, false].map { |enabled| kwargs_for(options_with(forward_subagent_text: enabled))[:forward_subagent_text] })
        .to eq([true, false])
    end

    it 'passes agent_progress_summaries, telling nil from false' do
      [true, false, nil].each do |value|
        expect(kwargs_for(options_with(agent_progress_summaries: value)).fetch(:agent_progress_summaries)).to be(value)
      end
    end

    it 'passes the scheduling and the wrapper of its dispatch, not those of the options' do
      wrapper = lambda(&:call)
      inline = ClaudeAgentSDK::Dispatch.new([], scheduling: :inline, wrapper: wrapper)

      expect(kwargs_for(options_with(callback_scheduling: :thread), with: inline))
        .to include(callback_scheduling: :inline, callback_wrapper: wrapper)
      expect(kwargs_for).to include(callback_scheduling: :thread, callback_wrapper: nil)
    end

    it 'passes verbatim_prompts as it reads after the transport connected' do
      flipped = options_with
      late = EntryPointHarness::FakeCLI.new(flipped, on_connect: ->(transport) { transport.options.verbatim_prompts = true })

      expect(kwargs_for(flipped, source: { instance: late })[:verbatim_prompts]).to be(true)
      expect(kwargs_for(options_with(verbatim_prompts: true))[:verbatim_prompts]).to be(true)
      expect(kwargs_for[:verbatim_prompts]).to be(false)
    end

    it 'passes the run-end ceiling the CLI will get from the options env, or its default' do
      ceiling = ClaudeAgentSDK::Query::RUN_END_CEILING_ENV_VAR

      expect(kwargs_for(options_with(env: { ceiling => '1500' }))[:run_end_ceiling_ms]).to eq(1500)
      expect(kwargs_for(options_with(env: { ceiling => 'soon' }))[:run_end_ceiling_ms])
        .to eq(ClaudeAgentSDK::Query::DEFAULT_RUN_END_CEILING_MS)
    end
  end

  describe '#connect: the order of acquisition' do
    it 'connects the transport, builds the Query, then starts it and performs the handshake' do
      steps = []
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport)
      allow(transport).to receive(:connect) { steps << :transport_connect }
      allow(ClaudeAgentSDK::Query).to receive(:new) do
        steps << :query_new
        handler
      end
      allow(handler).to receive(:start) { steps << :start }
      allow(handler).to receive(:initialize_protocol) { steps << :initialize_protocol }

      assembly(source: { instance: transport }).connect

      expect(steps).to eq(%i[transport_connect query_new start initialize_protocol])
    end

    it 'installs the transcript mirror before the read loop starts, when a session_store is configured' do
      steps = []
      stub_query
      allow(handler).to receive(:set_transcript_mirror_batcher) { |batcher| steps << batcher.class }
      allow(handler).to receive(:start) { steps << :start }

      assembly(options_with(session_store: store)).connect

      expect(steps).to eq([ClaudeAgentSDK::TranscriptMirrorBatcher, :start])
    end

    it 'builds the mirror from the store, the env, the flush mode and the wrapper, reporting errors to the Query' do
      wrapper = lambda(&:call)
      stub_query
      allow(handler).to receive(:report_mirror_error)
      allow(ClaudeAgentSDK::SessionResume).to receive(:build_mirror_batcher).and_call_original
      options = options_with(session_store: store, session_store_flush: 'eager', env: { 'CLAUDE_CONFIG_DIR' => '/cfg' })

      assembly(options, with: ClaudeAgentSDK::Dispatch.new([], scheduling: :thread, wrapper: wrapper)).connect

      expect(ClaudeAgentSDK::SessionResume).to have_received(:build_mirror_batcher) do |**kwargs|
        expect(kwargs).to include(store: store, env: { 'CLAUDE_CONFIG_DIR' => '/cfg' }, eager: true, callback_wrapper: wrapper)
        kwargs.fetch(:on_error).call({ 'session_id' => 's' }, 'append failed')
      end
      expect(handler).to have_received(:report_mirror_error).with({ 'session_id' => 's' }, 'append failed')
    end

    it 'installs no mirror without a session_store' do
      stub_query

      assembly.connect

      expect(handler).not_to have_received(:set_transcript_mirror_batcher)
    end
  end

  # A store-backed resume is materialized only when the repointed options
  # will reach a transport that spawns the CLI on this host with them: one the
  # assembly constructs itself, from SubprocessCLITransport or a subclass.
  describe '#connect: which transports get a materialized resume' do
    let(:created) { [] }

    before do
      stub_query
      stub_materialization
    end

    def connect_with(source, options = resume_options)
      assembly(options, source: source).connect
      options
    end

    it 'none for an injected transport' do
      connect_with({ instance: cli })

      expect(ClaudeAgentSDK::SessionResume).not_to have_received(:materialize_resume_session)
    end

    it 'one for SubprocessCLITransport itself, constructed with the repointed options' do
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |transport_options|
        EntryPointHarness::FakeCLI.new(transport_options).tap { |transport| created << transport }
      end

      options = connect_with({ class: ClaudeAgentSDK::SubprocessCLITransport, args: {} })

      handed = created.fetch(0).options
      expect(ClaudeAgentSDK::SessionResume).to have_received(:materialize_resume_session).with(options).once
      expect(handed).not_to be(options)
      expect(handed).to have_attributes(env: { 'CLAUDE_CONFIG_DIR' => '/nonexistent/claude-resume-x' },
                                        resume: materialized.resume_session_id, continue_conversation: false)
      expect(options.env).to eq({}) # the caller's options are left alone
    end

    it 'one for a subclass of it' do
      connect_with({ class: EntryPointHarness::FakeCLI.subprocess_class(created), args: {} })

      expect(created.fetch(0).config_dir).to eq('/nonexistent/claude-resume-x')
    end

    it 'none for any other class, which gets the options as they are' do
      options = connect_with({ class: EntryPointHarness::FakeCLI.foreign_class(created), args: {} })

      expect(ClaudeAgentSDK::SessionResume).not_to have_received(:materialize_resume_session)
      expect(created.fetch(0).options).to be(options)
    end

    it 'none for a factory that is not a Class' do
      factory = Object.new
      factory.define_singleton_method(:new) { |transport_options, **| EntryPointHarness::FakeCLI.new(transport_options) }

      connect_with({ class: factory, args: {} })

      expect(ClaudeAgentSDK::SessionResume).not_to have_received(:materialize_resume_session)
    end

    it 'none without a session_store' do
      options = connect_with({ class: EntryPointHarness::FakeCLI.subprocess_class(created), args: {} }, options_with)

      expect(ClaudeAgentSDK::SessionResume).not_to have_received(:materialize_resume_session)
      expect(created.fetch(0).options).to be(options)
    end

    it 'the options as they are when the store has nothing to materialize' do
      stub_materialization(nil)

      options = connect_with({ class: EntryPointHarness::FakeCLI.subprocess_class(created), args: {} })

      expect(created.fetch(0).options).to be(options)
    end

    it 'constructs a class with the args as keywords' do
      received = nil
      transport_class = Class.new do
        define_singleton_method(:new) do |_options, **kwargs|
          received = kwargs
          EntryPointHarness::FakeCLI.new
        end
      end

      connect_with({ class: transport_class, args: { sandbox: 'box-1', retries: 2 } })

      expect(received).to eq(sandbox: 'box-1', retries: 2)
    end
  end

  # Nothing is rolled back by #connect: the error propagates as it was
  # raised, and #close_resources disposes of what was acquired before it.
  describe '#connect: a step that fails' do
    let(:created) { [] }
    let(:failure) { IOError.new('step failed') }
    let(:transport) { instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: nil, close: nil) }
    let(:source) do
      doubled = transport
      { class: Class.new(ClaudeAgentSDK::SubprocessCLITransport) { define_singleton_method(:new) { |_options, **| doubled } },
        args: {} }
    end

    before do
      stub_query
      stub_materialization
    end

    def fail_connect(session)
      expect { session.connect }.to raise_error(failure)
      session.close_resources(always_close_transport: true)
    end

    it 'repointing the options: the materialized dir is removed, and no transport was constructed' do
      allow(ClaudeAgentSDK::SessionResume).to receive(:apply_materialized_options).and_raise(failure)

      fail_connect(assembly(resume_options, source: { class: EntryPointHarness::FakeCLI.subprocess_class(created), args: {} }))

      expect(materialized).to have_received(:cleanup)
      expect(created).to be_empty
    end

    it 'constructing the transport: the materialized dir is removed' do
      raising = Class.new(ClaudeAgentSDK::SubprocessCLITransport)
      error = failure
      raising.define_singleton_method(:new) { |_options, **| raise error }

      fail_connect(assembly(resume_options, source: { class: raising, args: {} }))

      expect(materialized).to have_received(:cleanup)
    end

    it 'connecting the transport: it is closed, the materialized dir is removed, and no Query was built' do
      allow(transport).to receive(:connect).and_raise(failure)

      fail_connect(assembly(resume_options, source: source))

      expect(transport).to have_received(:close)
      expect(materialized).to have_received(:cleanup)
      expect(ClaudeAgentSDK::Query).not_to have_received(:new)
    end

    it 'building the Query: the transport is closed and the materialized dir is removed' do
      allow(ClaudeAgentSDK::Query).to receive(:new).and_raise(failure)

      fail_connect(assembly(resume_options, source: source))

      expect(transport).to have_received(:close)
      expect(materialized).to have_received(:cleanup)
    end

    {
      'installing the mirror' => :set_transcript_mirror_batcher,
      'starting the read loop' => :start,
      'the handshake' => :initialize_protocol
    }.each do |label, step|
      it "#{label}: the Query and the transport are closed and the materialized dir is removed" do
        allow(handler).to receive(step).and_raise(failure)
        session = assembly(resume_options, source: source)

        fail_connect(session)

        expect(handler).to have_received(:close)
        expect(transport).to have_received(:close)
        expect(materialized).to have_received(:cleanup)
        expect(session.query_handler).to be_nil
      end
    end

    it 'notifies no observer' do
      allow(handler).to receive(:initialize_protocol).and_raise(failure)

      fail_connect(assembly(resume_options, source: source))

      expect(observer.events).to be_empty
    end
  end

  describe 'writing prompts' do
    let(:user_message) { { type: 'user', message: { role: 'user', content: 'hi' }, parent_tool_use_id: nil } }

    def connected(options = options_with, source: nil)
      stub_query
      assembly(options, source: source || { instance: cli }).tap(&:connect)
    end

    describe '#write_prompt' do
      it 'writes one user message with the given session_id, as one line' do
        connected.write_prompt('hello', session_id: 'abc')

        expect(cli.writes).to eq([{ type: 'user', message: { role: 'user', content: 'hello' }, parent_tool_use_id: nil,
                                    session_id: 'abc' }])
        expect(cli.lines).to match([a_string_ending_with("}\n")])
      end

      it 'requires the session_id' do
        expect { connected.write_prompt('hello') }.to raise_error(ArgumentError, /session_id/)
        expect(cli.writes).to be_empty
      end

      it 'notifies no observer: on_user_prompt is the caller\'s' do
        connected.write_prompt('hello', session_id: '')

        expect(observer.events).to be_empty
      end

      it 'stamps with the value captured in #connect by default, whatever the options say later' do
        on = options_with(verbatim_prompts: true)
        session = connected(on)
        on.verbatim_prompts = false
        session.write_prompt('one', session_id: '')
        session.write_prompt('two', session_id: '', verbatim: described_class::CAPTURED)

        expect(cli.writes).to all(include(client_composed: true))
      end

      it 'does not mark by default when the option was off at #connect and is turned on later' do
        late = options_with
        session = connected(late)
        late.verbatim_prompts = true
        session.write_prompt('hello', session_id: '')

        expect(cli.writes.first).not_to have_key(:client_composed)
      end

      it 'reads the options at write time with verbatim: :current' do
        late = options_with
        session = connected(late)
        session.write_prompt('before', session_id: '', verbatim: :current)
        late.verbatim_prompts = true
        session.write_prompt('after', session_id: '', verbatim: :current)

        expect(cli.writes.map { |frame| frame[:client_composed] }).to eq([nil, true])
      end

      it 'reads the repointed copy, not the configured options, with verbatim: :current once materialized' do
        created = []
        stub_materialization
        configured = resume_options
        stub_query
        session = assembly(configured, source: { class: EntryPointHarness::FakeCLI.subprocess_class(created), args: {} })
        session.connect
        repointed = created.fetch(0).options

        configured.verbatim_prompts = true
        session.write_prompt('caller flipped', session_id: '', verbatim: :current)
        repointed.verbatim_prompts = true
        session.write_prompt('copy flipped', session_id: '', verbatim: :current)

        expect(repointed).not_to be(configured)
        expect(created.fetch(0).writes.map { |frame| frame[:client_composed] }).to eq([nil, true])
      end

      it 'takes an explicit Boolean over both' do
        session = connected(options_with(verbatim_prompts: true))
        session.write_prompt('unmarked', session_id: '', verbatim: false)
        plain = connected(options_with)
        plain.write_prompt('marked', session_id: '', verbatim: true)

        expect(cli.writes.map { |frame| frame[:client_composed] }).to eq([nil, true])
      end
    end

    describe '#write_message' do
      it 'writes a Hash as one JSON line' do
        connected.write_message(user_message.merge(session_id: 'abc'))

        expect(cli.writes).to eq([user_message.merge(session_id: 'abc')])
        expect(cli.lines).to match([a_string_ending_with("}\n")])
      end

      it 'writes a JSONL String as it is, adding the newline only when it lacks one' do
        line = JSON.generate(user_message)
        session = connected
        session.write_message(line)
        session.write_message("#{line}\n")

        expect(cli.lines).to eq(["#{line}\n", "#{line}\n"])
      end

      it 'stamps with the value captured in #connect' do
        on = options_with(verbatim_prompts: true)
        session = connected(on)
        on.verbatim_prompts = false
        session.write_message(user_message)
        session.write_message(JSON.generate(user_message))

        expect(cli.writes).to all(include(client_composed: true))
      end

      it 'raises for a String it cannot mark, before writing it' do
        session = connected(options_with(verbatim_prompts: true))

        expect { session.write_message('not json') }.to raise_error(ArgumentError, /one JSON object/)
        expect(cli.writes).to be_empty
      end

      it 'notifies no observer' do
        connected.write_message(user_message)

        expect(observer.events).to be_empty
      end
    end
  end

  describe '#stream_prompt_in_background' do
    it 'streams through Query#stream_input on a task the Query tracks, notifying on_user_prompt per user message' do
      session = assembly
      stream = [{ type: 'user', message: { role: 'user', content: 'one' } },
                JSON.generate(type: 'user', message: { role: 'user', content: 'two' })]

      Sync do
        session.connect
        task = session.stream_prompt_in_background(stream.each)
        task.wait

        expect(task).to be_a(Async::Task)
        expect(cli.user_writes.map { |frame| frame.dig(:message, :content) }).to eq(%w[one two])
        expect(cli).to be_input_ended
        expect(observer.payloads(:on_user_prompt)).to eq(%w[one two])
      ensure
        session.close_resources(always_close_transport: true)
      end
    end
  end

  describe '#deliver' do
    let(:assistant) { EntryPointHarness::ASSISTANT_FRAME }
    let(:result) { EntryPointHarness::RESULT_FRAME }
    let(:frames) { [assistant, { type: 'a_frame_from_the_future' }, result, assistant] }

    def delivering(frames, with: dispatch)
      stub_query
      allow(handler).to receive(:receive_messages) do |&block|
        frames.each { |frame| frame.is_a?(Exception) ? raise(frame) : block.call(frame) }
        nil
      end
      assembly(with: with).tap(&:connect)
    end

    it 'parses each frame, notifies on_message, then calls the block, and skips frames that parse to nothing' do
      log = []
      logging = EntryPointHarness::RecordingObserver.new(on_message: ->(message) { log << [:on_message, message.class] })
      session = delivering(frames, with: ClaudeAgentSDK::Dispatch.new([logging], scheduling: :thread, wrapper: nil))

      returned = session.deliver(proc { |message| log << [:block, message.class] })

      expect(log).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage, ClaudeAgentSDK::AssistantMessage]
                          .flat_map { |klass| [[:on_message, klass], [:block, klass]] })
      expect(returned).to be_nil
    end

    it 'notifies the observers its dispatch holds when each message arrives, not the ones it started with' do
      later = EntryPointHarness::RecordingObserver.new
      session = delivering(frames)

      session.deliver(proc { |message| dispatch.observers = [later] if message.is_a?(ClaudeAgentSDK::ResultMessage) })

      expect(observer.payloads(:on_message).map(&:class)).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(later.payloads(:on_message).map(&:class)).to eq([ClaudeAgentSDK::AssistantMessage])
    end

    it 'stops after the ResultMessage with until_result: true' do
      seen = []

      delivering(frames).deliver(proc { |message| seen << message.class }, until_result: true)

      expect(seen).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
    end

    %i[thread inline].each do |scheduling|
      it "returns the value of the block's break and delivers nothing after it (#{scheduling}, with a wrapper)" do
        wrapped = []
        wrapper = lambda do |invocation|
          wrapped << true
          invocation.call
        end
        mode = ClaudeAgentSDK::Dispatch.new([observer], scheduling: scheduling, wrapper: wrapper)
        seen = []
        block = proc do |message|
          seen << message.class
          break :stopped
        end

        returned = Sync { delivering(frames, with: mode).deliver(block) }

        expect(returned).to eq(:stopped)
        expect(seen).to eq([ClaudeAgentSDK::AssistantMessage])
        expect(observer.names).to eq(%i[on_message])
        expect(wrapped.length).to eq(2) # the observer and the block
      end
    end

    it 'prefers the break value over the ResultMessage stop' do
      returned = delivering([result, assistant]).deliver(proc { break :mine }, until_result: true)

      expect(returned).to eq(:mine)
    end

    it 'lets an error of the block propagate, and notifies no on_error' do
      expect { delivering(frames).deliver(proc { raise ArgumentError, 'block boom' }) }
        .to raise_error(ArgumentError, 'block boom')
      expect(observer.names).to eq(%i[on_message])
    end

    it 'lets an error of the stream propagate, and notifies no on_error' do
      crash = ClaudeAgentSDK::ProcessError.new('Command failed', exit_code: 1)
      seen = []

      expect { delivering([assistant, crash]).deliver(proc { |message| seen << message.class }) }.to raise_error(crash)
      expect(seen).to eq([ClaudeAgentSDK::AssistantMessage])
      expect(observer.names).to eq(%i[on_message])
    end
  end

  describe '#close_resources' do
    let(:transport) { instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: nil, close: nil) }
    let(:source) do
      doubled = transport
      { class: Class.new(ClaudeAgentSDK::SubprocessCLITransport) { define_singleton_method(:new) { |_options, **| doubled } },
        args: {} }
    end

    # Connected with a materialized resume.
    def connected
      stub_query
      stub_materialization
      assembly(resume_options, source: source).tap(&:connect)
    end

    # Got as far as a transport whose #connect raised: no Query was built.
    def without_handler
      stub_query
      stub_materialization
      allow(transport).to receive(:connect).and_raise(IOError, 'no route')
      assembly(resume_options, source: source).tap do |session|
        expect { session.connect }.to raise_error(IOError, 'no route')
      end
    end

    it 'does nothing before #connect' do
      session = assembly

      expect { session.close_resources(always_close_transport: true) }.not_to raise_error
      expect(cli.close_calls).to eq(0)
    end

    context 'with always_close_transport: true' do
      it 'closes the Query, then the transport, then removes the materialized dir' do
        session = connected

        session.close_resources(always_close_transport: true)

        expect(handler).to have_received(:close).ordered
        expect(transport).to have_received(:close).ordered
        expect(materialized).to have_received(:cleanup).ordered
        expect(session.query_handler).to be_nil
      end

      it 'still closes the transport and removes the dir when closing the Query raises, then raises that error' do
        session = connected
        allow(handler).to receive(:close).and_raise(IOError, 'reap failed')

        expect { session.close_resources(always_close_transport: true) }.to raise_error(IOError, 'reap failed')
        expect(transport).to have_received(:close)
        expect(materialized).to have_received(:cleanup)
        expect(session.query_handler).to be_nil
      end

      it 'still removes the dir when closing the transport raises, then raises that error' do
        session = connected
        allow(transport).to receive(:close).and_raise(IOError, 'pipe')

        expect { session.close_resources(always_close_transport: true) }.to raise_error(IOError, 'pipe')
        expect(materialized).to have_received(:cleanup)
      end

      it 'raises the later error, the one of the transport, when both closes raise' do
        session = connected
        allow(handler).to receive(:close).and_raise(IOError, 'reap failed')
        allow(transport).to receive(:close).and_raise(ArgumentError, 'pipe')

        expect { session.close_resources(always_close_transport: true) }.to raise_error(ArgumentError, 'pipe')
        expect(materialized).to have_received(:cleanup)
      end

      it 'closes a transport that never got a Query' do
        session = without_handler

        session.close_resources(always_close_transport: true)

        expect(transport).to have_received(:close)
        expect(materialized).to have_received(:cleanup)
      end
    end

    context 'with always_close_transport: false' do
      it 'closes the Query and removes the materialized dir, leaving the transport to the Query' do
        session = connected

        session.close_resources(always_close_transport: false)

        expect(handler).to have_received(:close).ordered
        expect(materialized).to have_received(:cleanup).ordered
        expect(transport).not_to have_received(:close)
        expect(session.query_handler).to be_nil
      end

      it 'does not close the transport when closing the Query raises, removes the dir, then raises that error' do
        session = connected
        allow(handler).to receive(:close).and_raise(IOError, 'reap failed')

        expect { session.close_resources(always_close_transport: false) }.to raise_error(IOError, 'reap failed')
        expect(transport).not_to have_received(:close)
        expect(materialized).to have_received(:cleanup)
      end

      it 'closes a transport that never got a Query' do
        session = without_handler

        session.close_resources(always_close_transport: false)

        expect(transport).to have_received(:close)
        expect(materialized).to have_received(:cleanup)
      end

      it 'still removes the dir when closing that transport raises, then raises that error' do
        session = without_handler
        allow(transport).to receive(:close).and_raise(ArgumentError, 'pipe')

        expect { session.close_resources(always_close_transport: false) }.to raise_error(ArgumentError, 'pipe')
        expect(materialized).to have_received(:cleanup)
      end
    end

    it 'keeps a materialized dir whose removal was cut short, for the next call to remove' do
      session = connected
      attempts = 0
      allow(materialized).to receive(:cleanup) do
        attempts += 1
        raise Async::TimeoutError, 'execution expired' if attempts == 1
      end

      expect { session.close_resources(always_close_transport: true) }.to raise_error(Async::TimeoutError)
      session.close_resources(always_close_transport: true)
      session.close_resources(always_close_transport: true)

      expect(attempts).to eq(2)
      expect(handler).to have_received(:close).once
      expect(transport).to have_received(:close).once
    end

    # The block is where the caller marks itself disconnected: after both
    # closes, before the directory removal, which can take a while.
    describe 'the block it is given' do
      it 'is called once both closes are behind and before the materialized dir is dealt with' do
        steps = []
        session = connected
        allow(handler).to receive(:close) { steps << :query_close }
        allow(transport).to receive(:close) { steps << :transport_close }
        allow(materialized).to receive(:cleanup) { steps << :cleanup }

        session.close_resources(always_close_transport: true) { steps << [:block, session.query_handler] }

        expect(steps).to eq([:query_close, :transport_close, [:block, nil], :cleanup])
      end

      it 'is called when closing the Query raises, and when closing the transport raises' do
        calls = 0
        session = connected
        allow(handler).to receive(:close).and_raise(IOError, 'reap failed')
        allow(transport).to receive(:close).and_raise(ArgumentError, 'pipe')

        expect { session.close_resources(always_close_transport: true) { calls += 1 } }
          .to raise_error(ArgumentError, 'pipe')
        expect(calls).to eq(1)
        expect(materialized).to have_received(:cleanup)
      end

      it 'is called when there is nothing to close and no materialized dir' do
        calls = 0

        assembly.close_resources(always_close_transport: false) { calls += 1 }

        expect(calls).to eq(1)
      end
    end

    # A dropped mirror batch means the store copy is incomplete: the dir
    # holds the only copy of those turns.
    [true, false].each do |always|
      it "preserves the materialized dir when the mirror dropped batches (always_close_transport: #{always})" do
        session = connected
        allow(handler).to receive(:mirror_batches_dropped?).and_return(true)

        session.close_resources(always_close_transport: always)

        expect(handler).to have_received(:close).ordered
        expect(handler).to have_received(:mirror_batches_dropped?).ordered # asked after the final flush
        expect(materialized).to have_received(:preserve_transcripts)
        expect(materialized).not_to have_received(:cleanup)
      end

      it "disposes of everything once: a second call does nothing (always_close_transport: #{always})" do
        session = connected

        2.times { session.close_resources(always_close_transport: always) }

        expect(handler).to have_received(:close).once
        expect(materialized).to have_received(:cleanup).once
      end
    end
  end
end
