# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'fileutils'
require 'securerandom'
require 'tmpdir'

# Client#disconnect notifies on_close, and a failing Client#connect notifies
# on_error, BEFORE they tear the session down. Whatever is raised into the
# caller's fiber while it waits for that observer must not skip the teardown:
# the transport is closed, the read loop ends and the materialized resume dir
# (it holds a credentials copy) is removed, and only then does the exception
# reach the caller.
#
# What reaches the caller differs by scheduling. With the default :thread
# scheduling a task.with_timeout expiry propagates. With :inline the observer
# runs on the caller's fiber, so that same expiry lands inside the observer and
# is contained with the observer's own failures (a known residue). What does
# get through under :inline is a cancellation that is not a StandardError:
# FiberBoundary's cooperative timeouts (an inline hook's timeout) and
# Async::Stop.
#
# The observers block on a queue until the example releases them, so the
# deadlines can only expire while they wait. disconnect reaches its observer
# without suspending, so a task.with_timeout around it is enough. connect
# suspends before it reaches on_error (resume materialization, the handshake),
# and a timeout around all of it could be used up by slow setup; so there the
# deadline is delivered once the observer has signalled that it is running
# with the handshake rejection, the way an expired task.with_timeout delivers
# it (EntryPointHarness.expire_deadline_on).
RSpec.describe ClaudeAgentSDK::Client, 'teardown when the caller is interrupted during an observer' do
  # In-memory stand-in for the CLI process. It answers `initialize` the way
  # CLI 2.1.286 answers control requests (payload trimmed), or rejects it
  # with the error frame shape the CLI uses for a refused request.
  let(:fake_cli_class) do
    Class.new do
      attr_reader :config_dir

      def initialize(options, reject_initialize: false)
        @config_dir = options.env['CLAUDE_CONFIG_DIR'] # the materialized resume dir
        @reject_initialize = reject_initialize
        @stdout = Thread::Queue.new
        @closed = false
        @read_loop_ended = false
      end

      def connect; end

      def ready?
        !@closed
      end

      def end_input; end

      def closed?
        @closed
      end

      def read_loop_ended?
        @read_loop_ended
      end

      def inspect
        "#<fake CLI closed=#{@closed} read_loop_ended=#{@read_loop_ended}>"
      end

      def close
        @closed = true
        @stdout << :eof
      end

      def write(line)
        frame = JSON.parse(line, symbolize_names: true)
        return unless frame[:type] == 'control_request' && frame.dig(:request, :subtype) == 'initialize'

        @stdout << { type: 'control_response', response: initialize_response(frame[:request_id]) }
      end

      def read_messages
        while (frame = @stdout.pop) != :eof
          yield frame
        end
      ensure
        @read_loop_ended = true
      end

      private

      def initialize_response(request_id)
        if @reject_initialize
          { subtype: 'error', request_id: request_id, error: 'Invalid initialize request' }
        else
          { subtype: 'success', request_id: request_id,
            response: { commands: [], agents: [], output_style: 'default', models: [], pid: 4242,
                        session_state: 'idle', capabilities: [] },
            pending_permission_requests: [], pending_user_dialog_requests: [] }
        end
      end
    end
  end

  let(:cwd) { Dir.mktmpdir('client-teardown-cwd-') }
  let(:user_config_dir) { Dir.mktmpdir('client-teardown-config-') } # keeps the host's Keychain out of it
  let(:session_id) { SecureRandom.uuid }
  let(:store) do
    ClaudeAgentSDK::InMemorySessionStore.new.tap do |store|
      store.append({ 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id },
                   [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => 'hi' } }])
    end
  end
  let(:release) { Thread::Queue.new }
  let(:entered) { Thread::Queue.new }
  let(:handed) { [] }

  after do
    release.close
    FileUtils.remove_entry(cwd) if File.directory?(cwd)
    FileUtils.remove_entry(user_config_dir) if File.directory?(user_config_dir)
  end

  # Client materializes a store-backed resume only for SubprocessCLITransport
  # and its subclasses, so the class it is given is one; its .new hands back
  # the in-memory stand-in. No subprocess is spawned.
  def transport_class(created)
    fake = fake_cli_class
    Class.new(ClaudeAgentSDK::SubprocessCLITransport) do
      define_singleton_method(:new) { |options, **kwargs| fake.new(options, **kwargs).tap { |cli| created << cli } }
    end
  end

  # An observer that stays in +hook+ until the example releases it. on_error
  # waits only for the handshake rejection: handed anything else it returns
  # at once, and the example's gate (#expect_on_error_reached) fails.
  def blocking_observer(hook)
    queues = { entered: entered, release: release, handed: handed }
    Class.new do
      include ClaudeAgentSDK::Observer

      define_method(hook) do |*args|
        queues[:handed] << (args.first || :called)
        next if hook == :on_error && !args.first.message.include?('Invalid initialize request')

        queues[:entered] << true
        queues[:release].pop
      end
    end.new
  end

  def client_for(hook, scheduling:, reject_initialize: false)
    created = []
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      session_store: store, resume: session_id, cwd: cwd, env: { 'CLAUDE_CONFIG_DIR' => user_config_dir },
      observers: [blocking_observer(hook)], callback_scheduling: scheduling
    )
    client = described_class.new(options: options, transport_class: transport_class(created),
                                 transport_args: { reject_initialize: reject_initialize })
    [client, created]
  end

  # What the caller got from the call: :returned, or the exception it raised.
  def outcome_of
    yield
    :returned
  rescue Exception => e # rubocop:disable Lint/RescueException -- the deadline may be a bare Exception
    e
  end

  def expect_torn_down(client, cli)
    aggregate_failures do
      expect(cli).to be_closed
      expect(cli).to be_read_loop_ended
      expect(File.exist?(cli.config_dir)).to be(false) # the materialized resume dir is gone
      expect { client.query('again') }.to raise_error(ClaudeAgentSDK::CLIConnectionError, /Not connected/)
    end
  end

  # The cooperative-timeout class FiberBoundary uses for inline callbacks.
  def inline_cancellation
    Class.new(ClaudeAgentSDK::FiberBoundary::InlineCancellation)
  end

  describe 'Client#disconnect while on_close runs' do
    def connected_client(scheduling)
      client, created = client_for(:on_close, scheduling: scheduling)
      client.connect
      [client, created.fetch(0)]
    end

    it 'tears the session down, then raises the expired deadline (:thread)' do
      Sync do |task|
        client, cli = connected_client(:thread)
        outcome = outcome_of { task.with_timeout(0.05) { client.disconnect } }

        expect(outcome).to be_a(Async::TimeoutError)
        expect_torn_down(client, cli)
      ensure
        release.close
        client&.disconnect
      end
    end

    it 'tears the session down, then raises an inline cooperative cancellation (:inline)' do
      Sync do |task|
        client, cli = connected_client(:inline)
        cancellation = inline_cancellation
        outcome = outcome_of { task.with_timeout(0.05, cancellation) { client.disconnect } }

        expect(outcome).to be_a(cancellation)
        expect_torn_down(client, cli)
      ensure
        release.close
        client&.disconnect
      end
    end

    it 'tears the session down when the caller task is stopped (:thread)' do
      Sync do |task|
        client, cli = connected_client(:thread)
        caller_task = task.async { client.disconnect }
        entered.pop # on_close is running
        caller_task.stop
        caller_task.wait

        expect_torn_down(client, cli)
      ensure
        release.close
        client&.disconnect
      end
    end

    it 'tears the session down while the observer contains a deadline it ran into (:inline, residue)' do
      Sync do |task|
        client, cli = connected_client(:inline)
        outcome = outcome_of { task.with_timeout(0.05) { client.disconnect } }

        expect(outcome).to eq(:returned) # the expiry landed inside the observer, which contains it
        expect_torn_down(client, cli)
      ensure
        release.close
        client&.disconnect
      end
    end
  end

  describe 'a failing Client#connect while on_error runs' do
    # Runs connect on a task of its own and expires the caller's deadline on
    # it once on_error is running with the handshake rejection (the observer
    # signals it; handed anything else it never does, and this fails). Returns
    # what connect did.
    def connect_interrupted_during_on_error(task, client, exception_class = Async::TimeoutError)
      outcome = nil
      caller_task = task.async { outcome = outcome_of { client.connect } }
      raise 'on_error was never entered with the handshake rejection' unless entered.pop(timeout: 5)

      EntryPointHarness.expire_deadline_on(caller_task, exception_class)
      caller_task.wait
      outcome
    end

    # The gate of every example here: on_error ran, with the handshake rejection.
    def expect_on_error_reached
      expect(handed).to match([have_attributes(class: StandardError, message: 'Invalid initialize request')])
    end

    it 'tears the partial session down, then raises the expired deadline (:thread)' do
      Sync do |task|
        client, created = client_for(:on_error, scheduling: :thread, reject_initialize: true)
        outcome = connect_interrupted_during_on_error(task, client)

        expect_on_error_reached
        expect(outcome).to be_a(Async::TimeoutError)
        expect_torn_down(client, created.fetch(0))
      ensure
        release.close
        client&.disconnect
      end
    end

    it 'tears the partial session down, then raises an inline cooperative cancellation (:inline)' do
      Sync do |task|
        client, created = client_for(:on_error, scheduling: :inline, reject_initialize: true)
        cancellation = inline_cancellation
        outcome = connect_interrupted_during_on_error(task, client, cancellation)

        expect_on_error_reached
        expect(outcome).to be_a(cancellation)
        expect_torn_down(client, created.fetch(0))
      ensure
        release.close
        client&.disconnect
      end
    end

    it 'tears the partial session down when the caller task is stopped (:thread)' do
      Sync do |task|
        client, created = client_for(:on_error, scheduling: :thread, reject_initialize: true)
        caller_task = task.async { client.connect }
        entered.pop # on_error is running with the handshake rejection
        caller_task.stop
        caller_task.wait

        expect_on_error_reached
        expect_torn_down(client, created.fetch(0))
      ensure
        release.close
        client&.disconnect
      end
    end

    it 'tears the partial session down and raises the connect error while the observer contains a deadline ' \
       '(:inline, residue)' do
      Sync do |task|
        client, created = client_for(:on_error, scheduling: :inline, reject_initialize: true)
        outcome = connect_interrupted_during_on_error(task, client)

        expect_on_error_reached
        expect(outcome).to be_a(StandardError).and(have_attributes(message: 'Invalid initialize request'))
        expect_torn_down(client, created.fetch(0))
      ensure
        release.close
        client&.disconnect
      end
    end
  end
end
