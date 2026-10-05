# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'fileutils'
require 'securerandom'
require 'timeout'
require 'tmpdir'

# What a Client does when a teardown interleaves with its other calls: calls
# made while a disconnect is under way, a disconnect after one that was cut
# short, a receive still running across a disconnect and a reconnect. All of
# it through the public API, with a real Query over an in-memory CLI and a
# really materialized store-backed resume; the only thing stubbed is the
# removal of the materialized directory, to park it or to make it fail.
#
# Client#disconnect closes the query handler and the transport, and then
# removes the materialized resume dir. That removal can take a while (it
# retries, sleeping, when the directory is busy), and the reactor runs other
# tasks meanwhile.
RSpec.describe ClaudeAgentSDK::Client, 'when a teardown interleaves with its other calls' do
  let(:created) { [] }
  let(:cwd) { Dir.mktmpdir('client-interleavings-cwd-') }
  let(:user_config_dir) { Dir.mktmpdir('client-interleavings-config-') } # keeps the developer's own config out of it
  let(:session_id) { SecureRandom.uuid }
  let(:store) do
    ClaudeAgentSDK::InMemorySessionStore.new.tap do |store|
      store.append({ 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id },
                   [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => 'hi' } }])
    end
  end
  let(:observer) { EntryPointHarness::RecordingObserver.new }
  let(:wrapped) { [] }
  let(:wrapper) do
    lambda do |invocation|
      wrapped << true
      invocation.call
    end
  end

  # A regression here tends to be a wait that never ends; fail instead.
  around do |example|
    Timeout.timeout(30) { example.run }
  end

  after do
    [cwd, user_config_dir, *created.map(&:config_dir)].each { |dir| FileUtils.rm_rf(dir) if dir }
  end

  # A client connected with a materialized store-backed resume, and the
  # in-memory CLI it talks to (its config_dir is the materialized directory).
  def connected_client(scheduling)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      session_store: store, resume: session_id, cwd: cwd, env: { 'CLAUDE_CONFIG_DIR' => user_config_dir },
      observers: [observer], callback_scheduling: scheduling, callback_wrapper: wrapper
    )
    client = described_class.new(options: options, transport_class: EntryPointHarness::FakeCLI.subprocess_class(created))
    client.connect
    [client, created.fetch(0)]
  end

  # Every removal of +directory+ goes through the block first, with the
  # number of the attempt; any other removal is left alone.
  def on_removal_of(directory)
    attempts = 0
    allow(FileUtils).to receive(:remove_entry).and_wrap_original do |original, path, *rest|
      yield(attempts += 1) if path == directory
      original.call(path, *rest)
    end
  end

  def not_connected
    raise_error(ClaudeAgentSDK::CLIConnectionError, 'Not connected. Call connect() first')
  end

  %i[thread inline].each do |scheduling|
    context "with callback_scheduling: #{scheduling} and a callback_wrapper" do
      # The handler and the transport are closed by then: the client is no
      # longer connected, and says so, instead of running into the session
      # it has just taken apart.
      describe 'calls made while the materialized resume dir is being removed' do
        it 'are refused as not connected, notify no observer, and a second disconnect does not close again' do
          client, cli = Sync do |task|
            client, cli = connected_client(scheduling)
            entered = Thread::Queue.new
            release = Thread::Queue.new
            on_removal_of(cli.config_dir) do |attempt|
              next unless attempt == 1

              entered << true
              release.pop
            end

            disconnecting = task.async { client.disconnect }
            entered.pop # both closes ran; the first removal is parked

            aggregate_failures do
              expect(cli).to be_closed
              expect(observer.names).to eq(%i[on_close])
              expect { client.query('racing') }.to not_connected
              expect { client.receive_messages { |_message| nil } }.to not_connected
              expect { client.receive_response { |_message| nil } }.to not_connected
              expect { client.interrupt }.to not_connected
              expect { client.disconnect }.not_to raise_error
              expect(observer.names).to eq(%i[on_close]) # nothing was notified, and on_close only once
              expect(cli.user_writes).to be_empty
            end
            [client, cli]
          ensure
            release&.close
            disconnecting&.wait
          end

          expect(File.exist?(cli.config_dir)).to be(false)
          expect(client.query_handler).to be_nil
          expect(wrapped).not_to be_empty
        end
      end

      # The directory holds a copy of the credentials and the settings. A
      # removal that was cut short (the directory was busy, and the caller's
      # deadline expired or its task was stopped during the wait before the
      # retry) must stay within reach of the next disconnect.
      describe 'a disconnect interrupted while it removes the materialized resume dir' do
        {
          'an expired deadline' => Async::TimeoutError,
          'a cancellation that is not a StandardError' => Class.new(ClaudeAgentSDK::FiberBoundary::InlineCancellation)
        }.each do |label, cancellation|
          it "raises the interruption and leaves the dir to the next disconnect, which removes it (#{label})" do
            attempts = []

            Sync do |task|
              client, cli = connected_client(scheduling)
              entered = Thread::Queue.new
              on_removal_of(cli.config_dir) do |attempt|
                attempts << attempt
                next unless attempt == 1

                entered << true
                raise Errno::EBUSY, cli.config_dir # retried after a sleep, which is where the interruption lands
              end

              disconnecting = task.async { expect { client.disconnect }.to raise_error(cancellation) }
              entered.pop
              EntryPointHarness.expire_deadline_on(disconnecting, cancellation)
              disconnecting.wait

              aggregate_failures do
                expect(attempts).to eq([1])
                expect(File.directory?(cli.config_dir)).to be(true)
                expect(cli).to be_closed # the rest of the teardown was done
                expect(client.query_handler).to be_nil
                expect { client.query('again') }.to not_connected

                expect { client.disconnect }.not_to raise_error
                expect(attempts).to eq([1, 2])
                expect(File.exist?(cli.config_dir)).to be(false)

                client.disconnect # nothing is left to do
                expect(attempts).to eq([1, 2])
                expect(observer.names).to eq(%i[on_close])
              end
            end
          end
        end
      end

      # Observers are resolved on each connect, and a receive loop asks the
      # client for them message by message: one that is still running from
      # before a reconnect tells the observers of the connection there is
      # now, not the ones it started with.
      describe 'a receive still running across a disconnect and a reconnect' do
        it 'notifies the observers of the current connection of what it delivers from then on' do
          resolved = []
          factory = -> { EntryPointHarness::RecordingObserver.new.tap { |built| resolved << built } }
          options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [factory], callback_scheduling: scheduling,
                                                           callback_wrapper: wrapper)
          client = described_class.new(options: options,
                                       transport_class: EntryPointHarness::FakeCLI.foreign_class(created, hang_up_after: 1))
          entered = Thread::Queue.new
          release = Thread::Queue.new
          delivered = []

          Sync do |task|
            client.connect
            client.query('first session')
            receiving = task.async do
              client.receive_messages do |message|
                delivered << message.class
                next unless delivered.length == 1

                entered << true
                release.pop # parked in the block, with the result already read
              end
            end
            entered.pop
            client.disconnect
            client.connect
            release << true
            receiving.wait
            client.disconnect
          ensure
            release.close
          end

          expect(delivered).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
          expect(resolved.map(&:names)).to eq([%i[on_user_prompt on_message on_close], %i[on_message on_close]])
          expect(created.map(&:closed?)).to eq([true, true])
        end
      end
    end
  end
end
