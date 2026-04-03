# frozen_string_literal: true

# Prevent require 'opentelemetry' from trying to load the real gem —
# we define our own mock module below.
$LOADED_FEATURES << 'opentelemetry' unless $LOADED_FEATURES.any? { |f| f.end_with?('/opentelemetry.rb') || f == 'opentelemetry' }

require 'claude_agent_sdk/instrumentation'

# Mock OpenTelemetry classes for testing without the actual gem
module OpenTelemetry
  module Trace
    class Status
      attr_reader :code, :description

      OK = 0
      ERROR = 1

      def self.error(description = '')
        new(ERROR, description)
      end

      def self.ok
        new(OK)
      end

      def initialize(code, description = '')
        @code = code
        @description = description
      end
    end

    def self.current_span
      nil
    end

    def self.context_with_span(span)
      { span: span }
    end
  end

  module Context
    def self.with_current(_context)
      yield
    end
  end

  def self.tracer_provider
    @tracer_provider ||= MockTracerProvider.new
  end

  class MockTracerProvider
    def tracer(name, version = nil)
      MockTracer.new(name, version)
    end
  end

  class MockTracer
    attr_reader :name, :version

    def initialize(name, version)
      @name = name
      @version = version
    end

    def start_span(name, attributes: {})
      MockSpan.new(name, attributes)
    end

    def in_span(name, attributes: {})
      span = start_span(name, attributes: attributes)
      yield span
      span.finish
      span
    end
  end

  class MockSpan
    attr_reader :name, :attributes, :events, :finished
    attr_accessor :status

    def initialize(name, attributes = {})
      @name = name
      @attributes = attributes.dup
      @events = []
      @finished = false
      @status = nil
    end

    def set_attribute(key, value)
      @attributes[key] = value
    end

    def add_attributes(attrs)
      @attributes.merge!(attrs)
    end

    def add_event(name, attributes: {})
      @events << { name: name, attributes: attributes }
    end

    def record_exception(error, attributes: {})
      add_event('exception', attributes: {
        'exception.type' => error.class.name,
        'exception.message' => error.message
      }.merge(attributes))
    end

    def finish
      @finished = true
    end
  end
end

