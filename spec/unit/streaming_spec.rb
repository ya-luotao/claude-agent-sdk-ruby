# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::Streaming do
  describe '.from_block' do
    it 'wraps each yielded string as a JSON user message line' do
      stream = described_class.from_block(session_id: 's1') do |yielder|
        yielder.yield('First')
        yielder.yield('Second')
      end

      lines = stream.to_a
      expect(lines).to all(end_with("\n"))
      messages = lines.map { |line| JSON.parse(line) }
      expect(messages.map { |m| m.dig('message', 'content') }).to eq(%w[First Second])
      expect(messages).to all(include('type' => 'user', 'session_id' => 's1', 'parent_tool_use_id' => nil))
    end
  end
end
