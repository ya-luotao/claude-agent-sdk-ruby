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

    describe ClaudeAgentSDK::ResultError do
      let(:payload) do
        {
          type: 'result', subtype: 'success', is_error: true, errors: [],
          result: 'API Error: Stream idle timeout - no chunks received',
          api_error_status: nil, terminal_reason: 'api_error', session_id: 's-1'
        }
      end

      it 'inherits from ProcessError' do
        expect(described_class).to be < ClaudeAgentSDK::ProcessError
        expect(described_class).to be < ClaudeAgentSDK::ClaudeSDKError
      end

      it 'carries the result payload alongside the process fields' do
        error = described_class.new(
          'Claude Code returned an error result: x', data: payload, exit_code: 1, stderr: 'tail'
        )

        expect(error.data).to equal(payload)
        expect(error.subtype).to eq('success')
        expect(error.errors).to eq([])
        expect(error.result).to eq('API Error: Stream idle timeout - no chunks received')
        expect(error.api_error_status).to be_nil
        expect(error.terminal_reason).to eq('api_error')
        expect(error.session_id).to eq('s-1')
        expect(error.exit_code).to eq(1)
        expect(error.stderr).to eq('tail')
        expect(error.message).to include('exit code: 1')
      end

      it 'exposes the ProcessError it replaced (Ruby never sets #cause here)' do
        original = ClaudeAgentSDK::ProcessError.new('Command failed', exit_code: 1)
        error = described_class.new('boom', data: payload, original_error: original)

        expect(error.original_error).to equal(original)
        expect(error.cause).to be_nil
      end

      it 'narrows malformed fields to nil rather than leaking raw values' do
        error = described_class.new('boom', data: { errors: 42, api_error_status: '500', subtype: 7 })

        expect(error.subtype).to be_nil
        expect(error.errors).to eq([])
        expect(error.result).to be_nil
        expect(error.api_error_status).to be_nil
        expect(error.terminal_reason).to be_nil
        expect(error.session_id).to be_nil
        expect(error.exit_code).to be_nil
      end

      it 'defaults data to an empty Hash when absent or not a Hash' do
        expect(described_class.new('boom').data).to eq({})
        expect(described_class.new('boom', data: 'nope').data).to eq({})
      end

      # The structured field and the text the read loop builds are derived
      # from the same normalization, so they can never disagree.
      it 'normalizes errors the same way the message text is built' do
        expect(described_class.new('m', data: { errors: 'boom' }).errors).to eq(['boom'])
        expect(described_class.new('m', data: { errors: [' ', 'x ', 3] }).errors).to eq(['x'])
      end

      # Wire payloads arrive symbolized; a payload replayed from plain
      # JSON.parse has String keys and must read back identically.
      it 'reads String-keyed payloads too' do
        error = described_class.new('boom', data: { 'subtype' => 'error_max_turns', 'errors' => ['too many'] })

        expect(error.subtype).to eq('error_max_turns')
        expect(error.errors).to eq(['too many'])
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
