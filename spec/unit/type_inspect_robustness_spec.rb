# frozen_string_literal: true

require 'spec_helper'

# Type#inspect runs inside loggers, `puts` and exception messages, so it must
# not raise, whatever an attribute holds. A value that fails while it is
# rendered shows as a placeholder and the rest of the object still prints.
RSpec.describe 'Type#inspect on a value it cannot render',
               rbs_incompatible: 'plants values outside the attribute types' do
  def hostile(name, base, &body)
    stub_const(name, Class.new(base, &body))
  end

  describe 'an attribute that is a BasicObject' do
    it 'renders a placeholder next to the other attributes' do
      block = ClaudeAgentSDK::ToolUseBlock.new(id: 'toolu_1', input: BasicObject.new)

      expect(block.inspect).to eq('#<ClaudeAgentSDK::ToolUseBlock id="toolu_1" input=#<?>>')
      expect(block.to_s).to eq(block.inspect)
    end

    # A BasicObject has no #hash, so only an identity Hash can be keyed by one.
    it 'renders a BasicObject Hash key and keeps the rest of the Hash' do
      input = {}.compare_by_identity
      input[BasicObject.new] = 1
      input[:path] = '/tmp'
      block = ClaudeAgentSDK::ToolUseBlock.new(input: input)

      expect(block.inspect).to eq('#<ClaudeAgentSDK::ToolUseBlock input={#<?> => 1, path: "/tmp"}>')
    end

    it 'prints a filtered attribute as filtered' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new
      options.env = BasicObject.new
      options.settings = BasicObject.new
      config = ClaudeAgentSDK::McpHttpServerConfig.new
      config.url = BasicObject.new

      expect(options.inspect).to include(' env="[FILTERED]"').and include(' settings="[FILTERED]"')
      expect(config.inspect).to eq('#<ClaudeAgentSDK::McpHttpServerConfig type="http" url="[FILTERED]">')
    end

    it 'prints mcp_servers as filtered when a server config cannot be read' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new
      oddly_keyed = {}.compare_by_identity
      oddly_keyed[BasicObject.new] = 'x'
      rendered = [BasicObject.new, { api: BasicObject.new }, { api: oddly_keyed }].map do |servers|
        options.mcp_servers = servers
        options.inspect[/ mcp_servers=\S+/]
      end

      expect(rendered).to all(eq(' mcp_servers="[FILTERED]"'))
    end
  end

  describe 'a String whose own methods raise' do
    it 'renders a placeholder when #length raises' do
      hostile('LengthlessString', String) { def length = raise('len') }
      block = ClaudeAgentSDK::TextBlock.new(text: LengthlessString.new('x'))

      expect(block.inspect).to eq('#<ClaudeAgentSDK::TextBlock text=#<LengthlessString>>')
    end

    it 'renders a placeholder when #inspect or #[] raises' do
      hostile('UninspectableString', String) { def inspect = raise('inspect') }
      hostile('UnsliceableString', String) { def [](*) = raise('slice') }
      message = ClaudeAgentSDK::ResultMessage.new(
        subtype: UninspectableString.new('success'), result: UnsliceableString.new('a' * 200), num_turns: 3
      )

      expect(message.inspect).to eq('#<ClaudeAgentSDK::ResultMessage subtype=#<UninspectableString> ' \
                                    'result=#<UnsliceableString> num_turns=3>')
    end

    it 'renders a placeholder when #length answers something that is not a number' do
      hostile('OddString', String) { def length = nil }

      expect(ClaudeAgentSDK::TextBlock.new(text: OddString.new('x')).inspect)
        .to eq('#<ClaudeAgentSDK::TextBlock text=#<OddString>>')
    end

    it 'replaces only that value inside a container' do
      hostile('LengthlessString', String) { def length = raise('len') }
      block = ClaudeAgentSDK::ToolUseBlock.new(input: { command: LengthlessString.new('ls'), cwd: '/tmp' })

      expect(block.inspect).to eq('#<ClaudeAgentSDK::ToolUseBlock input={command: #<LengthlessString>, cwd: "/tmp"}>')
    end
  end

  describe 'a container whose own methods raise' do
    it 'renders a placeholder for the container' do
      hostile('SizelessHash', Hash) { def size = raise('size') }
      hostile('BottomlessArray', Array) { def first(*) = raise('first') }
      hostile('EmptinessUnknownArray', Array) { def empty? = raise('empty?') }
      message = ClaudeAgentSDK::AssistantMessage.new(
        content: BottomlessArray.new([1, 2]), usage: SizelessHash[(1..6).to_h { |i| [:"k#{i}", i] }],
        model: 'claude-opus-5', error: EmptinessUnknownArray.new
      )

      expect(message.inspect).to eq('#<ClaudeAgentSDK::AssistantMessage content=#<BottomlessArray> ' \
                                    'usage=#<SizelessHash> model="claude-opus-5" error=#<EmptinessUnknownArray>>')
    end
  end

  describe 'a nested Type that cannot list its attributes' do
    it 'renders a placeholder for it, also when it is the object being inspected' do
      hostile('BrokenBlock', ClaudeAgentSDK::TextBlock) do
        private

        def inspect_attributes = raise('attributes')
      end
      broken = BrokenBlock.new(text: 'x')
      message = ClaudeAgentSDK::AssistantMessage.new(content: [ClaudeAgentSDK::TextBlock.new(text: 'ok'), broken])

      expect(message.inspect)
        .to eq('#<ClaudeAgentSDK::AssistantMessage content=[#<ClaudeAgentSDK::TextBlock text="ok">, #<BrokenBlock>]>')
      expect(broken.inspect).to eq('#<BrokenBlock>')
    end
  end

  it 'keeps the placeholder bounded' do
    long_named = hostile("Lengthless#{'Very' * 40}LongName", String) { def length = raise('len') }
    block = ClaudeAgentSDK::TextBlock.new(text: long_named.new('x'))

    expect(block.inspect).to eq("#<ClaudeAgentSDK::TextBlock text=#<Lengthless#{'Very' * 17}…(+101 chars)>")
  end

  it 'lets process-control exceptions through' do
    hostile('InterruptingString', String) { def length = raise(Interrupt) }
    hostile('ExitingString', String) { def length = exit(3) }

    expect { ClaudeAgentSDK::TextBlock.new(text: InterruptingString.new('x')).inspect }.to raise_error(Interrupt)
    expect { ClaudeAgentSDK::TextBlock.new(text: ExitingString.new('x')).inspect }.to raise_error(SystemExit)
  end
end
