# frozen_string_literal: true

require 'spec_helper'

# docs/options.md is the reference for ClaudeAgentOptions. An option that is
# not on the page is public API a reader of the docs cannot discover, so every
# public attribute has to be named there.
RSpec.describe 'docs/options.md' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:page_path) { File.join(root, 'docs/options.md') }
  let(:page) { File.exist?(page_path) ? File.read(page_path) : '' }

  # Attributes whose declaration carries a YARD `@api private` tag are not
  # public API (CONTRIBUTING.md, "What is public API") and need no entry.
  def private_attributes(source)
    declaration = /((?:^[ \t]*#.*\n)+)[ \t]*attr_(?:accessor|reader|writer)[ \t]+((?::\w+,?\s*)+)/
    source.scan(declaration).flat_map do |comment, names|
      comment.match?(/^\s*#\s*@api private\s*$/) ? names.scan(/:(\w+)/).flatten : []
    end
  end

  def public_attributes
    source = File.read(File.join(root, 'lib/claude_agent_sdk/types/options.rb'))
    ClaudeAgentSDK::ClaudeAgentOptions.attribute_names - private_attributes(source)
  end

  it 'names every public ClaudeAgentOptions attribute' do
    missing = public_attributes.reject { |name| page.include?("`#{name}`") }

    expect(public_attributes.size).to be >= 55
    expect(missing).to be_empty, "docs/options.md does not mention: #{missing.join(', ')}"
  end

  it 'recognizes an attribute tagged @api private as not needing an entry' do
    source = <<~RUBY
      class ClaudeAgentOptions < Type
        attr_accessor :model, :cwd

        # Where the transport keeps its scratch files.
        #
        # @api private
        attr_accessor :scratch_dir,
                      :scratch_mode

        # Deliver every prompt as written.
        attr_reader :verbatim_prompts
      end
    RUBY

    expect(private_attributes(source)).to eq(%w[scratch_dir scratch_mode])
  end

  it 'is linked from the README documentation table' do
    readme = File.read(File.join(root, 'README.md'))

    expect(readme).to match(%r{\]\([^)]*docs/options\.md\)})
  end
end
