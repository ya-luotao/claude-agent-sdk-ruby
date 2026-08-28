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

  # The replacement is a typed ResultError (a ProcessError subclass), so
  # callers can branch on the payload instead of matching the message text.
  it 'raises a ResultError carrying the result payload and the replaced exit error' do
    payload = error_result
    transport = transport_yielding(payload, error: process_error(1, stderr: 'tail'))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(ClaudeAgentSDK::ResultError) do |e|
        expect(e).to be_a(ClaudeAgentSDK::ProcessError)
        expect(e.subtype).to eq('error_during_execution')
        expect(e.errors).to eq(['boom'])
        expect(e.data).to equal(payload)
        expect(e.exit_code).to eq(1)
        expect(e.original_error).to be_a(ClaudeAgentSDK::ProcessError)
        expect(e.original_error.message).to include('Command failed with exit code 1')
      end
    end.wait
  end

  # A run that ends on an API failure arrives as subtype "success",
  # is_error=true, errors=[] with the prose in `result`. Falling back to the
  # subtype printed the self-contradictory "error result: success".
  it 'prefers the result prose over a "success" subtype for API failures' do
    api_failure = {
      type: 'result', subtype: 'success', is_error: true, errors: [],
      result: 'API Error: Stream idle timeout - no chunks received',
      api_error_status: nil, terminal_reason: 'api_error', session_id: 's-1'
    }
    transport = transport_yielding(api_failure, error: process_error(1))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(ClaudeAgentSDK::ResultError) do |e|
        expect(e.message).to include(
          'Claude Code returned an error result: API Error: Stream idle timeout - no chunks received'
        )
        expect(e.message).not_to include('error result: success')
        expect(e.subtype).to eq('success')
        expect(e.terminal_reason).to eq('api_error')
        expect(e.result).to eq('API Error: Stream idle timeout - no chunks received')
        expect(e.errors).to be_empty
        expect(e.session_id).to eq('s-1')
      end
    end.wait
  end

  it 'falls back to the HTTP status when neither errors[] nor result carry text' do
    api_failure = {
      type: 'result', subtype: 'success', is_error: true, errors: [], result: '', api_error_status: 529
    }
    transport = transport_yielding(api_failure, error: process_error(1))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(
        ClaudeAgentSDK::ResultError, /returned an error result: API error \(HTTP 529\)/
      )
    end.wait
  end

  it 'falls back to the subtype when errors[] holds only blank entries' do
    blank = { type: 'result', subtype: 'error_during_execution', is_error: true, errors: [' '] }
    transport = transport_yielding(blank, error: process_error(1))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(
        ClaudeAgentSDK::ResultError, /returned an error result: error_during_execution/
      )
    end.wait
  end

  # A non-Array `errors` must neither be iterated per character nor crash the
  # read loop with an unrelated NoMethodError.
  [%w[boom boom], [42, 'error_during_execution']].each do |raw_errors, expected|
    it "tolerates a malformed errors field (#{raw_errors.inspect})" do
      malformed = { type: 'result', subtype: 'error_during_execution', is_error: true, errors: raw_errors }
      transport = transport_yielding(malformed, error: process_error(1))
      query = described_class.new(transport: transport, is_streaming_mode: true)

      Async do
        query.start
        expect { drain_until_error(query) }.to raise_error(
          ClaudeAgentSDK::ResultError, /returned an error result: #{Regexp.escape(expected)} \(/
        )
      end.wait
    end
  end

  it 'preserves the type of a transport failure that is not a ProcessError' do
    transport = transport_yielding(error_result, error: ClaudeAgentSDK::CLIConnectionError.new('lost the CLI'))
    query = described_class.new(transport: transport, is_streaming_mode: true)

    Async do
      query.start
      expect { drain_until_error(query) }.to raise_error(ClaudeAgentSDK::CLIConnectionError, 'lost the CLI')
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

    # A refused resume (nonexistent session, failed --resume-drops-turn
    # guard) is reported by the CLI as an error result on stdout followed by
    # exit 1, *before* it answers the SDK's `initialize`. The read loop used
    # to signal pending control requests with the raw exception, so the
    # in-flight request saw "Command failed with exit code 1" and the real
    # reason was discarded (Python #1198).
    it 'hands a pending control request the enriched result error, not the bare exit failure' do
      # Same load-bearing sequencing as above: the transport must not raise
      # until the interrupt's condition is registered, or the pending loop
      # would run before there is anything to signal.
      interrupt_on_wire = Async::Queue.new
      refused = {
        type: 'result', subtype: 'error_during_execution', is_error: true,
        errors: ['Resume rejected by --resume-drops-turn: nope']
      }

      transport = mock_transport
      allow(transport).to receive(:write) do |data|
        msg = JSON.parse(data, symbolize_names: true)
        interrupt_on_wire.enqueue(true) if msg[:type] == 'control_request' && msg.dig(:request, :subtype) == 'interrupt'
      end
      allow(transport).to receive(:read_messages) do |&block|
        block.call(refused)
        interrupt_on_wire.dequeue
        raise process_error(1)
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

      expect(failure).to be_a(ClaudeAgentSDK::ResultError),
                         "expected ResultError, got: #{failure.inspect}"
      expect(failure.message).to include(
        'Claude Code returned an error result: Resume rejected by --resume-drops-turn: nope'
      )
      expect(failure.subtype).to eq('error_during_execution')
      expect(failure.exit_code).to eq(1)
    end

    # The literal shape the fix was written for: the CLI reports the refusal
    # and exits *before* it ever answers `initialize`, so the handshake
    # itself is the pending request that has to receive the real reason.
    it 'hands a pending initialize the enriched result error' do
      initialize_on_wire = Async::Queue.new
      refused = {
        type: 'result', subtype: 'error_during_execution', is_error: true,
        errors: ['Resume rejected by --resume-drops-turn: nope']
      }

      transport = mock_transport
      allow(transport).to receive(:write) do |data|
        msg = JSON.parse(data, symbolize_names: true)
        initialize_on_wire.enqueue(true) if msg.dig(:request, :subtype) == 'initialize'
      end
      # The error result reaches stdout before the CLI answers initialize;
      # the exit follows only once the handshake is parked on its condition.
      allow(transport).to receive(:read_messages) do |&block|
        block.call(refused)
        initialize_on_wire.dequeue
        raise process_error(1)
      end

      query = described_class.new(transport: transport, is_streaming_mode: true)

      failure = nil
      Async do
        query.start
        begin
          query.initialize_protocol
        rescue StandardError => e
          failure = e
        end
      end.wait

      expect(failure).to be_a(ClaudeAgentSDK::ResultError),
                         "expected ResultError, got: #{failure.inspect}"
      expect(failure.message).to include('Resume rejected by --resume-drops-turn: nope')
      expect(failure.message).not_to include('Command failed with exit code 1')
      expect(failure.exit_code).to eq(1)
    end
  end
end
