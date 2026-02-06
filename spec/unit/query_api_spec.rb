# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK, '.query' do
  it 'passes entrypoint via transport env without mutating global ENV' do
    original_entrypoint = ENV['CLAUDE_CODE_ENTRYPOINT']
    ENV.delete('CLAUDE_CODE_ENTRYPOINT')

    captured_options = nil
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil)
    allow(transport).to receive(:read_messages) { nil }

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |_prompt, options|
      captured_options = options
      transport
    end

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(env: { 'EXTRA' => '1' })
    described_class.query(prompt: 'hello', options: options) { |_message| nil }

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
