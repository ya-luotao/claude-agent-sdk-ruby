# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

# Issue #126: Type#[], #[]= and the camelCase readers are public API, limited
# to declared attributes. A name that resolves to some other public method
# (msg[:to_h], msg['freeze'], msg.toH) is treated as undefined, silently, as
# of 1.0 (0.37 still reached it, with a warning).
RSpec.describe 'Type attribute access' do
  def capture_stderr
    captured = +''
    original = $stderr
    $stderr = StringIO.new(captured)
    begin
      yield
    ensure
      $stderr = original
    end
    captured
  end

  def camelize(name)
    name.gsub(/_([a-z\d])/) { Regexp.last_match(1).upcase }
  end

  # Class#descendants is not in Ruby 3.2/3.3.
  subclasses_of = ->(klass) { klass.subclasses.flat_map { |sub| [sub, *subclasses_of.call(sub)] } }
  types = subclasses_of.call(ClaudeAgentSDK::Type).select { |k| k.name&.start_with?('ClaudeAgentSDK::') }.uniq

  # Public methods of SDK types that are deliberately NOT attributes. A new
  # hand-written reader must either be declared (Type.declare_attributes) or
  # be listed here.
  non_attribute_methods = {
    'ClaudeAgentSDK::UserMessage' => %i[text],
    'ClaudeAgentSDK::AssistantMessage' => %i[text],
    'ClaudeAgentSDK::ClaudeAgentOptions' => %i[dup_with]
  }.freeze
  type_own_methods = ClaudeAgentSDK::Type.public_instance_methods(false)

  it 'finds the SDK types' do
    expect(types).to include(ClaudeAgentSDK::ResultMessage, ClaudeAgentSDK::InitMessage, ClaudeAgentSDK::HookMatcher)
  end

  types.each do |klass|
    describe klass.name do
      it 'declares every public reader and writer as an attribute, apart from the listed methods',
         rbs_incompatible: "enumerates public methods, which include the checker's wrapper aliases" do
        undeclared = klass.public_instance_methods.select do |method_name|
          owner = klass.instance_method(method_name).owner
          next false unless owner.is_a?(Class) && owner < ClaudeAgentSDK::Type
          next false if type_own_methods.include?(method_name)

          !klass.attribute?(method_name.to_s.delete_suffix('=').delete_suffix('?'))
        end

        expect(undeclared).to match_array(non_attribute_methods.fetch(klass.name, []))
      end

      it 'reaches every attribute through #[], #[]= and camelCase without a warning',
         rbs_incompatible: 'plants Object.new sentinels in every attribute' do
        instance = klass.new
        output = capture_stderr do
          klass.attribute_names.each do |name|
            camel = camelize(name)
            if instance.respond_to?(name)
              # A sentinel where the reader returns its ivar; a derived reader
              # (RateLimitEvent#data) ignores it and is compared by value.
              instance.instance_variable_set(:"@#{name}", Object.new)
              expected = instance.public_send(name)
              [name.to_sym, name, camel.to_sym, camel].each do |key|
                expect(instance[key]).to eq(expected), "#{klass}#[#{key.inspect}]"
              end
              expect(instance.public_send(camel)).to eq(expected) if camel != name
            end
            next unless instance.respond_to?(:"#{name}=")

            value = Object.new
            expect(instance).to receive(:"#{name}=").with(value).twice
            instance[camel.to_sym] = value
            instance[name] = value
          end
        end

        expect(output).to eq('')
      end
    end
  end

  describe 'a name that is not an attribute' do
    let(:message) { ClaudeAgentSDK::ResultMessage.new(subtype: 'success', session_id: 's1') }

    it 'reads nil through #[] without calling the method' do
      output = capture_stderr do
        expect(message[:to_h]).to be_nil
        expect(message['to_h']).to be_nil
        expect(message['class']).to be_nil
        expect(message['freeze']).to be_nil
      end

      expect(message).not_to be_frozen
      expect(output).to eq('')
    end

    it 'raises NoMethodError from a camelCase name and does not respond to it' do
      expect(message).not_to respond_to(:toH)
      expect { message.toH }.to raise_error(NoMethodError)
    end

    it 'ignores #[]= through a public non-attribute setter the SDK defines' do
      # A hand-written setter with no attr_* declaration, on a class in the
      # SDK namespace (an SDK type forgetting to declare an attribute).
      stub_const('ClaudeAgentSDK::SpecUndeclaredSetter', Class.new(ClaudeAgentSDK::Type) do
        def hidden=(value) # rubocop:disable Style/TrivialAccessors
          @hidden = value
        end
      end)
      instance = ClaudeAgentSDK::SpecUndeclaredSetter.new
      output = capture_stderr { instance[:hidden] = 1 }

      expect(instance.instance_variable_get(:@hidden)).to be_nil
      expect(output).to eq('')
    end

    it 'treats UserMessage#text and AssistantMessage#text as convenience methods, not attributes' do
      expect(ClaudeAgentSDK::AssistantMessage.new(content: [])[:text]).to be_nil
      expect(ClaudeAgentSDK::UserMessage.new(content: 'hi')[:text]).to be_nil
    end

    it 'keeps undefined names silent: nil from #[], a no-op #[]=, NoMethodError from camelCase' do
      output = capture_stderr do
        expect(message[:nope]).to be_nil
        message[:nope] = 1
        expect { message.noSuchThing }.to raise_error(NoMethodError)
      end

      expect(output).to eq('')
    end

    it 'still reaches attributes and predicates in every spelling, silently' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(fork_session: true)
      output = capture_stderr do
        message[:sessionId] = 's2'
        expect([message.session_id, message['session_id'], message.sessionId]).to eq(%w[s2 s2 s2])
        expect(options.forkSession?).to be(true)
        expect(options[:forkSession]).to be(true)
      end

      expect(output).to eq('')
    end
  end

  # User code extending an SDK type: its own methods are attributes, however
  # they were defined.
  shared_examples 'user-defined methods are attributes' do
    let(:mixin) { Module.new { attr_accessor :mixed_value } }
    let(:custom_matcher) do
      mod = mixin
      Class.new(ClaudeAgentSDK::HookMatcher) do
        include mod

        def custom=(value) # rubocop:disable Style/TrivialAccessors
          @custom = value
        end
      end
    end
    let(:scored_result) do
      Class.new(ClaudeAgentSDK::ResultMessage) do
        def score = 1
      end
    end

    it 'accepts a hand-written setter and a mixin accessor on a strict subclass' do
      matcher = nil
      output = capture_stderr { matcher = custom_matcher.new(matcher: 'Bash', custom: 2, mixedValue: 3) }

      expect(output).to eq('')
      expect(matcher.instance_variable_get(:@custom)).to eq(2)
      expect([matcher.mixed_value, matcher[:mixed_value], matcher.mixedValue]).to eq([3, 3, 3])
    end

    it 'reads a hand-written reader and a singleton method through #[]' do
      result = scored_result.new(session_id: 's')
      result.define_singleton_method(:extra) { 5 }
      output = capture_stderr do
        expect(result[:score]).to eq(1)
        expect(result['extra']).to eq(5)
        expect(result[:session_id]).to eq('s')
      end

      expect(output).to eq('')
    end
  end

  describe 'user extensions' do
    include_examples 'user-defined methods are attributes'

    it 'still gates methods defined by the SDK and Ruby on a user subclass' do
      result = scored_result.new
      expect(result[:to_h]).to be_nil
      expect(result[:freeze]).to be_nil
      expect(result).not_to be_frozen
      expect(result).not_to respond_to(:toH)
    end
  end
end
