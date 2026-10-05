# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'fileutils'
require 'securerandom'
require 'timeout'
require 'tmpdir'

# What other callers of a Client see while one of its teardowns is under way,
# or after one was cut short. All of it through the public API, with a real
# Query over an in-memory CLI and a really materialized store-backed resume;
# the only thing stubbed is the removal of the materialized directory, to
# park it or to make it fail.
#
# Client#disconnect closes the query handler and the transport, and then
# removes the materialized resume dir. That removal can take a while (it
# retries, sleeping, when the directory is busy), and the reactor runs other
# tasks meanwhile.
RSpec.describe ClaudeAgentSDK::Client, 'while a teardown is under way, or after one was cut short' do
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
    end
  end
end
