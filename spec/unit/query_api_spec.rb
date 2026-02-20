# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK, '.query' do
  it 'passes entrypoint via transport env without mutating global ENV' do
    original_entrypoint = ENV['CLAUDE_CODE_ENTRYPOINT']
    ENV.delete('CLAUDE_CODE_ENTRYPOINT')

    captured_options = nil
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)
    allow(transport).to receive(:read_messages) # returns nil immediately

    query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: nil, close: nil)
    allow(query_handler).to receive(:receive_messages) # yields nothing

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |opts|
      captured_options = opts
      transport
    end
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(env: { 'EXTRA' => '1' })

    # query() calls Async do...end.wait internally; wrap in Async to prevent nested reactor issues.
    begin
      Async do
        described_class.query(prompt: 'hello', options: options) { |_message| nil }
      end.wait
    rescue StandardError
      # Ignore errors from mock transport — we're only testing options configuration
    end

    expect(captured_options).not_to be_nil
    expect(captured_options.env['CLAUDE_CODE_ENTRYPOINT']).to eq('sdk-rb')
    expect(captured_options.env['EXTRA']).to eq('1')
    expect(options.env['CLAUDE_CODE_ENTRYPOINT']).to be_nil
    expect(ENV['CLAUDE_CODE_ENTRYPOINT']).to be_nil
  ensure
    if original_entrypoint.nil?
      ENV.delete('CLAUDE_CODE_ENTRYPOINT')
    else
      ENV['CLAUDE_CODE_ENTRYPOINT'] = original_entrypoint
    end
  end
end
