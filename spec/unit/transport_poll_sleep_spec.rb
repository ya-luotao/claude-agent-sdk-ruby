# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The transport polls in two places: while it waits for the CLI to exit, and
# while the version probe runs. Both used Async::Task#sleep when a task was
# current — deprecated in favor of the scheduler-aware Kernel#sleep, and a
# warning per call (every 50 ms) under `ruby -w`.
RSpec.describe ClaudeAgentSDK::SubprocessCLITransport, 'polling sleeps' do
  after { described_class.active_processes.clear }

  around do |example|
    Dir.mktmpdir('poll-sleep-spec') do |dir|
      @dir = dir
      example.run
    end
  end

  # What `ruby -w` turns on: verbose mode and the :deprecated category
  # (async tags its warning with it, and $VERBOSE alone does not enable it).
  def with_deprecation_warnings
    verbose = $VERBOSE
    deprecated = Warning[:deprecated]
    $VERBOSE = true
    Warning[:deprecated] = true
    yield
  ensure
    $VERBOSE = verbose
    Warning[:deprecated] = deprecated
  end

  def transport_for(cli_path)
    described_class.new(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: cli_path))
  end

  describe 'waiting for the CLI to exit' do
    let(:transport) { transport_for('/usr/bin/claude') }
    let(:process) { instance_double(Process::Waiter, value: :exited) }

    it 'does not use the deprecated Async::Task#sleep inside a task' do
      allow(process).to receive(:alive?).and_return(true, false)

      expect do
        with_deprecation_warnings { Sync { transport.send(:wait_process_with_timeout, 5, process) } }
      end.not_to output(/Async::Task#sleep/).to_stderr
    end

    # Two polls, whatever happens: a sleep that blocked the thread instead
    # of parking the fiber would finish the wait before the other task ever
    # ran, and the order below would be reversed.
    it 'parks only the waiting fiber: another task on the reactor runs meanwhile' do
      allow(process).to receive(:alive?).and_return(true, true, false)
      events = []

      result = Sync do |task|
        waiter = task.async do
          transport.send(:wait_process_with_timeout, 5, process).tap { events << :wait_returned }
        end
        # Control comes back here when the waiter parks in its first poll.
        events << :other_task_ran
        waiter.wait
      end

      expect(result).to eq(:exited)
      expect(events).to eq(%i[other_task_ran wait_returned])
    end
  end

  describe 'the version probe' do
    around do |example|
      previous = ENV.fetch('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK', nil)
      ENV.delete('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK')
      example.run
    ensure
      ENV['CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'] = previous if previous
    end

    let(:gate_path) { File.join(@dir, 'gate') }

    # `claude -v` that answers only once a line arrives on the gate FIFO, so
    # the probe is still running when the poll loop first goes round.
    let(:gated_cli) do
      File.mkfifo(gate_path)
      path = File.join(@dir, 'claude')
      File.write(path, <<~SH)
        #!/bin/sh
        read go < '#{gate_path}'
        echo '2.1.286 (Claude Code)'
      SH
      File.chmod(0o755, path)
      path
    end

    it 'does not use the deprecated Async::Task#sleep inside a task' do
      # The loop is `until drainer.join(0)`, and under a fiber scheduler
      # Ruby 3.2's Thread#join ignores its timeout: it returns only when the
      # thread has finished, so the loop body — the sleep under test, and
      # with it the gate below — is never reached there.
      skip 'on Ruby 3.2 this poll never sleeps inside a task' if RUBY_VERSION < '3.3'

      transport = transport_for(gated_cli)

      # Opened read-write so neither end blocks in open(2).
      File.open(gate_path, 'r+') do |gate|
        # The poll's own sleep opens the gate: the loop has then run at
        # least once, and the probe finishes right after. A poll that sleeps
        # some other way never opens it and runs into the probe's deadline.
        allow(transport).to receive(:sleep).and_wrap_original do |original, *args|
          gate.syswrite("go\n")
          original.call(*args)
        end

        expect do
          with_deprecation_warnings { Sync { transport.check_claude_version } }
        end.not_to output(/Async::Task#sleep/).to_stderr
        expect(transport).to have_received(:sleep).at_least(:once)
      end
    end
  end
end
