# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'fileutils'
require 'securerandom'
require 'timeout'
require 'tmpdir'

# What ClaudeAgentSDK.query and ClaudeAgentSDK::Client do around a session:
# the lifecycle differences between the two (L1-L8), what observers are told
# on the failure paths, which error wins, what goes on the wire, when
# verbatim_prompts is read, and what is disposed of after a partial setup.
#
# Everything here goes through the public API, over an in-memory CLI
# (EntryPointHarness::FakeCLI) and a recording observer. It pins behaviour,
# not structure: none of it depends on which object inside the SDK acquires
# the transport, builds the Query or cleans up.
RSpec.describe 'entry point lifecycle' do
  let(:fake_cli) { EntryPointHarness::FakeCLI }
  let(:client_class) { ClaudeAgentSDK::Client }
  let(:created) { [] }
  let(:observer) { EntryPointHarness::RecordingObserver.new }
  let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer]) }

  # A store-backed resume: the session is in the store, not on disk, so the
  # SDK materializes it into a temp CLAUDE_CONFIG_DIR for a CLI it spawns.
  let(:cwd) { Dir.mktmpdir('entry-point-cwd-') }
  let(:user_config_dir) { Dir.mktmpdir('entry-point-config-') } # keeps the developer's own config out of it
  let(:session_id) { SecureRandom.uuid }
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }

  # A regression here tends to be a wait that never ends; fail instead.
  around do |example|
    Timeout.timeout(30) { example.run }
  end

  after do
    [cwd, user_config_dir].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # The transport query() constructs when none is injected, and the class
  # Client constructs by default: a FakeCLI instead of a subprocess.
  def stub_default_transport(**switches)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |transport_options, **kwargs|
      fake_cli.new(transport_options, **switches, **kwargs).tap { |cli| created << cli }
    end
  end

  def run_query(prompt = 'hello', query_options: options, **kwargs)
    messages = []
    ClaudeAgentSDK.query(prompt: prompt, options: query_options, **kwargs) { |message| messages << message }
    messages
  end

  def user_message(content)
    { type: 'user', message: { role: 'user', content: content }, parent_tool_use_id: nil }
  end

  def seed_store
    store.append({ 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id },
                 [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => 'hi' } }])
  end

  def resume_options(**extra)
    ClaudeAgentSDK::ClaudeAgentOptions.new(
      session_store: store, resume: session_id, cwd: cwd, env: { 'CLAUDE_CONFIG_DIR' => user_config_dir },
      observers: [observer], **extra
    )
  end

  def materialized_dir?(dir)
    dir != user_config_dir && File.basename(dir.to_s).start_with?('claude-resume-')
  end

  # What the caller got from the call: :returned, or the exception it raised.
  def outcome_of
    yield
    :returned
  rescue Exception => e # rubocop:disable Lint/RescueException -- a deadline or a cancellation may be a bare Exception
    e
  end

  def expect_not_connected(client)
    expect { client.query('again') }.to raise_error(ClaudeAgentSDK::CLIConnectionError, /Not connected/)
  end

  describe 'L1: query() runs in a reactor of its own' do
    it 'works with no reactor around it and inside one' do
      stub_default_transport

      outside = run_query
      inside = Sync { run_query }

      expected = [ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage]
      expect([outside.map(&:class), inside.map(&:class)]).to eq([expected, expected])
    end

    it 'Client.open brings a reactor of its own as well' do
      stub_default_transport
      seen = []

      client_class.open(options: options) do |client|
        client.query('hello')
        client.receive_response { |message| seen << message.class }
      end

      expect(seen).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(created.fetch(0)).to be_closed
    end
  end

  describe 'L2: a String prompt' do
    it "query() writes one user message with session_id '' and closes stdin when the run is over" do
      cli = fake_cli.new

      run_query('hello', transport: cli)

      expect(cli.user_writes).to eq([user_message('hello').merge(session_id: '')])
      expect(cli.lines.last).to end_with("}\n")
      expect(cli).to be_input_ended
    end

    it "Client#query writes session_id 'default', or the one it is given, and never closes stdin" do
      stub_default_transport

      Sync do
        client = client_class.new(options: options)
        client.connect('first')
        client.query('second')
        client.query('third', session_id: 'abc')
        client.receive_response { |_message| nil }
        cli = created.fetch(0)

        expect(cli.user_writes).to eq([user_message('first').merge(session_id: 'default'),
                                       user_message('second').merge(session_id: 'default'),
                                       user_message('third').merge(session_id: 'abc')])
        expect(cli.lines.last(3)).to all(end_with("}\n"))
        expect(cli).not_to be_input_ended
      ensure
        client&.disconnect
      end
    end
  end

  describe 'L3: an Enumerable prompt' do
    let(:stream) { [user_message('one').merge(session_id: ''), JSON.generate(user_message('two').merge(session_id: ''))] }

    it 'query() streams it in the background and closes stdin once it is exhausted' do
      cli = fake_cli.new

      messages = run_query(stream.each, transport: cli)

      expect(cli.user_writes.map { |frame| frame.dig(:message, :content) }).to eq(%w[one two])
      expect(cli).to be_input_ended
      expect(messages.grep(ClaudeAgentSDK::ResultMessage).length).to eq(2)
      expect(observer.payloads(:on_user_prompt)).to eq(%w[one two])
    end

    it 'Client#connect streams it in the background and closes stdin once it is exhausted' do
      stub_default_transport

      Sync do
        client = client_class.new(options: options)
        client.connect(stream.each)
        client.receive_messages { |_message| nil } # the output ends with stdin
        cli = created.fetch(0)

        expect(cli.user_writes.map { |frame| frame.dig(:message, :content) }).to eq(%w[one two])
        expect(cli).to be_input_ended
        expect(observer.payloads(:on_user_prompt)).to eq(%w[one two])
      ensure
        client&.disconnect
      end
    end

    it 'Client#query streams it inline, stamps the session_id on Hashes that lack one and leaves stdin open' do
      stub_default_transport

      Sync do
        client = client_class.new(options: options)
        client.connect
        client.query([user_message('one'), JSON.generate(user_message('two').merge(session_id: 'kept'))], session_id: 'abc')
        cli = created.fetch(0)

        expect(cli.user_writes.map { |frame| [frame.dig(:message, :content), frame[:session_id]] })
          .to eq([%w[one abc], %w[two kept]])
        expect(cli).not_to be_input_ended
        expect(observer.payloads(:on_user_prompt)).to eq(%w[one two])
      ensure
        client&.disconnect
      end
    end
  end

  describe 'L4: query() is one run' do
    it 'writes the handshake and the prompt, and no other control request' do
      cli = fake_cli.new

      run_query('hello', transport: cli)

      expect(cli.writes.map { |frame| frame.dig(:request, :subtype) || frame[:type] }).to eq(%w[initialize user])
    end
  end

  describe 'L5: ask' do
    def result_frame(turns)
      EntryPointHarness::RESULT_FRAME.merge(num_turns: turns)
    end

    it 'returns the last ResultMessage of the run' do
      cli = fake_cli.new(replies: [EntryPointHarness::ASSISTANT_FRAME, result_frame(1), result_frame(2)])
      seen = []

      result = ClaudeAgentSDK.ask('hello', options: options, transport: cli) { |message| seen << message.class }

      expect(result).to be_a(ClaudeAgentSDK::ResultMessage).and(have_attributes(num_turns: 2))
      expect(seen).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage, ClaudeAgentSDK::ResultMessage])
    end

    it 'raises CLIConnectionError when the run ends without one' do
      cli = fake_cli.new(replies: [EntryPointHarness::ASSISTANT_FRAME])

      expect { ClaudeAgentSDK.ask('hello', options: options, transport: cli) }
        .to raise_error(ClaudeAgentSDK::CLIConnectionError, /without a result message/)
    end
  end

  describe 'L6: an injected transport' do
    it 'is closed by query() when the run is over' do
      cli = fake_cli.new

      run_query('hello', transport: cli)

      expect(cli).to be_closed
    end

    it 'is closed by query() even when its #connect raised' do
      cli = fake_cli.new(connect_error: IOError.new('no route'))

      expect { run_query('hello', transport: cli) }.to raise_error(IOError, 'no route')
      expect(cli).to be_closed
    end
  end

  describe 'L7: query() without a block' do
    it 'returns an Enumerator that runs the query when it is iterated',
       rbs_incompatible: 'the checker samples the returned Enumerator, which runs the query before the example does' do
      cli = fake_cli.new

      enumerator = ClaudeAgentSDK.query(prompt: 'hello', options: options, transport: cli)

      expect(enumerator).to be_an(Enumerator)
      expect(cli.writes).to be_empty
      expect(enumerator.map(&:class)).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
    end

    it 'validates the prompt before it returns', rbs_incompatible: 'passes out-of-signature input to test its rejection' do
      expect { ClaudeAgentSDK.query(prompt: 42) }.to raise_error(ArgumentError, /got Integer/)
    end
  end

  describe 'L8: what observers are told when the session cannot be opened' do
    it 'query() notifies on_error, then on_close, when the transport cannot connect' do
      cli = fake_cli.new(connect_error: IOError.new('no route'))

      expect { run_query('hello', transport: cli) }.to raise_error(IOError, 'no route')
      expect(observer.names).to eq(%i[on_error on_close])
      expect(observer.payloads(:on_error)).to match([have_attributes(class: IOError, message: 'no route')])
    end

    it 'query() notifies on_error, then on_close, when the handshake is rejected' do
      cli = fake_cli.new(reject_initialize: true)

      expect { run_query('hello', transport: cli) }.to raise_error(StandardError, 'Invalid initialize request')
      expect(observer.names).to eq(%i[on_error on_close])
    end

    it 'Client#connect notifies on_error alone when the transport cannot connect' do
      client = client_class.new(options: options,
                                transport_class: fake_cli.foreign_class(created, connect_error: IOError.new('no route')))

      Sync { expect { client.connect }.to raise_error(IOError, 'no route') }
      expect(observer.names).to eq(%i[on_error])
    end

    it 'Client#connect notifies on_error alone when the handshake is rejected' do
      client = client_class.new(options: options, transport_class: fake_cli.foreign_class(created, reject_initialize: true))

      Sync { expect { client.connect }.to raise_error(StandardError, 'Invalid initialize request') }
      expect(observer.names).to eq(%i[on_error])
      expect(created.fetch(0)).to be_closed
    end

    it 'both notify on_close once the session did open' do
      stub_default_transport

      run_query
      Sync do
        client = client_class.new(options: options)
        client.connect
        client.disconnect
      end

      expect(observer.names).to eq(%i[on_user_prompt on_message on_message on_close on_close])
    end
  end

  describe 'which error wins when the cleanup after a failed connect fails too' do
    let(:connect_error) { IOError.new('no route') }
    let(:close_error) { ArgumentError.new('close failed') }

    it 'Client#connect raises the connect error and warns about the cleanup error' do
      transport_class = fake_cli.foreign_class(created, connect_error: connect_error, close_errors: [close_error])
      client = client_class.new(options: options, transport_class: transport_class)

      expect { Sync { expect { client.connect }.to raise_error(connect_error) } }
        .to output(/cleanup after failed connect raised: close failed/).to_stderr
      expect(observer.payloads(:on_error)).to eq([connect_error])
      expect_not_connected(client)
    end

    it 'query() raises the cleanup error' do
      cli = fake_cli.new(connect_error: connect_error, close_errors: [close_error])

      expect { run_query('hello', transport: cli) }.to raise_error(close_error)
      expect(observer.events).to eq([[:on_error, connect_error], [:on_close, nil]])
    end
  end

  describe 'Client#disconnect when closing the query handler raises' do
    it 'still closes the transport, resets the client and removes the materialized resume dir' do
      seed_store
      close_error = IOError.new('reap failed')
      stub_default_transport(close_errors: [close_error]) # the first close is the handler's

      Sync do
        client = client_class.new(options: resume_options)
        client.connect
        cli = created.fetch(0)
        materialized = cli.config_dir

        expect(materialized_dir?(materialized)).to be(true)
        expect { client.disconnect }.to raise_error(close_error)
        expect(cli.close_calls).to eq(2)
        expect(cli).to be_closed
        expect(client.query_handler).to be_nil
        expect_not_connected(client)
        expect(File.exist?(materialized)).to be(false)
      end
    end
  end

  # ClaudeAgentOptions#verbatim_prompts has a public writer, and the two entry
  # points read it at different moments. Client reads it once while it
  # connects: after the transport connected, before the Query is built.
  # query() reads it there too (for the Query, which stamps streamed
  # prompts), and once more for its String prompt, after on_user_prompt.
  describe 'when verbatim_prompts is read' do
    %i[thread inline].each do |scheduling|
      context "with callback_scheduling: #{scheduling} and a callback_wrapper" do
        let(:wrapped) { [] }
        let(:wrapper) do
          lambda do |invocation|
            wrapped << true
            invocation.call
          end
        end
        let(:target) { {} }
        # Turns the option on, on the options the caller passed, as soon as it
        # is told about the prompt.
        let(:flipping_observer) do
          EntryPointHarness::RecordingObserver.new(on_user_prompt: ->(_prompt) { target.fetch(:options).verbatim_prompts = true })
        end
        let(:flip_on_connect) { ->(cli) { cli.options.verbatim_prompts = true } }

        define_method(:mode_options) do |observers: [observer], **extra|
          built = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: observers, callback_scheduling: scheduling,
                                                         callback_wrapper: wrapper, **extra)
          target[:options] = built
        end

        def client_writes(client_options, connect_with: nil)
          Sync do
            client = client_class.new(options: client_options)
            client.connect(connect_with)
            yield client if block_given?
            client.receive_response { |_message| nil }
            created.fetch(0).user_writes
          ensure
            client&.disconnect
          end
        end

        it 'query() marks its String prompt when an observer turns the option on in on_user_prompt' do
          stub_default_transport

          run_query('hello', query_options: mode_options(observers: [flipping_observer]))

          expect(created.fetch(0).user_writes).to match([a_hash_including(client_composed: true)])
          expect(wrapped).not_to be_empty
        end

        it 'Client#query does not mark its String prompt when an observer turns the option on in on_user_prompt' do
          stub_default_transport

          writes = client_writes(mode_options(observers: [flipping_observer])) { |client| client.query('hello') }

          expect(writes.length).to eq(1)
          expect(writes.first).not_to have_key(:client_composed)
          expect(wrapped).not_to be_empty
        end

        it 'both mark their String prompt when the transport turns the option on while it connects' do
          stub_default_transport(on_connect: flip_on_connect)

          run_query('hello', query_options: mode_options)
          writes = client_writes(mode_options) { |client| client.query('hello') }

          expect(created.fetch(0).user_writes).to match([a_hash_including(client_composed: true)])
          expect(writes).to match([a_hash_including(client_composed: true)])
        end

        it 'both mark a streamed prompt when the transport turns the option on while it connects' do
          stub_default_transport(on_connect: flip_on_connect)

          run_query([user_message('one')].each, query_options: mode_options)
          Sync do
            client = client_class.new(options: mode_options)
            client.connect([user_message('one')].each)
            client.receive_messages { |_message| nil }
          ensure
            client&.disconnect
          end

          expect(created.map(&:user_writes)).to all(match([a_hash_including(client_composed: true)]))
        end

        it 'neither marks a streamed prompt when an observer turns the option on in on_user_prompt' do
          stub_default_transport

          run_query([user_message('one')].each, query_options: mode_options(observers: [flipping_observer]))
          Sync do
            client = client_class.new(options: mode_options(observers: [flipping_observer]))
            client.connect([user_message('one')].each)
            client.receive_messages { |_message| nil }
          ensure
            client&.disconnect
          end

          expect(created.flat_map(&:user_writes).length).to eq(2)
          expect(created.flat_map(&:user_writes)).to all(satisfy { |frame| !frame.key?(:client_composed) })
        end

        it 'neither marks its String prompt when the option is turned on after that' do
          stub_default_transport
          query_options = mode_options
          late = EntryPointHarness::RecordingObserver.new(on_message: ->(_message) { query_options.verbatim_prompts = true })
          query_options.observers = [late]

          run_query('hello', query_options: query_options)
          client_options = mode_options
          writes = client_writes(client_options) do |client|
            client_options.verbatim_prompts = true
            client.query('hello')
          end

          expect(query_options.verbatim_prompts).to be(true)
          expect(created.fetch(0).user_writes.first).not_to have_key(:client_composed)
          expect(writes.first).not_to have_key(:client_composed)
        end

        # The session of a materialized store-backed resume runs on a copy of
        # the options (repointed at the temp config dir), so what an observer
        # does to the caller's options no longer reaches it.
        context 'with a store-backed resume' do
          define_method(:mode_resume_options) do |observers: [observer]|
            resume_options(callback_scheduling: scheduling, callback_wrapper: wrapper)
              .tap { |built| built.observers = observers }
              .tap { |built| target[:options] = built }
          end

          it 'query() does not mark its String prompt for an observer that turns the option on, once materialized' do
            seed_store
            stub_default_transport

            run_query('hello', query_options: mode_resume_options(observers: [flipping_observer]))

            cli = created.fetch(0)
            expect(materialized_dir?(cli.config_dir)).to be(true)
            expect(target.fetch(:options).verbatim_prompts).to be(true)
            expect(cli.user_writes.length).to eq(1)
            expect(cli.user_writes.first).not_to have_key(:client_composed)
            expect(wrapped).not_to be_empty
          end

          it 'query() marks it in the same run when nothing was materialized' do
            stub_default_transport # the store has no such session: nothing to materialize

            run_query('hello', query_options: mode_resume_options(observers: [flipping_observer]))

            cli = created.fetch(0)
            expect(cli.config_dir).to eq(user_config_dir)
            expect(cli.user_writes).to match([a_hash_including(client_composed: true)])
          end

          it 'both mark their String prompt when the transport turns the option on, on the options it was given' do
            seed_store
            stub_default_transport(on_connect: flip_on_connect)

            run_query('hello', query_options: mode_resume_options)
            writes = client_writes(mode_resume_options) { |client| client.query('hello') }

            expect(created.map { |cli| materialized_dir?(cli.config_dir) }).to eq([true, true])
            expect(target.fetch(:options).verbatim_prompts).to be(false) # the caller's options were not touched
            expect(created.fetch(0).user_writes).to match([a_hash_including(client_composed: true)])
            expect(writes).to match([a_hash_including(client_composed: true)])
          end
        end
      end
    end
  end

  describe 'a setup that fails part-way' do
    let(:connect_error) { IOError.new('no route') }

    it 'query() closes the transport it constructed when #connect raises' do
      stub_default_transport(connect_error: connect_error)

      expect { run_query }.to raise_error(connect_error)
      expect(created.fetch(0)).to be_closed
    end

    it 'Client#connect closes the transport it constructed when #connect raises, and stays disconnected' do
      stub_default_transport(connect_error: connect_error)
      client = client_class.new(options: options)

      Sync { expect { client.connect }.to raise_error(connect_error) }
      expect(created.fetch(0)).to be_closed
      expect(client.query_handler).to be_nil
      expect_not_connected(client)
    end

    it 'query() removes the materialized resume dir when the transport cannot connect' do
      seed_store
      stub_default_transport(connect_error: connect_error)

      expect { run_query('hello', query_options: resume_options) }.to raise_error(connect_error)
      expect(materialized_dir?(created.fetch(0).config_dir)).to be(true)
      expect(File.exist?(created.fetch(0).config_dir)).to be(false)
    end

    it 'Client#connect removes the materialized resume dir when the transport cannot connect' do
      seed_store
      stub_default_transport(connect_error: connect_error)
      client = client_class.new(options: resume_options)

      Sync { expect { client.connect }.to raise_error(connect_error) }
      expect(materialized_dir?(created.fetch(0).config_dir)).to be(true)
      expect(File.exist?(created.fetch(0).config_dir)).to be(false)
    end

    context 'when repointing the options at the materialized dir raises' do
      let(:materialized_dirs) { [] }

      before do
        seed_store
        stub_default_transport
        allow(ClaudeAgentSDK::SessionResume).to receive(:apply_materialized_options) do |_options, materialized|
          materialized_dirs << materialized.config_dir
          raise ArgumentError, 'cannot repoint'
        end
      end

      it 'query() removes the dir and constructs no transport' do
        expect { run_query('hello', query_options: resume_options) }.to raise_error(ArgumentError, 'cannot repoint')
        expect(materialized_dirs.length).to eq(1)
        expect(File.exist?(materialized_dirs.first)).to be(false)
        expect(created).to be_empty
        expect(observer.names).to eq(%i[on_error on_close])
      end

      it 'Client#connect removes the dir and constructs no transport' do
        client = client_class.new(options: resume_options)

        Sync { expect { client.connect }.to raise_error(ArgumentError, 'cannot repoint') }
        expect(materialized_dirs.length).to eq(1)
        expect(File.exist?(materialized_dirs.first)).to be(false)
        expect(created).to be_empty
        expect(observer.names).to eq(%i[on_error])
      end
    end
  end

  describe 'which transports get a materialized store-backed resume' do
    before { seed_store }

    it 'the transport query() constructs: materialized, repointed, and removed afterwards' do
      stub_default_transport
      query_options = resume_options

      run_query('hello', query_options: query_options)

      cli = created.fetch(0)
      expect(materialized_dir?(cli.config_dir)).to be(true)
      expect(cli.options.resume).to eq(session_id)
      expect(File.exist?(cli.config_dir)).to be(false)
      expect(query_options.env).to eq('CLAUDE_CONFIG_DIR' => user_config_dir) # the caller's options are left alone
    end

    it 'a SubprocessCLITransport (sub)class Client constructs: materialized, repointed, and removed on disconnect' do
      client_options = resume_options
      client = client_class.new(options: client_options, transport_class: fake_cli.subprocess_class(created))

      Sync do
        client.connect
        cli = created.fetch(0)

        expect(materialized_dir?(cli.config_dir)).to be(true)
        expect(cli.options.resume).to eq(session_id)
        expect(File.directory?(cli.config_dir)).to be(true)
        client.disconnect
        expect(File.exist?(cli.config_dir)).to be(false)
        expect(client_options.env).to eq('CLAUDE_CONFIG_DIR' => user_config_dir)
      end
    end

    it 'any other transport class Client constructs: not materialized, options handed over as they are' do
      client_options = resume_options
      client = client_class.new(options: client_options, transport_class: fake_cli.foreign_class(created))

      Sync do
        client.connect
        expect(created.fetch(0).options).to be(client_options)
        expect(created.fetch(0).config_dir).to eq(user_config_dir)
      ensure
        client.disconnect
      end
    end

    it 'a transport injected into query(): not materialized' do
      cli = fake_cli.new

      expect(ClaudeAgentSDK::SessionResume).not_to receive(:materialize_resume_session)
      run_query('hello', query_options: resume_options, transport: cli)
    end

    # Async::Stop (reactor cancellation) is an Exception, not a StandardError.
    it 'Client#connect removes the materialized dir when the transport #connect is cancelled, without notifying on_error' do
      cancellation = Class.new(Exception) # rubocop:disable Lint/InheritException -- what a cancellation looks like
      client = client_class.new(options: resume_options,
                                transport_class: fake_cli.subprocess_class(created, connect_error: cancellation.new))

      Sync { expect { client.connect }.to raise_error(cancellation) }
      expect(materialized_dir?(created.fetch(0).config_dir)).to be(true)
      expect(File.exist?(created.fetch(0).config_dir)).to be(false)
      expect(created.fetch(0)).to be_closed
      expect(observer.names).to be_empty
      expect_not_connected(client)
    end

    # ClaudeAgentOptions fills env and load_timeout_ms with their defaults in
    # the constructor only; set back to nil, they read as those defaults.
    it 'Client#connect materializes with env and load_timeout_ms set back to nil' do
      previous = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
      ENV['CLAUDE_CONFIG_DIR'] = user_config_dir
      cleared = resume_options.dup_with(env: nil, load_timeout_ms: nil)
      client = client_class.new(options: cleared, transport_class: fake_cli.subprocess_class(created))

      Sync do
        client.connect
        cli = created.fetch(0)

        expect(materialized_dir?(cli.config_dir)).to be(true)
        expect(cli.options.env).to eq('CLAUDE_CONFIG_DIR' => cli.config_dir)
        expect(cli.options.resume).to eq(session_id)
        expect(cleared.env).to be_nil
      ensure
        client.disconnect
      end
    ensure
      previous.nil? ? ENV.delete('CLAUDE_CONFIG_DIR') : (ENV['CLAUDE_CONFIG_DIR'] = previous)
    end
  end

  # A dropped mirror batch means the store copy is incomplete and the
  # materialized temp dir holds the only copy of those turns: it is kept
  # (scrubbed of credentials) instead of deleted.
  describe 'Client#disconnect and the materialized resume dir' do
    let(:materialized) do
      instance_double(ClaudeAgentSDK::MaterializedResume, cleanup: nil, preserve_transcripts: nil,
                                                          config_dir: '/nonexistent/claude-resume-x',
                                                          resume_session_id: session_id)
    end

    def disconnect_after_connecting(dropped:)
      handler = instance_double(ClaudeAgentSDK::Query, start: nil, initialize_protocol: nil, close: nil,
                                                       set_transcript_mirror_batcher: nil,
                                                       mirror_batches_dropped?: dropped)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(handler)
      allow(ClaudeAgentSDK::SessionResume).to receive(:materialize_resume_session).and_return(materialized)
      stub_default_transport
      client = client_class.new(options: resume_options)
      client.connect
      client.disconnect
      handler
    end

    it 'preserves it when the mirror dropped batches' do
      handler = disconnect_after_connecting(dropped: true)

      expect(handler).to have_received(:close).ordered
      expect(materialized).to have_received(:preserve_transcripts).ordered
      expect(materialized).not_to have_received(:cleanup)
      expect(created.fetch(0).config_dir).to eq('/nonexistent/claude-resume-x')
    end

    it 'removes it when none were dropped' do
      disconnect_after_connecting(dropped: false)

      expect(materialized).to have_received(:cleanup)
      expect(materialized).not_to have_received(:preserve_transcripts)
    end
  end

  describe 'Client: connecting again after a disconnect' do
    it 'opens a new session on a new transport, with observers resolved again' do
      stub_default_transport
      resolved = []
      factory = -> { EntryPointHarness::RecordingObserver.new.tap { |built| resolved << built } }
      client = client_class.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [factory]))

      Sync do
        2.times do |round|
          client.connect
          client.query("round #{round}")
          client.receive_response { |_message| nil }
          client.disconnect
          expect(client.query_handler).to be_nil
        end
      end

      expect(created.map { |cli| cli.user_writes.map { |frame| frame.dig(:message, :content) } })
        .to eq([['round 0'], ['round 1']])
      expect(created).to all(be_closed)
      expect(resolved.map(&:names)).to eq([%i[on_user_prompt on_message on_message on_close]] * 2)
    end

    it 'does nothing when it is already connected' do
      stub_default_transport

      Sync do
        client = client_class.new(options: options)
        client.connect
        handler = client.query_handler
        client.connect

        expect(created.length).to eq(1)
        expect(client.query_handler).to be(handler)
      ensure
        client&.disconnect
      end
    end
  end

  describe 'Client#disconnect from inside a callback' do
    %i[thread inline].each do |scheduling|
      it "from the message block ends the session; what was already read is delivered, then the iteration ends (#{scheduling})" do
        stub_default_transport
        client = client_class.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer],
                                                                                  callback_scheduling: scheduling))
        seen = []

        Sync do
          client.connect
          client.query('hello')
          client.receive_messages do |message|
            seen << [message.class, client.query_handler.nil?]
            client.disconnect if seen.length == 1
          end
        end

        expect(seen).to eq([[ClaudeAgentSDK::AssistantMessage, false], [ClaudeAgentSDK::ResultMessage, true]])
        expect(created.fetch(0)).to be_closed
        expect(client.query_handler).to be_nil
        expect_not_connected(client)
        expect(observer.names).to eq(%i[on_user_prompt on_message on_close on_message])
      end
    end

    def permission_request
      { type: 'control_request', request_id: 'req_close_probe',
        request: { subtype: 'can_use_tool', tool_name: 'Bash', input: { command: 'true' } } }
    end

    # What the callback saw the moment its disconnect returned or raised.
    def teardown_seen_by(client, cli, handler, raised)
      { raised: raised, transport_closed: cli.closed?, read_loop_ended: cli.read_loop_ended?,
        handler_was_set: !handler.nil?, handler_now: client.query_handler }
    end

    def disconnecting_can_use_tool(seen, done, client_ref)
      lambda do |_tool, _input, _context|
        client = client_ref.fetch(:client)
        handler = client.query_handler
        begin
          client.disconnect
          seen.merge!(teardown_seen_by(client, created.fetch(0), handler, nil))
        rescue Exception => e # rubocop:disable Lint/RescueException -- Async::Stop is not a StandardError
          seen.merge!(teardown_seen_by(client, created.fetch(0), handler, e))
        ensure
          done << true
        end
        ClaudeAgentSDK::PermissionResultAllow.new
      end
    end

    def run_permission_disconnect(scheduling)
      seen = {}
      done = Thread::Queue.new
      client_ref = {}
      client_options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        callback_scheduling: scheduling, can_use_tool: disconnecting_can_use_tool(seen, done, client_ref)
      )
      client = client_ref[:client] = client_class.new(options: client_options,
                                                      transport_class: fake_cli.foreign_class(created))
      Async do
        client.connect
        created.fetch(0).inject(permission_request)
      end.wait # ends only once the read loop and the callback's task are done
      expect(done.pop(timeout: 5)).to be(true), 'the permission callback did not finish'
      [client, seen]
    end

    it 'from can_use_tool returns to the callback with the teardown complete (:thread)' do
      client, seen = run_permission_disconnect(:thread)

      expect(seen).to eq(raised: nil, transport_closed: true, read_loop_ended: true, handler_was_set: true,
                         handler_now: nil)
      expect(client.query_handler).to be_nil
      expect_not_connected(client)
    end

    it 'from can_use_tool completes the teardown, then unwinds the callback with Async::Stop (:inline)' do
      client, seen = run_permission_disconnect(:inline)

      expect(seen).to match(raised: an_instance_of(Async::Stop), transport_closed: true, read_loop_ended: true,
                            handler_was_set: true, handler_now: nil)
      expect(client.query_handler).to be_nil
      expect_not_connected(client)
    end

    it 'from a parked streaming-input enumerator completes the teardown before the stream unwinds' do
      seen = {}
      done = Thread::Queue.new
      gate = Thread::Queue.new
      client = client_class.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new,
                                transport_class: fake_cli.foreign_class(created))
      stream = Enumerator.new do |yielder|
        yielder << user_message('hi').merge(session_id: 'default')
        gate.pop # parks the stream's task; connect returns
        handler = client.query_handler
        begin
          client.disconnect
          seen.merge!(teardown_seen_by(client, created.fetch(0), handler, nil))
        rescue Exception => e # rubocop:disable Lint/RescueException -- Async::Stop is not a StandardError
          seen.merge!(teardown_seen_by(client, created.fetch(0), handler, e))
        ensure
          done << true
        end
        yielder << user_message('never sent').merge(session_id: 'default')
      end

      Async do
        client.connect(stream)
        gate << true
      end.wait # ends only once the read loop and the stream's task are done
      expect(done.pop(timeout: 5)).to be(true), 'the stream never reached disconnect'

      expect(seen).to match(raised: an_instance_of(Async::Stop), transport_closed: true, read_loop_ended: true,
                            handler_was_set: true, handler_now: nil)
      expect(created.fetch(0).user_writes.map { |frame| frame.dig(:message, :content) }).to eq(['hi'])
      expect_not_connected(client)
    end
  end

  # on_error is notified per failing operation, not once per session: a
  # Client#query whose write fails inside a receive_messages block is notified
  # by #query, and again by the #receive_messages it then unwinds.
  describe 'Client: an error raised by #query inside a #receive_messages block' do
    it 'notifies on_error twice, with the same error' do
      write_error = ClaudeAgentSDK::CLIConnectionError.new('stdin is gone')
      fail_second = ->(frame, cli) { raise write_error if frame[:type] == 'user' && cli.user_writes.length == 1 }
      stub_default_transport(on_write: fail_second)

      Sync do
        client = client_class.new(options: options)
        client.connect
        client.query('hello')

        expect { client.receive_messages { |_message| client.query('again') } }.to raise_error(write_error)
        expect(observer.payloads(:on_error)).to eq([write_error, write_error])
      ensure
        client&.disconnect
      end
    end
  end

  # A failing Client#connect notifies on_error BEFORE it tears the partial
  # session down. A deadline of the caller's that expires while the observer
  # runs must not skip the teardown. What reaches the caller differs by
  # scheduling: with :thread the caller's fiber waits for the observer's
  # thread, and the expiry propagates; with :inline the observer runs on the
  # caller's fiber, so an ordinary expiry lands inside the observer and is
  # contained with the observer's own failures, and only a cancellation that
  # is not a StandardError gets through.
  #
  # The observer signals that it is running with the handshake rejection, and
  # only then is the deadline delivered: slow setup cannot use it up.
  describe 'a failing Client#connect when the caller is interrupted during on_error' do
    let(:entered) { Thread::Queue.new }
    let(:release) { Thread::Queue.new }
    let(:blocking_observer) do
      EntryPointHarness::RecordingObserver.new(
        on_error: lambda do |error|
          next unless error.message.include?('Invalid initialize request')

          entered << true
          release.pop
        end
      )
    end

    after { release.close }

    def failing_client(scheduling)
      seed_store
      client_options = resume_options(callback_scheduling: scheduling)
      client_options.observers = [blocking_observer]
      client_class.new(options: client_options, transport_class: fake_cli.subprocess_class(created, reject_initialize: true))
    end

    # Runs connect on a task of its own and delivers the deadline to it once
    # on_error is running. Returns what connect did.
    def interrupted_connect(client, exception_class)
      Sync do |task|
        outcome = nil
        caller_task = task.async { outcome = outcome_of { client.connect } }
        entered.pop
        EntryPointHarness.expire_deadline_on(caller_task, exception_class)
        caller_task.wait
        outcome
      ensure
        release.close
      end
    end

    # The gate of every example here: on_error ran, with the handshake rejection.
    def expect_on_error_reached
      expect(blocking_observer.events).to match([[:on_error, have_attributes(class: StandardError,
                                                                             message: 'Invalid initialize request')]])
    end

    def expect_torn_down(client)
      cli = created.fetch(0)
      aggregate_failures do
        expect(cli).to be_closed
        expect(cli).to be_read_loop_ended
        expect(materialized_dir?(cli.config_dir)).to be(true)
        expect(File.exist?(cli.config_dir)).to be(false)
        expect(client.query_handler).to be_nil
        expect_not_connected(client)
      end
    end

    it 'tears the partial session down, then raises the expired deadline (:thread)' do
      client = failing_client(:thread)

      outcome = interrupted_connect(client, Async::TimeoutError)

      expect_on_error_reached
      expect(outcome).to be_a(Async::TimeoutError)
      expect_torn_down(client)
    end

    it 'tears the partial session down, then raises an inline cooperative cancellation (:inline)' do
      client = failing_client(:inline)
      cancellation = Class.new(ClaudeAgentSDK::FiberBoundary::InlineCancellation)

      outcome = interrupted_connect(client, cancellation)

      expect_on_error_reached
      expect(outcome).to be_a(cancellation)
      expect_torn_down(client)
    end

    it 'tears the partial session down and raises the connect error while the observer contains the deadline ' \
       '(:inline, residue)' do
      client = failing_client(:inline)

      outcome = interrupted_connect(client, Async::TimeoutError)

      expect_on_error_reached
      expect(outcome).to be_a(StandardError).and(have_attributes(message: 'Invalid initialize request'))
      expect_torn_down(client)
    end
  end
end
