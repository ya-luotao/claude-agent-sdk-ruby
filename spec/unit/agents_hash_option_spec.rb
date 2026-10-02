# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'json'

# ClaudeAgentOptions#agents is signed
#   Hash[String | Symbol, AgentDefinition | Hash[Symbol | String, untyped]]
# but the initialize request was built by calling readers on every value, so
# an agent given as a Hash raised NoMethodError out of connect.
#
# End to end through the real control protocol (no stubbing of Query): a fake
# Transport records each control request as the CLI's JSON parser sees it and
# answers it the way the CLI does.
RSpec.describe 'agents given as Hashes' do
  let(:transport_class) do
    Class.new(ClaudeAgentSDK::Transport) do
      def initialize(_options, requests:)
        super()
        @requests = requests
        @queue = Thread::Queue.new
      end

      def connect = @ready = true
      def ready? = @ready
      def end_input; end
      def close = @queue.push(:eof)

      def write(data)
        message = JSON.parse(data, symbolize_names: true)
        return unless message[:type] == 'control_request'

        @requests << JSON.parse(data).fetch('request')
        response = { subtype: 'success', request_id: message[:request_id], response: {} }
        @queue.push({ type: 'control_response', response: response })
      end

      def read_messages
        loop do
          message = @queue.pop
          break if message == :eof

          yield message
        end
      end
    end
  end

  let(:requests) { [] }

  def client_with(agents)
    ClaudeAgentSDK::Client.new(
      options: ClaudeAgentSDK::ClaudeAgentOptions.new(agents: agents),
      transport_class: transport_class, transport_args: { requests: requests }
    )
  end

  # The `agents` object of the initialize request a session with these
  # agents sends.
  def agents_on_the_wire(agents)
    requests.clear
    Sync do
      client = client_with(agents)
      client.connect
    ensure
      client&.disconnect
    end
    requests.find { |request| request['subtype'] == 'initialize' }.fetch('agents')
  end

  # What connecting with these agents raises, caught inside the reactor.
  def connect_error(agents)
    Sync do
      client = client_with(agents)
      client.connect
      nil
    rescue StandardError => e
      e
    ensure
      client&.disconnect
    end
  end

  # Every attribute of AgentDefinition, with an inline MCP server config
  # next to a server name.
  attributes = {
    description: 'Reviews pull requests',
    prompt: 'You review code. Be specific.',
    tools: %w[Read Grep],
    disallowed_tools: %w[Bash],
    model: 'sonnet',
    skills: %w[review],
    memory: 'project',
    mcp_servers: ['docs', { 'tracker' => { type: 'http', url: 'https://example.com/mcp' } }],
    initial_prompt: 'Start with the diff.',
    max_turns: 4,
    background: true,
    effort: 'high',
    permission_mode: 'plan'
  }.freeze

  wire_agent = {
    'description' => 'Reviews pull requests',
    'prompt' => 'You review code. Be specific.',
    'tools' => %w[Read Grep],
    'disallowedTools' => %w[Bash],
    'model' => 'sonnet',
    'skills' => %w[review],
    'memory' => 'project',
    'mcpServers' => ['docs', { 'tracker' => { 'type' => 'http', 'url' => 'https://example.com/mcp' } }],
    'initialPrompt' => 'Start with the diff.',
    'maxTurns' => 4,
    'background' => true,
    'effort' => 'high',
    'permissionMode' => 'plan'
  }.freeze

  it 'covers every attribute of AgentDefinition' do
    expect(attributes.keys.map(&:to_s)).to match_array(ClaudeAgentSDK::AgentDefinition.attribute_names)
  end

  it 'sends a typed AgentDefinition under its wire keys' do
    typed = ClaudeAgentSDK::AgentDefinition.new(attributes)

    expect(agents_on_the_wire('reviewer' => typed)).to eq('reviewer' => wire_agent)
  end

  {
    'Symbol keys' => attributes,
    'String keys' => attributes.transform_keys(&:to_s),
    'camelCase String keys' => wire_agent
  }.each do |spelling, hash|
    it "sends a Hash with #{spelling} like the AgentDefinition it stands for" do
      expect(agents_on_the_wire('reviewer' => hash)).to eq('reviewer' => wire_agent)
    end
  end

  it 'takes Hash and typed agents side by side, under Symbol or String names' do
    agents = {
      reviewer: { description: 'Reviews pull requests', prompt: 'You review code.' },
      'writer' => ClaudeAgentSDK::AgentDefinition.new(description: 'Writes docs', prompt: 'You write docs.')
    }

    expect(agents_on_the_wire(agents)).to eq(
      'reviewer' => { 'description' => 'Reviews pull requests', 'prompt' => 'You review code.' },
      'writer' => { 'description' => 'Writes docs', 'prompt' => 'You write docs.' }
    )
  end

  it 'raises the strict-attribute error for a misspelled key, before anything is written' do
    error = connect_error('reviewer' => { description: 'Reviews pull requests', promt: 'You review code.' })

    expect(error).to be_a(ArgumentError)
    expect(error.message).to start_with('ClaudeAgentSDK::AgentDefinition: unknown attribute :promt (known: ')
    expect(requests).to be_empty
  end
end
