# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK, '.ask' do
  # A transport that answers the initialize control request, then replays
  # +frames+ and ends the stream — or raises +error+ in place of a clean EOF.
  def fake_transport(frames, error: nil)
    Class.new do
      attr_reader :writes

      define_method(:initialize) do
        @incoming = Async::Queue.new
        @writes = []
      end

      def connect; end
      def end_input; end
      def close; end

      define_method(:write) do |data|
        @writes << JSON.parse(data, symbolize_names: true)
        msg = @writes.last
        return unless msg[:type] == 'control_request' && msg.dig(:request, :subtype) == 'initialize'

        @incoming.enqueue(type: 'control_response',
                          response: { subtype: 'success', request_id: msg[:request_id], response: {} })
        frames.each { |frame| @incoming.enqueue(frame) }
        @incoming.enqueue(:end)
      end

      define_method(:read_messages) do |&block|
        loop do
          msg = @incoming.dequeue
          break if msg == :end

          block.call(msg)
        end
        raise error if error
      end
    end.new
  end

  def result_frame(text, **overrides)
    { type: 'result', subtype: 'success', is_error: false, duration_ms: 1200, duration_api_ms: 900,
      num_turns: 1, session_id: 's-1', total_cost_usd: 0.002, result: text }.merge(overrides)
  end

  let(:assistant_frame) do
    { type: 'assistant', message: { role: 'assistant', model: 'claude-sonnet-4', content: [{ type: 'text', text: '4' }] } }
  end

  it 'returns the ResultMessage, whose #result is the final text' do
    transport = fake_transport([assistant_frame, result_frame('2 + 2 = 4')])

    result = described_class.ask('What is 2 + 2?', transport: transport)

    expect(result).to be_a(ClaudeAgentSDK::ResultMessage)
    expect(result.result).to eq('2 + 2 = 4')
    expect(result.session_id).to eq('s-1')
    expect(result.to_s).to start_with('[result: success, 1 turn')
    user_frame = transport.writes.find { |w| w[:type] == 'user' }
    expect(user_frame.dig(:message, :content)).to eq('What is 2 + 2?')
  end

  it 'yields every message to the block, in order, and still returns the result' do
    transport = fake_transport([assistant_frame, result_frame('done')])
    seen = []

    result = described_class.ask('hi', transport: transport) { |message| seen << message }

    expect(seen.map(&:class)).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
    expect(seen.last).to equal(result)
  end

  it 'returns the last ResultMessage when the prompt produces several turns' do
    transport = fake_transport([result_frame('first'), result_frame('second', num_turns: 2)])
    prompt = ClaudeAgentSDK::Streaming.from_array(%w[one two])

    expect(described_class.ask(prompt, transport: transport).result).to eq('second')
  end

  it 'passes the prompt, options and transport straight to .query' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(max_turns: 1)
    transport = fake_transport([])
    result = ClaudeAgentSDK::ResultMessage.new(subtype: 'success', duration_ms: 1, duration_api_ms: 1,
                                               is_error: false, num_turns: 1, session_id: 's')
    allow(described_class).to receive(:query).and_yield(result)

    expect(described_class.ask('hi', options: options, transport: transport)).to equal(result)
    expect(described_class).to have_received(:query).with(prompt: 'hi', options: options, transport: transport)
  end

  it 'returns an error result like any other when the stream ends cleanly' do
    transport = fake_transport([result_frame('API Error: overloaded', is_error: true)])

    result = described_class.ask('hi', transport: transport)

    expect(result.is_error).to be(true)
    expect(result.result).to eq('API Error: overloaded')
  end

  it 'lets the ResultError query raises for an error exit propagate unchanged' do
    exit_error = ClaudeAgentSDK::ProcessError.new('Command failed with exit code 1', exit_code: 1)
    error_result = result_frame(nil, subtype: 'error_max_turns', is_error: true, errors: ['max turns reached'])
    transport = fake_transport([error_result], error: exit_error)
    seen = []

    expect { described_class.ask('hi', transport: transport) { |message| seen << message } }
      .to raise_error(ClaudeAgentSDK::ResultError) { |e| expect(e.subtype).to eq('error_max_turns') }
    expect(seen.last).to be_a(ClaudeAgentSDK::ResultMessage)
  end

  it 'raises CLIConnectionError when the stream ends without a ResultMessage' do
    transport = fake_transport([assistant_frame])

    expect { described_class.ask('hi', transport: transport) }
      .to raise_error(ClaudeAgentSDK::CLIConnectionError, /without a result message/)
  end

  it 'propagates an exception raised by the block' do
    transport = fake_transport([assistant_frame, result_frame('done')])

    expect { described_class.ask('hi', transport: transport) { |_message| raise 'observer failed' } }
      .to raise_error(RuntimeError, 'observer failed')
  end

  it 'rejects the prompts .query rejects, before starting anything',
     rbs_incompatible: 'passes out-of-signature input to test its rejection' do
    expect(ClaudeAgentSDK::SubprocessCLITransport).not_to receive(:new)

    expect { described_class.ask({ role: 'user' }) }.to raise_error(ArgumentError, /got Hash/)
    expect { described_class.ask(nil) }.to raise_error(ArgumentError, /respond to #each/)
  end
end
