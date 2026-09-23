# frozen_string_literal: true

require 'spec_helper'
require 'json'

# End to end through the real Query control protocol (no query_handler
# stubbing): a fake Transport answers each control_request the way the CLI
# does, serialized to JSON and parsed back with symbolize_names: true like
# SubprocessCLITransport. Pins the documented contract (docs/client.md, "MCP
# status and context usage return Hashes"): these methods return the CLI's
# `response` payload verbatim, Symbol keys with wire (camelCase) spelling,
# `{}` when the CLI sends no payload.
RSpec.describe ClaudeAgentSDK::Client do
  let(:mcp_status_payload) do
    {
      mcpServers: [
        { name: 'tools', status: 'connected', scope: 'project',
          serverInfo: { name: 'tools', version: '1.0.0' },
          config: { type: 'sdk', name: 'tools' },
          tools: [{ name: 'add', description: 'Add', annotations: { readOnly: true, openWorld: false } }] },
        { name: 'remote', status: 'failed', error: 'timeout',
          config: { type: 'http', url: 'https://example.com/mcp' } }
      ]
    }
  end

  let(:context_usage_payload) do
    { totalTokens: 1200, maxTokens: 200_000, categories: [{ name: 'System prompt', tokens: 300 }] }
  end

  # Answers every control_request with a success response. `payloads` maps a
  # request subtype to its payload; a subtype mapped to :none gets a response
  # with no `response` key at all. Unlisted subtypes (initialize) get {}.
  # Each request's subtype is appended to `subtypes`.
  let(:transport_class) do
    Class.new(ClaudeAgentSDK::Transport) do
      def initialize(_options, payloads:, subtypes:)
        super()
        @payloads = payloads
        @subtypes = subtypes
        @queue = Thread::Queue.new
      end

      def connect = @ready = true
      def ready? = @ready
      def end_input; end
      def close = @queue.push(:eof)

      def write(data)
        message = JSON.parse(data, symbolize_names: true)
        return unless message[:type] == 'control_request'

        subtype = message.dig(:request, :subtype)
        @subtypes << subtype
        response = { subtype: 'success', request_id: message[:request_id] }
        payload = @payloads.fetch(subtype, {})
        response[:response] = payload unless payload == :none
        @queue.push(JSON.parse(JSON.generate(type: 'control_response', response: response), symbolize_names: true))
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

  let(:subtypes) { [] }

  def with_client(payloads, &)
    described_class.open(transport_class: transport_class,
                         transport_args: { payloads: payloads, subtypes: subtypes }, &)
  end

  it 'returns the mcp_status payload as a Symbol-keyed Hash with wire spelling' do
    status, parity = with_client('mcp_status' => mcp_status_payload) do |client|
      [client.mcp_status, client.get_mcp_status]
    end

    expect(status).to eq(mcp_status_payload)
    expect(parity).to eq(status)
    expect(status.dig(:mcpServers, 0, :serverInfo, :version)).to eq('1.0.0')
    expect(status.dig(:mcpServers, 0, :tools, 0, :annotations, :readOnly)).to be(true)
    expect(status['mcpServers']).to be_nil
    expect(subtypes.count('mcp_status')).to eq(2)
  end

  it 'returns the context_usage payload as a Symbol-keyed Hash with wire spelling' do
    usage, parity = with_client('get_context_usage' => context_usage_payload) do |client|
      [client.context_usage, client.get_context_usage]
    end

    expect(usage).to eq(context_usage_payload)
    expect(parity).to eq(usage)
    expect(usage[:totalTokens]).to eq(1200)
    expect(usage[:total_tokens]).to be_nil
    expect(subtypes.count('get_context_usage')).to eq(2)
  end

  it 'returns {} when the CLI sends no payload' do
    status, usage = with_client('mcp_status' => :none, 'get_context_usage' => :none) do |client|
      [client.mcp_status, client.context_usage]
    end

    expect(status).to eq({})
    expect(usage).to eq({})
  end

  it 'parses into the typed view with McpStatusResponse.parse(client.mcp_status)' do
    typed = with_client('mcp_status' => mcp_status_payload) do |client|
      ClaudeAgentSDK::McpStatusResponse.parse(client.mcp_status)
    end

    sdk_server, http_server = typed.mcp_servers
    expect(typed).to be_a(ClaudeAgentSDK::McpStatusResponse)
    expect(sdk_server).to be_a(ClaudeAgentSDK::McpServerStatus)
    expect([sdk_server.name, sdk_server.status, sdk_server.scope]).to eq(%w[tools connected project])
    expect(sdk_server.server_info).to be_a(ClaudeAgentSDK::McpServerInfo)
    expect(sdk_server.server_info.version).to eq('1.0.0')
    expect(sdk_server.config).to be_a(ClaudeAgentSDK::McpSdkServerConfigStatus)
    expect(sdk_server.config.name).to eq('tools')
    expect(sdk_server.tools.first).to be_a(ClaudeAgentSDK::McpToolInfo)
    expect(sdk_server.tools.first.annotations.read_only).to be(true)
    expect([http_server.status, http_server.error]).to eq(%w[failed timeout])
    expect(http_server.config).to eq({ type: 'http', url: 'https://example.com/mcp' })
  end
end
