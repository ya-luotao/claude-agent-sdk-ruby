# frozen_string_literal: true

require 'spec_helper'

# Strict attributes are documented as inherited (Type.strict_attributes): a
# subclass of a type the user builds — HookMatcher here — rejects a key it
# does not know, as the type itself does, and still accepts one that names a
# reader the subclass defines. strict_attributes_spec.rb covers the SDK's
# own classes; nothing covered a subclass.
RSpec.describe ClaudeAgentSDK::Type do
  describe 'strict attributes on a subclass of a strict type' do
    it 'raises for an unknown key, as the parent type does' do
      subclass = Class.new(ClaudeAgentSDK::HookMatcher)

      expect { subclass.new(matchr: 'Bash') }.to raise_error(ArgumentError, /unknown attribute :matchr/)
      expect(subclass.new(matcher: 'Bash').matcher).to eq('Bash')
    end

    it 'accepts a key that names a reader the subclass defines' do
      subclass = Class.new(ClaudeAgentSDK::HookMatcher) do
        def note
          'defined by the subclass'
        end
      end

      expect { subclass.new(matcher: 'Bash', note: 'x') }.not_to raise_error
      expect { subclass.new(notes: 'x') }.to raise_error(ArgumentError, /unknown attribute :notes/)
    end
  end
end
