# frozen_string_literal: true

require 'spec_helper'
require 'json'

# A handler may return a String, or a Hash whose :content is an Array of
# content blocks. A Hash whose :content is itself a String (an easy slip next
# to the String form) or a single block Hash used to be forwarded as it was:
# the CLI rejected the frame against its schema and told the model that the
# SERVER "returned a malformed result", so the text never reached it.
RSpec.describe ClaudeAgentSDK::SdkMcpServer, 'a tool result whose :content is not an Array' do
  def server_returning(result)
    tool = ClaudeAgentSDK.create_tool('order_status', 'Look up an order', { id: :string }) { |_args| result }
    described_class.new(name: 'shop', tools: [tool])
  end

  # tools/call the way a session routes it: the frame from the CLI's
  # mcp_message control request, parsed with symbol keys, through the mcp gem.
  def call_through_session(server)
    wire = JSON.generate(jsonrpc: '2.0', id: 3, method: 'tools/call',
                         params: { name: 'order_status', arguments: { id: 'A-7' } })
    server.handle_message(JSON.parse(wire, symbolize_names: true))[:result]
  end

  def expect_content_error(result, got)
    expect(result[:isError]).to be true
    expect(result[:content]).to eq(
      [{ type: 'text',
         text: "Tool 'order_status' must return :content as an Array of content blocks (got #{got})" }]
    )
  end

  [
    ['a String', { content: 'Order A-7 has shipped' }, 'String'],
    ['a single block Hash', { content: { type: 'text', text: 'Order A-7 has shipped' } }, 'Hash'],
    ['a String under a String key', { 'content' => 'Order A-7 has shipped' }, 'String'],
    ['an Integer', { content: 7 }, 'Integer'],
    # Present, but falsy: the key is there, so this is a wrong value, not a
    # missing key.
    ['false', { content: false }, 'FalseClass'],
    ['a present nil', { content: nil }, 'NilClass'],
    ['a present nil under a String key', { 'content' => nil }, 'NilClass']
  ].each do |label, handler_result, got|
    it "answers a session's tools/call with an in-band error when :content is #{label}" do
      expect_content_error(call_through_session(server_returning(handler_result)), got)
    end

    it "returns the same error from #call_tool when :content is #{label}" do
      expect_content_error(server_returning(handler_result).call_tool('order_status', { id: 'A-7' }), got)
    end
  end

  it 'keeps the handler\'s own is_error flag out of it: the result is an error either way' do
    result = call_through_session(server_returning({ content: 'fine', is_error: false }))

    expect_content_error(result, 'String')
  end

  # The other diagnostic is about the KEY, and only about the key: a result
  # that is not a Hash, or a Hash with no :content under either spelling.
  [
    ['nil', nil],
    ['an Array of blocks without the Hash around it', [{ type: 'text', text: 'Order A-7 has shipped' }]],
    ['a Hash without the key', { text: 'Order A-7 has shipped' }],
    ['a Hash whose only key is :contents', { contents: [{ type: 'text', text: 'Order A-7 has shipped' }] }]
  ].each do |label, handler_result|
    it "says the :content key is missing, on both paths, when the handler returns #{label}" do
      server = server_returning(handler_result)
      missing = [{ type: 'text', text: "Tool 'order_status' must return a hash with :content key" }]

      session = call_through_session(server)
      expect(session[:isError]).to be true
      expect(session[:content]).to eq(missing)

      expect(server.call_tool('order_status', { id: 'A-7' })).to eq(content: missing, isError: true)
    end
  end

  it 'reads the Array under either spelling when the other one is nil' do
    server = server_returning({ content: nil, 'content' => [{ type: 'text', text: 'shipped' }] })

    expect(call_through_session(server)).to include(isError: false, content: [{ type: 'text', text: 'shipped' }])
    expect(server.call_tool('order_status', { id: 'A-7' })).not_to have_key(:isError)
  end

  # The legal shapes are untouched.
  [
    ['a String', 'Order A-7 has shipped', [{ type: 'text', text: 'Order A-7 has shipped' }]],
    ['an Array of blocks', { content: [{ type: 'text', text: 'shipped' }, { type: 'text', text: 'on time' }] },
     [{ type: 'text', text: 'shipped' }, { type: 'text', text: 'on time' }]],
    ['an empty Array', { content: [] }, []]
  ].each do |label, handler_result, content|
    it "still passes #{label} through on both paths" do
      server = server_returning(handler_result)

      session = call_through_session(server)
      expect(session[:isError]).to be false
      expect(session[:content]).to eq(content)

      direct = server.call_tool('order_status', { id: 'A-7' })
      expect(direct[:content]).to eq(content)
      expect(direct).not_to have_key(:isError)
    end
  end
end