RSpec.describe ClaudeAgentSDK::Instrumentation::OTelObserver do
  let(:observer) { described_class.new }
  let(:tracer) { OpenTelemetry.tracer_provider.tracer('test') }

  # Capture spans created by the observer
  let(:created_spans) { [] }

  before do
    # Track all spans created
    allow_any_instance_of(OpenTelemetry::MockTracer).to receive(:start_span) do |_tracer, name, **kwargs|
      span = OpenTelemetry::MockSpan.new(name, kwargs[:attributes] || {})
      created_spans << span
      span
    end
  end

  describe '#on_message with InitMessage' do
    let(:init_message) do
      ClaudeAgentSDK::InitMessage.new(
        subtype: 'init',
        data: {},
        uuid: 'uuid-1',
        session_id: 'sess-123',
        model: 'claude-sonnet-4',
        cwd: '/tmp/test',
        claude_code_version: '2.1.0',
        permission_mode: 'default',
        tools: nil, mcp_servers: nil, agents: nil, api_key_source: nil,
        betas: nil, slash_commands: nil, output_style: nil, skills: nil,
        plugins: nil, fast_mode_state: nil
      )
    end

    it 'creates a root span with gen_ai attributes' do
      observer.on_message(init_message)

      expect(created_spans.length).to eq(1)
      span = created_spans.first
      expect(span.name).to eq('claude_agent.session')
      expect(span.attributes['gen_ai.system']).to eq('anthropic')
      expect(span.attributes['gen_ai.request.model']).to eq('claude-sonnet-4')
      expect(span.attributes['session.id']).to eq('sess-123')
    end

    it 'sets OpenInference attributes for Langfuse compatibility' do
      observer.on_message(init_message)

      span = created_spans.first
      expect(span.attributes['openinference.span.kind']).to eq('AGENT')
      expect(span.attributes['llm.model_name']).to eq('claude-sonnet-4')
      expect(span.attributes['input.mime_type']).to eq('text/plain')
      expect(span.attributes['output.mime_type']).to eq('text/plain')
    end

    it 'includes optional metadata attributes' do
      observer.on_message(init_message)

      span = created_spans.first
      expect(span.attributes['claude_code.version']).to eq('2.1.0')
      expect(span.attributes['claude_code.cwd']).to eq('/tmp/test')
      expect(span.attributes['claude_code.permission_mode']).to eq('default')
    end
  end

  describe '#on_message with AssistantMessage' do
    let(:init_message) do
      ClaudeAgentSDK::InitMessage.new(
        subtype: 'init', data: {}, uuid: nil, session_id: 'sess-1',
        model: 'claude-sonnet-4', cwd: nil, claude_code_version: nil,
        permission_mode: nil, tools: nil, mcp_servers: nil, agents: nil,
        api_key_source: nil, betas: nil, slash_commands: nil, output_style: nil,
        skills: nil, plugins: nil, fast_mode_state: nil
      )
    end

    let(:assistant_message) do
      ClaudeAgentSDK::AssistantMessage.new(
        content: [
          ClaudeAgentSDK::TextBlock.new(text: 'Hello!'),
          ClaudeAgentSDK::TextBlock.new(text: 'How can I help?')
        ],
        model: 'claude-sonnet-4',
        usage: { input_tokens: 100, output_tokens: 50 }
      )
    end

    before do
      observer.on_message(init_message)
      created_spans.clear
    end

    it 'creates a generation span' do
      observer.on_message(assistant_message)

      generation_spans = created_spans.select { |s| s.name == 'claude_agent.generation' }
      expect(generation_spans.length).to eq(1)

      span = generation_spans.first
      expect(span.attributes['gen_ai.response.model']).to eq('claude-sonnet-4')
      expect(span.attributes['gen_ai.usage.input_tokens']).to eq(100)
      expect(span.attributes['gen_ai.usage.output_tokens']).to eq(50)
      expect(span.attributes['gen_ai.completion']).to eq("Hello!\nHow can I help?")
    end

    it 'finishes the generation span immediately' do
      observer.on_message(assistant_message)

      generation_span = created_spans.find { |s| s.name == 'claude_agent.generation' }
      expect(generation_span.finished).to be true
    end
  end

  describe '#on_message with ToolUseBlock and ToolResultBlock' do
    let(:init_message) do
      ClaudeAgentSDK::InitMessage.new(
        subtype: 'init', data: {}, uuid: nil, session_id: 'sess-1',
        model: 'claude-sonnet-4', cwd: nil, claude_code_version: nil,
        permission_mode: nil, tools: nil, mcp_servers: nil, agents: nil,
        api_key_source: nil, betas: nil, slash_commands: nil, output_style: nil,
        skills: nil, plugins: nil, fast_mode_state: nil
      )
    end

    let(:assistant_with_tool) do
      ClaudeAgentSDK::AssistantMessage.new(
        content: [
          ClaudeAgentSDK::TextBlock.new(text: 'Let me read that file.'),
          ClaudeAgentSDK::ToolUseBlock.new(
            id: 'toolu_abc',
            name: 'Read',
            input: { file_path: '/tmp/test.rb' }
          )
        ],
        model: 'claude-sonnet-4',
        usage: { input_tokens: 50, output_tokens: 30 }
      )
    end

    let(:user_with_tool_result) do
      ClaudeAgentSDK::UserMessage.new(
        content: [
          ClaudeAgentSDK::ToolResultBlock.new(
            tool_use_id: 'toolu_abc',
            content: 'puts "hello"',
            is_error: false
          )
        ]
      )
    end

    before do
      observer.on_message(init_message)
      created_spans.clear
    end

    it 'opens a tool span for ToolUseBlock' do
      observer.on_message(assistant_with_tool)

      tool_spans = created_spans.select { |s| s.name == 'claude_agent.tool.Read' }
      expect(tool_spans.length).to eq(1)

      span = tool_spans.first
      expect(span.attributes['tool.name']).to eq('Read')
      expect(span.attributes['input.value']).to include('file_path')
      expect(span.attributes['input.mime_type']).to eq('application/json')
      expect(span.finished).to be false
    end

    it 'closes the tool span when ToolResultBlock arrives' do
      observer.on_message(assistant_with_tool)
      tool_span = created_spans.find { |s| s.name == 'claude_agent.tool.Read' }

      observer.on_message(user_with_tool_result)

      expect(tool_span.finished).to be true
      expect(tool_span.attributes['output.value']).to eq('puts "hello"')
    end

    it 'sets error status on tool span when is_error is true' do
      observer.on_message(assistant_with_tool)

      error_result = ClaudeAgentSDK::UserMessage.new(
        content: [
          ClaudeAgentSDK::ToolResultBlock.new(
            tool_use_id: 'toolu_abc',
            content: 'file not found',
            is_error: true
          )
        ]
      )
      observer.on_message(error_result)

      tool_span = created_spans.find { |s| s.name == 'claude_agent.tool.Read' }
      expect(tool_span.status).not_to be_nil
      expect(tool_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    end
  end

  describe '#on_message with ResultMessage' do
    let(:init_message) do
      ClaudeAgentSDK::InitMessage.new(
        subtype: 'init', data: {}, uuid: nil, session_id: 'sess-1',
        model: 'claude-sonnet-4', cwd: nil, claude_code_version: nil,
        permission_mode: nil, tools: nil, mcp_servers: nil, agents: nil,
        api_key_source: nil, betas: nil, slash_commands: nil, output_style: nil,
        skills: nil, plugins: nil, fast_mode_state: nil
      )
    end

    let(:result_message) do
      ClaudeAgentSDK::ResultMessage.new(
        subtype: 'success',
        duration_ms: 1500,
        duration_api_ms: 1000,
        is_error: false,
        num_turns: 2,
        session_id: 'sess-1',
        total_cost_usd: 0.0042,
        usage: { input_tokens: 200, output_tokens: 100 },
        stop_reason: 'end_turn'
      )
    end

    before do
      observer.on_message(init_message)
    end

    it 'finishes the root span with cost and usage attributes' do
      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }

      observer.on_message(result_message)

      expect(root_span.finished).to be true
      expect(root_span.attributes['gen_ai.usage.cost']).to eq(0.0042)
      expect(root_span.attributes['claude_agent.duration_ms']).to eq(1500)
      expect(root_span.attributes['claude_agent.num_turns']).to eq(2)
      expect(root_span.attributes['claude_agent.stop_reason']).to eq('end_turn')
      expect(root_span.attributes['gen_ai.usage.input_tokens']).to eq(200)
      expect(root_span.attributes['gen_ai.usage.output_tokens']).to eq(100)
    end

    it 'sets OpenInference token and cost attributes' do
      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }

      observer.on_message(result_message)

      expect(root_span.attributes['llm.token_count.prompt']).to eq(200)
      expect(root_span.attributes['llm.token_count.completion']).to eq(100)
      expect(root_span.attributes['llm.token_count.total']).to eq(300)
      expect(root_span.attributes['llm.cost.total']).to eq(0.0042)
    end

    it 'captures input from on_user_prompt and output from last AssistantMessage' do
      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }

      # Simulate: prompt → assistant response → result
      observer.on_user_prompt('What is 2+2?')
      assistant_msg = ClaudeAgentSDK::AssistantMessage.new(
        content: [ClaudeAgentSDK::TextBlock.new(text: 'The answer is 4.')],
        model: 'claude-sonnet-4',
        usage: { input_tokens: 10, output_tokens: 8 }
      )

      observer.on_message(assistant_msg)
      observer.on_message(result_message)

      expect(root_span.attributes['input.value']).to eq('What is 2+2?')
      expect(root_span.attributes['output.value']).to eq('The answer is 4.')
    end

    it 'only captures the first prompt via on_user_prompt' do
      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }

      observer.on_user_prompt('First prompt')
      observer.on_user_prompt('Second prompt')
      observer.on_message(result_message)

      expect(root_span.attributes['input.value']).to eq('First prompt')
    end

    it 'sets error status when is_error is true' do
      error_result = ClaudeAgentSDK::ResultMessage.new(
        subtype: 'error',
        is_error: true,
        stop_reason: 'max_turns',
        duration_ms: 500,
        duration_api_ms: 400,
        num_turns: 1,
        session_id: 'sess-1',
        usage: {}
      )

      observer.on_message(error_result)

      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }
      expect(root_span.status).not_to be_nil
      expect(root_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    end
  end

  describe '#on_message with APIRetryMessage' do
    before do
      init_msg = ClaudeAgentSDK::InitMessage.new(
        subtype: 'init', data: {}, uuid: nil, session_id: 'sess-1',
        model: 'claude-sonnet-4', cwd: nil, claude_code_version: nil,
        permission_mode: nil, tools: nil, mcp_servers: nil, agents: nil,
        api_key_source: nil, betas: nil, slash_commands: nil, output_style: nil,
        skills: nil, plugins: nil, fast_mode_state: nil
      )
      observer.on_message(init_msg)
    end

    it 'records an api_retry event on the root span' do
      retry_msg = ClaudeAgentSDK::APIRetryMessage.new(
        subtype: 'api_retry', data: {},
        attempt: 2, max_retries: 5, retry_delay_ms: 1000,
        error_status: 429, error: 'rate limited'
      )

      observer.on_message(retry_msg)

      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }
      expect(root_span.events.length).to eq(1)
      expect(root_span.events.first[:name]).to eq('api_retry')
      expect(root_span.events.first[:attributes]['attempt']).to eq(2)
    end
  end

  describe '#on_error' do
    before do
      init_msg = ClaudeAgentSDK::InitMessage.new(
        subtype: 'init', data: {}, uuid: nil, session_id: 'sess-1',
        model: 'claude-sonnet-4', cwd: nil, claude_code_version: nil,
        permission_mode: nil, tools: nil, mcp_servers: nil, agents: nil,
        api_key_source: nil, betas: nil, slash_commands: nil, output_style: nil,
        skills: nil, plugins: nil, fast_mode_state: nil
      )
      observer.on_message(init_msg)
    end

    it 'records exception on root span' do
      error = RuntimeError.new('connection lost')
      observer.on_error(error)

      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }
      expect(root_span.events.length).to eq(1)
      expect(root_span.events.first[:name]).to eq('exception')
      expect(root_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    end

    it 'is a no-op when no root span exists' do
      fresh_observer = described_class.new
      expect { fresh_observer.on_error(RuntimeError.new('test')) }.not_to raise_error
    end
  end

  describe '#on_close' do
    before do
      init_msg = ClaudeAgentSDK::InitMessage.new(
        subtype: 'init', data: {}, uuid: nil, session_id: 'sess-1',
        model: 'claude-sonnet-4', cwd: nil, claude_code_version: nil,
        permission_mode: nil, tools: nil, mcp_servers: nil, agents: nil,
        api_key_source: nil, betas: nil, slash_commands: nil, output_style: nil,
        skills: nil, plugins: nil, fast_mode_state: nil
      )
      observer.on_message(init_msg)
    end

    it 'finishes the root span' do
      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }
      observer.on_close

      expect(root_span.finished).to be true
    end

    it 'finishes any open tool spans' do
      assistant_msg = ClaudeAgentSDK::AssistantMessage.new(
        content: [
          ClaudeAgentSDK::ToolUseBlock.new(id: 'toolu_1', name: 'Bash', input: { command: 'ls' })
        ],
        model: 'claude-sonnet-4',
        usage: {}
      )
      observer.on_message(assistant_msg)

      tool_span = created_spans.find { |s| s.name == 'claude_agent.tool.Bash' }
      expect(tool_span.finished).to be false

      observer.on_close

      expect(tool_span.finished).to be true
    end

    it 'is safe to call multiple times' do
      observer.on_close
      expect { observer.on_close }.not_to raise_error
    end
  end

  describe 'default_attributes' do
    it 'merges custom attributes into root span' do
      custom_observer = described_class.new(
        'user.id' => 'user-42',
        'langfuse.session.id' => 'my-session'
      )

      init_msg = ClaudeAgentSDK::InitMessage.new(
        subtype: 'init', data: {}, uuid: nil, session_id: 'sess-1',
        model: 'claude-sonnet-4', cwd: nil, claude_code_version: nil,
        permission_mode: nil, tools: nil, mcp_servers: nil, agents: nil,
        api_key_source: nil, betas: nil, slash_commands: nil, output_style: nil,
        skills: nil, plugins: nil, fast_mode_state: nil
      )
      custom_observer.on_message(init_msg)

      root_span = created_spans.find { |s| s.name == 'claude_agent.session' }
      expect(root_span.attributes['user.id']).to eq('user-42')
      expect(root_span.attributes['langfuse.session.id']).to eq('my-session')
    end
  end
end
