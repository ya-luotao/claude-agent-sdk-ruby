# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::SubprocessCLITransport do
  describe '#build_command' do
    it 'passes a string system_prompt via --system-prompt' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: 'You are a helpful assistant'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt', 'You are a helpful assistant')
    end

    it 'passes a preset system_prompt via --system-prompt-preset and --append-system-prompt' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: { type: 'preset', preset: 'claude_code', append: 'Extra instructions' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt-preset', 'claude_code')
      expect(cmd).to include('--append-system-prompt', 'Extra instructions')
    end

    it 'supports SystemPromptPreset objects' do
      preset = ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', append: 'Extra')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: preset
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt-preset', 'claude_code')
      expect(cmd).to include('--append-system-prompt', 'Extra')
    end
  end

  describe '#check_claude_version' do
    it 'uses Open3.capture3 to avoid shelling out' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')
      transport = described_class.new('hi', options)

      expect(Open3).to receive(:capture3).with('/usr/bin/claude', '-v')
                                        .and_return(["2.1.22 (Claude Code)\n", '', nil])

      transport.send(:check_claude_version)
    end
  end
end

