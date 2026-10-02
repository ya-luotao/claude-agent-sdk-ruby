# frozen_string_literal: true

require 'spec_helper'

# docs/ is part of the SemVer contract (public API = docs/ plus the YARD docs
# without `@api private`), so the reference pages have to name what the code
# defines. The checks run from the code to the page: a class the SDK can hand
# to a consumer must be in the reference. Prose is not scanned for names; the
# only page-to-code check is on table rows that start with a constant name.
RSpec.describe 'docs/types.md' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:types_doc) { File.read(File.join(root, 'docs/types.md')) }

  def short_name(klass)
    klass.name.split('::').last
  end

  def sdk_classes
    ClaudeAgentSDK.constants.map { |name| ClaudeAgentSDK.const_get(name) }.grep(Class)
  end

  # Every class the message parser can hand to a consumer: the Type subclasses
  # message_parser.rb names (its system-subtype table included), plus every
  # Type subclass called *Message / *Block, so the list cannot shrink
  # unnoticed if the dispatch moves out of that file.
  def produced_classes
    parser_source = File.read(File.join(root, 'lib/claude_agent_sdk/message_parser.rb'))
    sdk_classes.select do |klass|
      next false unless klass < ClaudeAgentSDK::Type

      name = short_name(klass)
      name.end_with?('Message', 'Block') || parser_source.match?(/\b#{name}\b/)
    end
  end

  def block_classes
    produced_classes.select { |klass| short_name(klass).end_with?('Block') }
  end

  def message_classes
    produced_classes - block_classes
  end

  # The members of a `Name = A | B | ...` union inside a fenced block.
  def documented_union(name)
    types_doc[/^#{name} = (.*?)^```/m, 1].to_s.scan(/[A-Z]\w+/)
  end

  it 'names every message and content-block class the parser can produce' do
    missing = produced_classes.map { |klass| short_name(klass) }.reject { |name| types_doc.match?(/\b#{name}\b/) }

    expect(produced_classes.size).to be >= 36
    expect(missing).to be_empty, "docs/types.md does not mention: #{missing.sort.join(', ')}"
  end

  it 'lists every top-level message class in the Message union' do
    top_level = message_classes.reject { |klass| klass < ClaudeAgentSDK::SystemMessage }

    expect(documented_union('Message')).to match_array(top_level.map { |klass| short_name(klass) })
  end

  it 'lists every content-block class in the ContentBlock union' do
    expect(documented_union('ContentBlock')).to match_array(block_classes.map { |klass| short_name(klass) })
  end

  it 'starts its table rows only with classes and constants that exist' do
    names = types_doc.scan(/^\| `([A-Z]\w+)` \|/).flatten
    unknown = names.reject { |name| ClaudeAgentSDK.const_defined?(name) }

    expect(names).not_to be_empty
    expect(unknown).to be_empty, "docs/types.md lists names ClaudeAgentSDK does not define: #{unknown.join(', ')}"
  end
end
