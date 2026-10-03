# frozen_string_literal: true

module TestHelpers
  # Helper to create sample messages
  def sample_user_message
    {
      type: 'user',
      message: {
        role: 'user',
        content: 'Hello, Claude!'
      },
      parent_tool_use_id: nil
    }
  end

  def sample_assistant_message
    {
      type: 'assistant',
      message: {
        role: 'assistant',
        model: 'claude-sonnet-4',
        content: [
          { type: 'text', text: 'Hello! How can I help you?' }
        ]
      },
      parent_tool_use_id: nil
    }
  end

  def sample_assistant_message_with_tool_use
    {
      type: 'assistant',
      message: {
        role: 'assistant',
        model: 'claude-sonnet-4',
        content: [
          { type: 'text', text: "I'll help you with that." },
          {
            type: 'tool_use',
            id: 'toolu_123',
            name: 'Read',
            input: { file_path: '/path/to/file.rb' }
          }
        ]
      },
      parent_tool_use_id: nil
    }
  end

  def sample_result_message
    {
      type: 'result',
      subtype: 'success',
      duration_ms: 1500,
      duration_api_ms: 1000,
      is_error: false,
      num_turns: 1,
      session_id: 'test_session_123',
      total_cost_usd: 0.001234,
      usage: {
        input_tokens: 100,
        output_tokens: 50
      }
    }
  end

  def sample_system_message
    {
      type: 'system',
      subtype: 'info',
      message: 'Test system message'
    }
  end

  # #connect over a stubbed Open3.popen3, then wait for the stderr drain it
  # starts. An example that never closes its transport leaves that thread
  # running: given an rspec double as stderr, it reads it after the example,
  # when the double has expired, dies, and Ruby prints the report on $stderr in
  # whichever example is running then — inside an `output.to_stderr` matcher, a
  # failure (seen on Ruby 4.0). Stub stdout and stderr with StringIOs; the join
  # turns a double that comes back into a failure of its own example.
  def connect_draining_stderr(transport)
    transport.connect
    drain = transport.instance_variable_get(:@stderr_task)
    raise 'the stderr drain did not finish' if drain && !drain.join(5)
  end

  # Helper to create a mock transport
  def mock_transport
    double('Transport').tap do |transport|
      allow(transport).to receive(:connect)
      allow(transport).to receive(:close)
      allow(transport).to receive(:write)
      allow(transport).to receive(:ready?).and_return(true)
      allow(transport).to receive(:end_input)
    end
  end
end
