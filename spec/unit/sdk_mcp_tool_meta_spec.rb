# frozen_string_literal: true

require 'spec_helper'
require 'json'

# create_tool forwards annotations[:maxResultSizeChars] to the CLI as
# _meta['anthropic/maxResultSizeChars'] (MCP clients drop the annotation
# itself). It only did so when no meta: was passed: any explicit meta:, even
# one about something else, replaced the size hint.
RSpec.describe ClaudeAgentSDK, '.create_tool _meta from annotations and meta:' do
  size_key = 'anthropic/maxResultSizeChars'

  def tool_with(**options)
    described_class.create_tool('export_rows', 'Export rows', {}, **options) { |_args| 'rows' }
  end

  def advertised_meta(tool)
    described_class::SdkMcpServer.new(name: 'reports', tools: [tool]).list_tools.first[:_meta]
  end

  it 'derives the size hint from the annotation when no meta: is given' do
    tool = tool_with(annotations: { maxResultSizeChars: 500_000 })

    expect(tool.meta).to eq(size_key => 500_000)
  end

  it 'merges an unrelated meta: with the derived size hint instead of dropping it' do
    tool = tool_with(annotations: { maxResultSizeChars: 500_000 }, meta: { 'acme/team' => 'billing' })

    expect(tool.meta).to eq(size_key => 500_000, 'acme/team' => 'billing')
    expect(advertised_meta(tool)).to eq(size_key => 500_000, 'acme/team' => 'billing')
  end

  it 'advertises both keys through the mcp gem\'s tools/list too' do
    tool = tool_with(annotations: { maxResultSizeChars: 500_000 }, meta: { 'acme/team' => 'billing' })
    server = described_class::SdkMcpServer.new(name: 'reports', tools: [tool])

    listed = JSON.parse(server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list')))

    expect(listed.dig('result', 'tools', 0, '_meta')).to eq(size_key => 500_000, 'acme/team' => 'billing')
  end

  it 'reads the annotation under a String key as well' do
    tool = tool_with(annotations: { 'maxResultSizeChars' => 500_000 }, meta: { 'acme/team' => 'billing' })

    expect(tool.meta).to eq(size_key => 500_000, 'acme/team' => 'billing')
  end

  it 'lets a size key set in meta: win over the annotation' do
    tool = tool_with(annotations: { maxResultSizeChars: 500_000 }, meta: { size_key => 100, 'acme/team' => 'billing' })

    expect(tool.meta).to eq(size_key => 100, 'acme/team' => 'billing')
  end

  it 'lets a Symbol-keyed size key in meta: win, without a second spelling of the key' do
    tool = tool_with(annotations: { maxResultSizeChars: 500_000 }, meta: { size_key.to_sym => 100 })

    expect(tool.meta).to eq(size_key.to_sym => 100)
    # Counted in the serialized frame: two spellings of one key are a
    # duplicate JSON key, which json 3.x refuses to generate.
    expect(JSON.generate(advertised_meta(tool)).scan(size_key).size).to eq(1)
  end

  it 'does not modify the Hash passed as meta:' do
    meta = { 'acme/team' => 'billing' }.freeze

    tool = tool_with(annotations: { maxResultSizeChars: 500_000 }, meta: meta)

    expect(meta).to eq('acme/team' => 'billing')
    expect(tool.meta).not_to equal(meta)
  end

  it 'passes meta: through untouched when the annotations carry no size' do
    meta = { 'acme/team' => 'billing' }

    expect(tool_with(annotations: { readOnlyHint: true }, meta: meta).meta).to equal(meta)
    expect(tool_with(meta: meta).meta).to equal(meta)
  end

  it 'leaves _meta out when there is neither a size annotation nor meta:' do
    expect(tool_with(annotations: { readOnlyHint: true }).meta).to be_nil
    expect(tool_with.meta).to be_nil
    expect(described_class::SdkMcpServer.new(name: 'reports', tools: [tool_with]).list_tools.first).not_to have_key(:_meta)
  end
end
