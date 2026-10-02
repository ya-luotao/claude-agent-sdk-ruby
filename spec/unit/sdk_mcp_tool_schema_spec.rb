# frozen_string_literal: true

require 'spec_helper'
require 'json'

# Shorthand tool schemas ({ name: type }) for collection parameters.
# `{ tags: Array }` used to be advertised as a string: the model then sent
# "fragile,gift" where the handler expected an Array, and a model that did
# send an array had its call rejected by argument validation.
#
# A session answers tools/list from SdkMcpServer#list_tools and routes
# tools/call through #handle_message (the mcp gem, which validates the
# arguments), so the two are checked against each other here.
RSpec.describe ClaudeAgentSDK::SdkMcpServer, 'shorthand schemas for Array and Hash parameters' do
  def server_with(schema, received = [])
    tool = ClaudeAgentSDK.create_tool('tag_order', 'Tag an order', schema) do |args|
      received << args
      "tagged with #{args.inspect}"
    end
    described_class.new(name: 'shop', tools: [tool])
  end

  # The frame the CLI embeds in an mcp_message control request, as the
  # transport hands it over: parsed with symbol keys.
  def call_tool(server, arguments)
    wire = JSON.generate(jsonrpc: '2.0', id: 7, method: 'tools/call',
                         params: { name: 'tag_order', arguments: arguments })
    server.handle_message(JSON.parse(wire, symbolize_names: true))
  end

  def advertised_type(server, param)
    server.list_tools.first.dig(:inputSchema, :properties, param, :type)
  end

  [
    [Array, 'array', %w[fragile gift], 'fragile,gift'],
    [:array, 'array', [1, 2, 3], 7],
    [Hash, 'object', { gift: true, note: 'handle with care' }, 'gift=true'],
    [:object, 'object', { priority: 2 }, %w[priority 2]]
  ].each do |type, json_type, valid, invalid|
    it "advertises #{type.inspect} as #{json_type}, accepts one and rejects anything else" do
      received = []
      server = server_with({ order_id: Integer, value: type }, received)

      expect(advertised_type(server, :value)).to eq(json_type)
      expect(advertised_type(server, :order_id)).to eq('integer')
      expect(server.list_tools.first.dig(:inputSchema, :required)).to eq(%w[order_id value])

      accepted = call_tool(server, { order_id: 7, value: valid })
      expect(accepted.dig(:result, :isError)).to be(false), accepted.inspect
      expect(received).to eq([{ order_id: 7, value: valid }])

      rejected = call_tool(server, { order_id: 7, value: invalid })
      expect(rejected.dig(:result, :isError)).to be true
      expect(rejected.dig(:result, :content, 0, :text)).to match(%r{Invalid arguments.*/value}m)
      expect(received.size).to eq(1)
    end
  end

  it 'advertises the same types through the mcp gem\'s own tools/list' do
    server = server_with({ tags: Array, opts: Hash, ids: :array, meta: :object })

    response = JSON.parse(server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list')),
                          symbolize_names: true)
    properties = response.dig(:result, :tools, 0, :inputSchema, :properties)

    expect(properties.transform_values { |property| property[:type] })
      .to eq(tags: 'array', opts: 'object', ids: 'array', meta: 'object')
    expect(server.list_tools.first.dig(:inputSchema, :properties)).to eq(properties)
  end

  it 'accepts an empty Array and an empty Hash' do
    received = []
    server = server_with({ tags: Array, opts: Hash }, received)

    response = call_tool(server, { tags: [], opts: {} })

    expect(response.dig(:result, :isError)).to be false
    expect(received).to eq([{ tags: [], opts: {} }])
  end

  # Everything else in a shorthand schema keeps its present meaning. What an
  # unrecognized value should do (warn, raise) is a separate decision; until
  # then it is advertised as a string, exactly as before.
  it 'leaves every other shorthand value as it was' do
    schema = { name: String, count: :integer, ratio: Float, flag: :boolean,
               typo: :interger, short: :bool, numeric: Numeric,
               list_of: [String], fragment: { type: 'array', items: { type: 'string' } } }

    types = server_with(schema).list_tools.first.dig(:inputSchema, :properties).transform_values { |p| p[:type] }

    expect(types).to eq(name: 'string', count: 'integer', ratio: 'number', flag: 'boolean',
                        typo: 'string', short: 'string', numeric: 'string',
                        list_of: 'string', fragment: 'string')
  end

  it 'still reads { type: :object } as a prebuilt schema, not as a parameter named type' do
    # :object is now a shorthand value too; a propertyless object schema has
    # always been detected first and must stay "accept any object".
    server = server_with({ type: :object })

    expect(server.list_tools.first[:inputSchema]).to eq({ type: 'object' })
    expect(call_tool(server, { anything: 1 }).dig(:result, :isError)).to be false
  end

  it 'declares an object parameter literally named type through the class form' do
    schema = server_with({ type: Hash, name: String }).list_tools.first[:inputSchema]

    expect(schema).to eq(type: 'object', required: %w[type name],
                         properties: { type: { type: 'object' }, name: { type: 'string' } })
  end
end
