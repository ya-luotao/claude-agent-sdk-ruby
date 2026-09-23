# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

# Issue #126: Type#[], #[]= and the camelCase readers are public API, limited
# to declared attributes. Through 0.x a name that resolves to some other
# public method (msg[:to_h], msg['freeze'], msg.toH) still works but warns
# once per class and name; from 1.0 (Type::ENFORCE_ATTRIBUTES) it is treated
# as undefined.
RSpec.describe 'Type attribute access' do
  before { ClaudeAgentSDK::Deprecation.reset! }
  after { ClaudeAgentSDK::Deprecation.reset! }

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
      it 'declares every public reader and writer as an attribute, apart from the listed methods' do
        undeclared = klass.public_instance_methods.select do |method_name|
          owner = klass.instance_method(method_name).owner
          next false unless owner.is_a?(Class) && owner < ClaudeAgentSDK::Type
          next false if type_own_methods.include?(method_name)

          !klass.attribute?(method_name.to_s.delete_suffix('=').delete_suffix('?'))
        end

        expect(undeclared).to match_array(non_attribute_methods.fetch(klass.name, []))
      end

      it 'reaches every attribute through #[], #[]= and camelCase without a warning' do
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

  describe 'a name that is not an attribute (0.x)' do
    let(:message) { ClaudeAgentSDK::ResultMessage.new(subtype: 'success', session_id: 's1') }

    it 'still reads it through #[] but warns once per class and name at the caller' do
      first = capture_stderr { expect(message[:to_h]).to be_a(Hash) }
      again = capture_stderr { message['to_h'] }

      expect(first).to eq("#{__FILE__}:#{__LINE__ - 3}: warning: ClaudeAgentSDK::ResultMessage#[]: :to_h is not an " \
                          "attribute; Type#[] will only read attributes in 1.0\n")
      expect(again).to eq('')
    end

    it 'reports each name separately' do
      output = capture_stderr do
        expect(message['class']).to eq(ClaudeAgentSDK::ResultMessage)
        message[:to_s]
      end

      expect(output.lines.size).to eq(2)
      expect(output).to include('#[]: "class" is not an attribute')
    end

    it 'still calls it through a camelCase name, with a warning' do
      expect(message).to respond_to(:toH)
      output = capture_stderr { expect(message.toH).to be_a(Hash) }

      expect(output).to include('ClaudeAgentSDK::ResultMessage#toH: to_h is not an attribute; ' \
                                'camelCase methods will only reach attributes in 1.0')
    end

    it 'still writes through a public non-attribute setter, with a warning' do
      klass = Class.new(ClaudeAgentSDK::Type) do
        attr_reader :hidden

        def hidden=(value) # rubocop:disable Style/TrivialAccessors
          @hidden = value
        end
      end
      # attr_reader declared `hidden` itself; drop it to model a writer that
      # is not an attribute.
      klass.send(:own_attribute_names).clear
      instance = klass.new
      output = capture_stderr { instance[:hidden] = 1 }

      expect(instance.instance_variable_get(:@hidden)).to eq(1)
      expect(output).to include('#[]=: :hidden is not an attribute; Type#[]= and .new will only write attributes in 1.0')
    end

    it 'keeps undefined names silent: nil from #[], a no-op #[]=, NoMethodError from camelCase' do
      output = capture_stderr do
        expect(message[:nope]).to be_nil
        message[:nope] = 1
        expect { message.noSuchThing }.to raise_error(NoMethodError)
      end

      expect(output).to eq('')
    end

    it 'keeps camelCase attribute readers and predicates silent' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(fork_session: true)
      output = capture_stderr do
        expect(message.sessionId).to eq('s1')
        expect(options.forkSession?).to be(true)
        expect(options[:forkSession]).to be(true)
      end

      expect(output).to eq('')
    end
  end

  context 'when the 1.0 switch is flipped' do
    before { stub_const('ClaudeAgentSDK::Type::ENFORCE_ATTRIBUTES', true) }

    let(:message) { ClaudeAgentSDK::ResultMessage.new(subtype: 'success', session_id: 's1') }

    it 'treats a non-attribute method as undefined' do
      output = capture_stderr do
        expect(message[:to_h]).to be_nil
        expect(message['freeze']).to be_nil
        expect(message).not_to be_frozen
        expect(message).not_to respond_to(:toH)
        expect { message.toH }.to raise_error(NoMethodError)
      end

      expect(output).to eq('')
    end

    it 'still reaches attributes in every spelling' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(fork_session: true)
      message[:sessionId] = 's2'

      expect([message.session_id, message['session_id'], message.sessionId]).to eq(%w[s2 s2 s2])
      expect(options.forkSession?).to be(true)
    end
  end
end
