# frozen_string_literal: true

require 'spec_helper'
require 'async'

RSpec.describe 'Real Claude CLI Integration', :integration, :real_integration do
  before do
    skip 'Set RUN_REAL_INTEGRATION=1 to run real CLI integration tests' unless ENV['RUN_REAL_INTEGRATION'] == '1'
    skip 'Claude CLI is not available on PATH' unless system('command -v claude >/dev/null 2>&1')
    skip 'ANTHROPIC_API_KEY is required for real CLI integration tests' if ENV['ANTHROPIC_API_KEY'].to_s.empty?
  end

  it 'completes a minimal one-shot query through Claude CLI' do
    seen_result = nil
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      max_turns: 1,
      max_budget_usd: 0.02,
      tools: []
    )

    ClaudeAgentSDK.query(prompt: 'Reply with exactly: OK', options: options) do |message|
      seen_result = message if message.is_a?(ClaudeAgentSDK::ResultMessage)
    end

    expect(seen_result).to be_a(ClaudeAgentSDK::ResultMessage)
    expect(seen_result.is_error).to eq(false)
  end

  it 'initializes Client and returns server info' do
    Async do
      client = ClaudeAgentSDK::Client.new
      begin
        client.connect
        info = client.get_server_info

        expect(info).to be_a(Hash)
        expect(info).not_to eq({})
      ensure
        client.disconnect
      end
    end.wait
  end
end
