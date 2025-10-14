# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::Transport do
  # Create a test implementation
  let(:test_transport_class) do
    Class.new(described_class) do
      attr_accessor :connected, :messages, :written_data

      def initialize
        @connected = false
        @messages = []
        @written_data = []
      end

      def connect
        @connected = true
      end

      def write(data)
        @written_data << data
      end

      def read_messages(&block)
        @messages.each { |msg| block.call(msg) }
      end

      def close
        @connected = false
      end

      def ready?
        @connected
      end

      def end_input
        # No-op for test
      end
    end
  end

  let(:transport) { test_transport_class.new }

  describe 'interface requirements' do
    it 'requires connect to be implemented' do
      expect(transport).to respond_to(:connect)
    end

    it 'requires write to be implemented' do
      expect(transport).to respond_to(:write)
    end

    it 'requires read_messages to be implemented' do
      expect(transport).to respond_to(:read_messages)
    end

    it 'requires close to be implemented' do
      expect(transport).to respond_to(:close)
    end

    it 'requires ready? to be implemented' do
      expect(transport).to respond_to(:ready?)
    end

    it 'requires end_input to be implemented' do
      expect(transport).to respond_to(:end_input)
    end
  end

  describe 'test implementation' do
    it 'connects successfully' do
      expect(transport.ready?).to eq(false)
      transport.connect
      expect(transport.ready?).to eq(true)
    end

    it 'writes data' do
      transport.write('test data')
      expect(transport.written_data).to eq(['test data'])
    end

    it 'reads messages with block' do
      transport.messages = [{ type: 'test1' }, { type: 'test2' }]

      received = []
      transport.read_messages { |msg| received << msg }

      expect(received).to eq([{ type: 'test1' }, { type: 'test2' }])
    end

    it 'closes successfully' do
      transport.connect
      expect(transport.ready?).to eq(true)

      transport.close
      expect(transport.ready?).to eq(false)
    end
  end

  describe 'abstract class behavior' do
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
end
