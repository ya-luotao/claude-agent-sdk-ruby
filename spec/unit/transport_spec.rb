# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::Transport do
  # The abstract base pins the six-method transport contract: every method is a
  # stub that raises NotImplementedError until a concrete subclass overrides it.
  describe 'abstract base class' do
    let(:abstract_transport) { described_class.new }

    it 'raises NotImplementedError for connect' do
      expect { abstract_transport.connect }
        .to raise_error(NotImplementedError, /implement #connect/)
    end

    it 'raises NotImplementedError for write' do
      expect { abstract_transport.write('data') }
        .to raise_error(NotImplementedError, /implement #write/)
    end

    it 'raises NotImplementedError for read_messages' do
      expect { abstract_transport.read_messages }
        .to raise_error(NotImplementedError, /implement #read_messages/)
    end

    it 'raises NotImplementedError for close' do
      expect { abstract_transport.close }
        .to raise_error(NotImplementedError, /implement #close/)
    end

    it 'raises NotImplementedError for ready?' do
      expect { abstract_transport.ready? }
        .to raise_error(NotImplementedError, /implement #ready/)
    end

    it 'raises NotImplementedError for end_input' do
      expect { abstract_transport.end_input }
        .to raise_error(NotImplementedError, /implement #end_input/)
    end
  end

  # The shipped transport must satisfy the same contract. These assertions bite
  # if lib/ regresses: dropping an override would make a live transport inherit
  # the abstract stub and raise NotImplementedError mid-session.
  describe 'SubprocessCLITransport conformance' do
    let(:concrete_class) { ClaudeAgentSDK::SubprocessCLITransport }

    it 'subclasses the abstract Transport' do
      expect(concrete_class.ancestors).to include(described_class)
    end

    %i[connect write read_messages close ready? end_input].each do |method_name|
      it "overrides ##{method_name} rather than inheriting the abstract stub" do
        owner = concrete_class.instance_method(method_name).owner
        expect(owner).to eq(concrete_class)
      end
    end
  end
end
