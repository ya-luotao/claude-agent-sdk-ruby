# frozen_string_literal: true

require 'spec_helper'

# #[] reads attributes, and a name that is not one reads as nil
# (docs/types.md, "Attributes Only"). A setter-shaped name (`session_id=`)
# names a writer: #[] must not call it. On the write side,
# ClaudeAgentOptions accepts an option name only when it is an attribute or a
# setter user code defined, never a method such as #[]= or #==.
RSpec.describe 'setter-shaped and operator-shaped attribute names' do
  describe 'Type#[] with a setter-shaped name' do
    # A subclass of its own, so the per-class reader cache starts empty.
    let(:message_class) { Class.new(ClaudeAgentSDK::ResultMessage) }
    let(:message) { message_class.new(subtype: 'success', session_id: 's1') }

    it 'returns nil in every spelling and leaves the attribute alone' do
      [:session_id=, 'session_id=', :sessionId=, 'sessionId='].each do |name|
        expect(message[name]).to be_nil, "#[#{name.inspect}]"
      end

      expect(message.session_id).to eq('s1')
    end

    it 'never stores the name in the reader cache' do
      message[:session_id=]
      message['sessionId=']

      expect(message_class.cached_attribute_reader(:session_id=)).to be_nil
      expect(message_class.cached_attribute_reader('sessionId=')).to be_nil
    end

    # The camelCase writer (message.sessionId = ...) is resolved by
    # method_missing, which keeps what it resolved in the same cache.
    it 'returns nil after the camelCase writer has been called' do
      message.sessionId = 's2'

      expect(message[:sessionId=]).to be_nil
      expect(message.session_id).to eq('s2')
    end

    it 'returns nil for a hand-written setter and for a setter user code defined' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(fork_session: true, env: { 'A' => 'b' })
      custom = Class.new(ClaudeAgentSDK::ResultMessage) do
        def note=(value) # rubocop:disable Style/TrivialAccessors
          @note = value
        end
      end.new

      expect(options[:env=]).to be_nil
      expect(options['forkSession=']).to be_nil
      expect(ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash')['hooks=']).to be_nil
      expect(custom[:note=]).to be_nil
      expect(options.fork_session).to be(true)
      expect(options.env).to eq('A' => 'b')
    end

    it 'returns nil for a name that only ends in "=" once converted to a String',
       rbs_incompatible: 'passes a name that is neither a Symbol nor a String' do
      name = Class.new { def to_s = 'session_id=' }.new

      expect(message[name]).to be_nil
      expect(message.session_id).to eq('s1')
    end

    it 'still returns nil for the operators that end in "="' do
      %i[== != === []=].each { |name| expect(message[name]).to be_nil, "#[#{name.inspect}]" }
    end

    it 'still reads attributes and predicates' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(fork_session: true)

      expect([message[:session_id], message['sessionId']]).to eq(%w[s1 s1])
      expect([options[:fork_session], options[:fork_session?], options['forkSession?']]).to eq([true, true, true])
    end
  end

  describe 'ClaudeAgentOptions with an option name that resolves to a method of the SDK or of Ruby' do
    after { ClaudeAgentSDK.reset_configuration }

    it 'reports "[]" as an unknown option in the constructor' do
      expect { ClaudeAgentSDK::ClaudeAgentOptions.new('[]' => 1) }
        .to raise_error(ArgumentError, 'unknown ClaudeAgentOptions option: "[]"')
    end

    it 'reports it through #[]= and #dup_with too' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new

      expect { options['[]'] = 1 }.to raise_error(ArgumentError, 'unknown ClaudeAgentOptions option: "[]"')
      expect { options.dup_with('[]': 1) }.to raise_error(ArgumentError, 'unknown ClaudeAgentOptions option: :[]')
    end

    it 'reports the name as written when defaults are configured' do
      ClaudeAgentSDK.configure { |config| config.default_options = { model: 'sonnet' } }

      expect { ClaudeAgentSDK::ClaudeAgentOptions.new('[]' => 1) }
        .to raise_error(ArgumentError, 'unknown ClaudeAgentOptions option: "[]"')
    end

    # '=' + '=' is #==, '!' + '=' is #!=, '==' + '=' is #===: each used to be
    # called with the value, and the key was dropped without a word.
    it 'reports the names that resolve to a comparison operator' do
      ['=', '!', '=='].each do |name|
        expect { ClaudeAgentSDK::ClaudeAgentOptions.new(name => 1) }
          .to raise_error(ArgumentError, "unknown ClaudeAgentOptions option: #{name.inspect}")
      end
    end

    it 'still reports a misspelled option and a method that is not an option' do
      expect { ClaudeAgentSDK::ClaudeAgentOptions.new(modle: 'sonnet') }
        .to raise_error(ArgumentError, 'unknown ClaudeAgentOptions option: :modle')
      expect { ClaudeAgentSDK::ClaudeAgentOptions.new(dup_with: 1) }
        .to raise_error(ArgumentError, 'unknown ClaudeAgentOptions option: :dup_with')
    end

    it 'still accepts every declared option in any spelling' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new('permissionMode' => 'plan', forkSession: true, 'max-turns' => 3)
      options[:callbackScheduling] = 'inline'

      expect([options.permission_mode, options.fork_session, options.max_turns, options.callback_scheduling])
        .to eq(['plan', true, 3, :inline])
    end
  end

  # docs/types.md, "Attributes Only": methods user code adds to a subclass
  # (an attr_accessor, a hand-written setter, a mixin's accessors, a singleton
  # method) count as attributes.
  describe 'a ClaudeAgentOptions subclass with its own setters' do
    after { ClaudeAgentSDK.reset_configuration }

    let(:mixin) { Module.new { attr_accessor :team } }
    let(:labelled_options) do
      mod = mixin
      Class.new(ClaudeAgentSDK::ClaudeAgentOptions) do
        include mod

        attr_accessor :tenant

        def label=(value)
          @label = value.to_s
        end
      end
    end

    it 'accepts them in the constructor, in any spelling' do
      options = labelled_options.new(label: :nightly, 'tenant' => 'acme', team: 'infra', model: 'sonnet')

      expect(options.instance_variable_get(:@label)).to eq('nightly')
      expect([options.tenant, options.team, options.model]).to eq(%w[acme infra sonnet])
    end

    it 'accepts them through #[]= and #dup_with' do
      options = labelled_options.new
      options[:label] = 'weekly'
      copy = options.dup_with(tenant: 'acme', label: 'daily')

      expect(options.instance_variable_get(:@label)).to eq('weekly')
      expect([copy.tenant, copy.instance_variable_get(:@label)]).to eq(%w[acme daily])
    end

    it 'accepts them when defaults are configured' do
      ClaudeAgentSDK.configure { |config| config.default_options = { model: 'sonnet' } }
      options = labelled_options.new('label' => 'nightly', tenant: 'acme')

      expect([options.instance_variable_get(:@label), options.tenant, options.model]).to eq(%w[nightly acme sonnet])
    end

    it 'accepts a setter defined on the object itself' do
      options = labelled_options.new
      options.define_singleton_method(:trace_id=) { |value| @trace_id = value }
      options[:trace_id] = 'abc'

      expect(options.instance_variable_get(:@trace_id)).to eq('abc')
    end

    it 'still reports an unknown option and "[]"' do
      expect { labelled_options.new(lable: 'x') }
        .to raise_error(ArgumentError, 'unknown ClaudeAgentOptions option: :lable')
      expect { labelled_options.new('[]' => 1) }
        .to raise_error(ArgumentError, 'unknown ClaudeAgentOptions option: "[]"')
    end
  end
end
