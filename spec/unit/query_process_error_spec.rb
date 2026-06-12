# frozen_string_literal: true

require 'spec_helper'
require 'async'

# The CLI exits non-zero on purpose after emitting a result with
# is_error=true (for shell-script consumers), so the trailing ProcessError
# is rewritten with the structured error text the CLI already reported —
# but only when it directly follows that error result. Any other crash must
# surface raw, and a crash must unblock pending control requests instead of
# leaving them to the 1200s control-request timeout.
RSpec.describe ClaudeAgentSDK::Query, 'ProcessError handling' do
  def transport_yielding(*messages, error:)
    mock_transport.tap do |transport|
      allow(transport).to receive(:read_messages) do |&block|
        messages.each { |m| block.call(m) }
        raise error
      end
    end
  end

  def error_result
    { type: 'result', subtype: 'error_during_execution', is_error: true, errors: ['boom'] }
  end

  def process_error(exit_code, stderr: '')
    ClaudeAgentSDK::ProcessError.new(
      "Command failed with exit code #{exit_code}", exit_code: exit_code, stderr: stderr
    )
  end

  def drain_until_error(query)
    query.receive_messages { |_message| nil }
  end

  it 'rewrites a ProcessError directly following an is_error result with the structured error text' do
    transport = transport_yielding(error_result, error: process_error(1, stderr: 'tail'))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(ClaudeAgentSDK::ProcessError) do |e|
        expect(e.message).to include('Claude Code returned an error result: boom')
        expect(e.exit_code).to eq(1)
        expect(e.stderr).to eq('tail')
      end
    end.wait
  end

  it 'raises the raw ProcessError when the crash follows a successful result' do
    transport = transport_yielding(sample_result_message, error: process_error(139))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(ClaudeAgentSDK::ProcessError, /exit code 139/)
    end.wait
  end

  it 'stops rewriting once the conversation moves past the error result' do
    transport = transport_yielding(error_result, sample_assistant_message, error: process_error(1))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(ClaudeAgentSDK::ProcessError) do |e|
        expect(e.message).to include('Command failed with exit code 1')
        expect(e.message).not_to include('returned an error result')
      end
    end.wait
  end

  it 'keeps the rewrite across the post-turn session_state_changed marker' do
    state_changed = { type: 'system', subtype: 'session_state_changed' }
    transport = transport_yielding(error_result, state_changed, error: process_error(1))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(
        ClaudeAgentSDK::ProcessError, /returned an error result: boom/
      )
    end.wait
  end

  describe 'pending control requests' do
    around do |example|
      previous = ENV.fetch('CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS', nil)
      ENV['CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS'] = '2'
      example.run
    ensure
      if previous
        ENV['CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS'] = previous
      else
        ENV.delete('CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS')
      end
    end

    it 'fails a pending control request promptly when the process dies after the first result' do
      # Sequencing is load-bearing: the transport delivers a successful result
      # first (the historic suppression path triggered only after it), then
      # read_messages parks on a fiber-yielding dequeue until #write observes
      # the interrupt on the wire, and only then raises. Raising any earlier
      # would signal the pending-conditions loop before interrupt registers
      # its condition and the spec would pass without the fix.
      interrupt_on_wire = Async::Queue.new
      result = sample_result_message

      transport = mock_transport
      allow(transport).to receive(:write) do |data|
        msg = JSON.parse(data, symbolize_names: true)
        interrupt_on_wire.enqueue(true) if msg[:type] == 'control_request' && msg.dig(:request, :subtype) == 'interrupt'
      end
      allow(transport).to receive(:read_messages) do |&block|
        block.call(result)
        interrupt_on_wire.dequeue
        raise process_error(137)
      end

      query = described_class.new(transport: transport, is_streaming_mode: true)

      failure = nil
      Async do
        query.start
        begin
          query.interrupt
        rescue StandardError => e
          failure = e
        end
      end.wait

      expect(failure).to be_a(ClaudeAgentSDK::ProcessError),
                         "expected fast ProcessError, got: #{failure.inspect}"
      expect(failure.exit_code).to eq(137)
    end
  end
end
