# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK do
  describe 'Error Classes' do
    describe ClaudeAgentSDK::ClaudeSDKError do
      it 'is a StandardError' do
        expect(described_class).to be < StandardError
      end

      it 'can be raised with a message' do
        expect { raise described_class, 'Test error' }.to raise_error(described_class, 'Test error')
      end
    end

    describe ClaudeAgentSDK::CLIConnectionError do
      it 'inherits from ClaudeSDKError' do
        expect(described_class).to be < ClaudeAgentSDK::ClaudeSDKError
      end

      it 'can be raised with a message' do
        expect { raise described_class, 'Connection failed' }
          .to raise_error(described_class, 'Connection failed')
      end
    end

    describe ClaudeAgentSDK::CLINotFoundError do
      it 'inherits from CLIConnectionError' do
        expect(described_class).to be < ClaudeAgentSDK::CLIConnectionError
      end

      it 'has a default message' do
        error = described_class.new
        expect(error.message).to eq('Claude Code not found')
      end

      it 'can include CLI path in message' do
        error = described_class.new('Claude Code not found', cli_path: '/usr/bin/claude')
        expect(error.message).to include('/usr/bin/claude')
      end
    end

    describe ClaudeAgentSDK::ProcessError do
      it 'inherits from ClaudeSDKError' do
        expect(described_class).to be < ClaudeAgentSDK::ClaudeSDKError
      end

      it 'stores exit code' do
        error = described_class.new('Process failed', exit_code: 1)
        expect(error.exit_code).to eq(1)
      end

      it 'stores stderr output' do
        error = described_class.new('Process failed', stderr: 'Error output')
        expect(error.stderr).to eq('Error output')
      end

      it 'includes exit code in message' do
        error = described_class.new('Process failed', exit_code: 1)
        expect(error.message).to include('exit code: 1')
      end

      it 'includes stderr in message' do
        error = described_class.new('Process failed', stderr: 'Error output')
        expect(error.message).to include('Error output')
      end
    end

    describe ClaudeAgentSDK::CLIJSONDecodeError do
      it 'inherits from ClaudeSDKError' do
        expect(described_class).to be < ClaudeAgentSDK::ClaudeSDKError
      end

      it 'stores the line that failed to parse' do
        original = StandardError.new('Invalid JSON')
        error = described_class.new('invalid json', original)
        expect(error.line).to eq('invalid json')
      end

      it 'stores the original error' do
        original = StandardError.new('Invalid JSON')
        error = described_class.new('invalid json', original)
        expect(error.original_error).to eq(original)
      end
    end

    describe ClaudeAgentSDK::MessageParseError do
      it 'inherits from ClaudeSDKError' do
        expect(described_class).to be < ClaudeAgentSDK::ClaudeSDKError
      end

      it 'stores the data that failed to parse' do
        data = { type: 'unknown' }
        error = described_class.new('Failed to parse', data: data)
        expect(error.data).to eq(data)
      end
    end
  end
end
