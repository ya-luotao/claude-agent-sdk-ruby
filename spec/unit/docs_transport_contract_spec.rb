# frozen_string_literal: true

require 'spec_helper'
require 'json'

# The custom-transport contract is written down in three places: the
# _Transport interface in sig/, the table in docs/client.md and one sentence
# of the bundled skill. They once listed five, six and four methods, and a
# transport written from the four-method list hung query(). The interface in
# sig/ is the reference; the other two must name the same methods, and a
# transport with exactly those methods must work.
RSpec.describe 'the custom transport contract' do
  let(:root) { File.expand_path('../..', __dir__) }

  let(:interface_methods) do
    sig = File.read(File.join(root, 'sig/claude_agent_sdk/transport.rbs'))
    sig[/^  interface _Transport\n(.*?)^  end/m, 1].scan(/def (\w+\??):/).flatten
  end

  # A scripted stand-in for the CLI with the interface's methods and nothing
  # else. It answers the initialize request, and each user message with the
  # frames a turn produces (system/init, assistant, result).
  let(:minimal_transport_class) do
    Class.new do
      def initialize(*)
        @frames = Thread::Queue.new
      end

      def connect; end

      def write(data)
        data.each_line do |line|
          frame = JSON.parse(line, symbolize_names: true)
          case frame[:type]
          when 'control_request' then answer_control_request(frame)
          when 'user' then answer_user_message
          end
        end
      end

      def read_messages
        while (frame = @frames.pop) != :end
          yield frame
        end
      end

      def end_input
        @frames << :end
      end

      def close
        @frames << :end
      end

      private

      def answer_control_request(frame)
        @frames << { type: 'control_response',
                     response: { subtype: 'success', request_id: frame[:request_id], response: {} } }
      end

      def answer_user_message
        session_id = '11111111-1111-4111-8111-111111111111'
        @frames << { type: 'system', subtype: 'init', session_id: session_id, uuid: 'init-1',
                     model: 'claude-haiku-4-5', cwd: '/srv/app', tools: %w[Read Bash],
                     claude_code_version: '2.1.285', permissionMode: 'default' }
        @frames << { type: 'assistant', session_id: session_id, uuid: 'assistant-1', parent_tool_use_id: nil,
                     message: { id: 'msg_1', role: 'assistant', model: 'claude-haiku-4-5',
                                content: [{ type: 'text', text: 'Hello.' }],
                                usage: { input_tokens: 10, output_tokens: 5 } } }
        @frames << { type: 'result', subtype: 'success', is_error: false, duration_ms: 2100,
                     duration_api_ms: 1800, num_turns: 1, session_id: session_id, total_cost_usd: 0.0031,
                     result: 'Hello.', usage: { input_tokens: 10, output_tokens: 5 }, uuid: 'result-1' }
      end
    end
  end

  it 'has five methods in sig/, none of them ready?' do
    expect(interface_methods).to match_array(%w[connect write read_messages end_input close])
  end

  it 'lists the same methods in the docs/client.md table' do
    section = File.read(File.join(root, 'docs/client.md'))[/^## Custom Transport\n(.*?)^###? /m, 1]

    expect(section.scan(/^\| `(\w+\??)/).flatten).to match_array(interface_methods)
  end

  it 'lists the same methods in both copies of the skill' do
    %w[skills plugins/claude-agent-ruby/skills/claude-agent-ruby].each do |tree|
      text = File.read(File.join(root, tree, 'references/options.md'))
      required = text[/A custom transport must implement ([^(.]*)/, 1].to_s

      expect(required.scan(/`(\w+\??)`/).flatten).to match_array(interface_methods), "in #{tree}"
    end
  end

  it 'serves query and Client with a transport that has only those methods' do
    expect(minimal_transport_class.public_instance_methods(false)).to match_array(interface_methods.map(&:to_sym))

    from_query = []
    ClaudeAgentSDK.query(prompt: 'Hello', transport: minimal_transport_class.new) { |message| from_query << message }
    from_client = []
    ClaudeAgentSDK::Client.open(transport_class: minimal_transport_class) do |client|
      client.query('Hello')
      client.receive_response { |message| from_client << message }
    end

    [from_query, from_client].each do |messages|
      expect(messages.map(&:class)).to eq(
        [ClaudeAgentSDK::InitMessage, ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage]
      )
      expect(messages.last.result).to eq('Hello.')
    end
  end
end
