# frozen_string_literal: true

require 'spec_helper'

# docs/ is part of the SemVer contract (public API = docs/ plus the YARD docs
# without `@api private`), so the reference pages have to name what the code
# defines. The checks run from the code to the page: a class the SDK can hand
# to a consumer must be in the reference. Prose is not scanned for names; the
# only page-to-code check is on table rows that start with a constant name.
RSpec.describe 'the type and error references' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:types_doc) { File.read(File.join(root, 'docs/types.md')) }
  let(:errors_doc) { File.read(File.join(root, 'docs/errors.md')) }

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

  it 'names every message and content-block class the parser can produce in docs/types.md' do
    missing = produced_classes.map { |klass| short_name(klass) }.reject { |name| types_doc.match?(/\b#{name}\b/) }

    expect(produced_classes.size).to be >= 36
    expect(missing).to be_empty, "docs/types.md does not mention: #{missing.sort.join(', ')}"
  end

  it 'lists every top-level message class in the Message union of docs/types.md' do
    top_level = message_classes.reject { |klass| klass < ClaudeAgentSDK::SystemMessage }

    expect(documented_union('Message')).to match_array(top_level.map { |klass| short_name(klass) })
  end

  it 'lists every content-block class in the ContentBlock union of docs/types.md' do
    expect(documented_union('ContentBlock')).to match_array(block_classes.map { |klass| short_name(klass) })
  end

  it 'starts the table rows of docs/types.md only with classes and constants that exist' do
    names = types_doc.scan(/^\| `([A-Z]\w+)` \|/).flatten
    unknown = names.reject { |name| ClaudeAgentSDK.const_defined?(name) }

    expect(names).not_to be_empty
    expect(unknown).to be_empty, "docs/types.md lists names ClaudeAgentSDK does not define: #{unknown.join(', ')}"
  end

  it 'has a reference entry and a table row in docs/errors.md for every error class' do
    errors = sdk_classes.select { |klass| klass <= ClaudeAgentSDK::ClaudeSDKError }.map { |klass| short_name(klass) }
    without_entry = errors.reject { |name| errors_doc.match?(/^class #{name}\b/) }
    without_row = errors.reject { |name| errors_doc.match?(/^\| `#{name}` \|/) }

    expect(errors).to include('ClaudeSDKError', 'ProcessError', 'ResultError')
    expect(without_entry).to be_empty, "docs/errors.md has no reference entry for: #{without_entry.join(', ')}"
    expect(without_row).to be_empty, "docs/errors.md has no table row for: #{without_row.join(', ')}"
  end

  # docs/types.md: SystemMessage#data is the whole frame, unless the frame
  # carries a `data` value of its own that is neither nil nor false (the class
  # assigns it with `||=`, so key presence alone does not decide).
  it 'parses #data of a system frame the way docs/types.md describes it' do
    frame = { type: 'system', subtype: 'status', uuid: 'u1', session_id: 's1', status: 'compacting' }
    data_of = ->(extra) { ClaudeAgentSDK::MessageParser.parse(frame.merge(extra)).data }

    expect(data_of.call({})).to eq(frame)
    expect(data_of.call(data: { marker: 1 })).to eq(marker: 1)
    expect(data_of.call(data: {})).to eq({})
    expect(data_of.call(data: nil)).to eq(frame.merge(data: nil))
    prose = types_doc.gsub(/\s+/, ' ') # the sentences may wrap anywhere
    expect(prose).to include('unless the frame carries a `data` value of its own that is neither `nil` nor `false`')
    expect(prose).to include('A frame whose `data` is `nil` or `false` reads like one without the key')
    expect(types_doc).to include("the frame's own `data` value when that is neither nil nor false, otherwise the whole frame")
  end

  it 'parses a system frame whose data is false like one without the key, as docs/types.md says',
     rbs_incompatible: 'parses a frame whose data is false, outside the signature of SystemMessage#data=' do
    frame = { type: 'system', subtype: 'status', uuid: 'u1', session_id: 's1', status: 'compacting', data: false }

    expect(ClaudeAgentSDK::MessageParser.parse(frame).data).to eq(frame)
  end

  # docs/types.md: RateLimitEvent#data is always the whole event, whether or
  # not the event has a `data` key.
  it 'parses #data of a rate-limit event the way docs/types.md describes it' do
    event = { type: 'rate_limit_event', uuid: 'rl_123', session_id: 'sess_456',
              rate_limit_info: { status: 'allowed_warning', resetsAt: 1_700_000_000, rateLimitType: 'five_hour' } }
    with_data = event.merge(data: { marker: 1 })

    expect(ClaudeAgentSDK::MessageParser.parse(event).data).to eq(event)
    expect(ClaudeAgentSDK::MessageParser.parse(with_data).data).to eq(with_data)
    expect(types_doc.gsub(/\s+/, ' ')).to include('`RateLimitEvent#data` is always the whole event')
  end

  # The example announces how many message types it handles; both the number
  # and the `when` branches are checked against the classes.
  it 'handles every typed message class in examples/message_types_example.rb, and counts them' do
    example = File.read(File.join(root, 'examples/message_types_example.rb'))
    typed = message_classes.map { |klass| short_name(klass) } - ['SystemMessage']
    handled = example.scan(/^\s*when ClaudeAgentSDK::(\w+)\s*$/).flatten

    expect(typed - handled).to eq([])
    expect(example[/Handling all (\d+) SDK message types/, 1]).to eq(typed.size.to_s)
  end
end
