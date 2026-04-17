# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

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

    it 'passes a preset system_prompt via --append-system-prompt only (no --system-prompt)' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: { type: 'preset', preset: 'claude_code', append: 'Extra instructions' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--system-prompt')
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

      expect(cmd).not_to include('--system-prompt')
      expect(cmd).to include('--append-system-prompt', 'Extra')
    end

    it 'passes empty system prompt when nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--system-prompt')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('')
    end

    it 'always uses --input-format stream-json' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--input-format', 'stream-json')
    end

    it 'does not include --agents in CLI args' do
      agent = ClaudeAgentSDK::AgentDefinition.new(
        description: 'Test agent',
        prompt: 'You are helpful'
      )
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        agents: { test: agent }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--agents')
    end

    it 'passes --thinking adaptive for ThinkingConfigAdaptive' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('adaptive')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'passes --max-thinking-tokens for ThinkingConfigEnabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 50_000)
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--max-thinking-tokens')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('50000')
      expect(cmd).not_to include('--thinking')
    end

    it 'passes --thinking disabled for ThinkingConfigDisabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigDisabled.new
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('disabled')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'thinking takes precedence over deprecated max_thinking_tokens' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new,
        max_thinking_tokens: 99_999
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('adaptive')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'falls back to max_thinking_tokens when thinking is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        max_thinking_tokens: 20_000
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--max-thinking-tokens')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('20000')
    end

    it 'passes --effort flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'high'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'high')
    end

    it 'passes --effort max' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'max'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'max')
    end

    it 'passes --effort xhigh' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'xhigh'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'xhigh')
    end

    it 'omits --effort when effort is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: nil
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--effort')
    end

    it 'forwards an Integer effort verbatim' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 8000
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', '8000')
    end

    it 'maps tools preset objects to the CLI default tool set' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        tools: ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code')
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--tools')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('default')
    end

    it 'uses plugin directories instead of --plugins JSON' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        plugins: [ClaudeAgentSDK::SdkPluginConfig.new(path: '/tmp/plugin')]
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--plugin-dir', '/tmp/plugin')
      expect(cmd).not_to include('--plugins')
    end

    it 'merges sandbox settings into settings loaded from a file path' do
      Tempfile.create(['claude-settings', '.json']) do |file|
        file.write(JSON.generate({ permissions: { allow: ['Bash(ls:*)'] } }))
        file.flush

        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          cli_path: '/usr/bin/claude',
          settings: file.path,
          sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
        )

        transport = described_class.new('hi', options)
        cmd = transport.build_command

        idx = cmd.index('--settings')
        expect(idx).not_to be_nil

        merged_settings = JSON.parse(cmd[idx + 1])
        expect(merged_settings).to eq(
          'permissions' => { 'allow' => ['Bash(ls:*)'] },
          'sandbox' => { 'enabled' => true }
        )
      end
    end

    it 'raises when settings file path contains invalid JSON and sandbox is enabled' do
      Tempfile.create(['claude-settings', '.json']) do |file|
        file.write('not valid json {{{')
        file.flush

        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          cli_path: '/usr/bin/claude',
          settings: file.path,
          sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
        )

        transport = described_class.new('hi', options)
        expect { transport.build_command }.to raise_error(JSON::ParserError)
      end
    end

    it 'raises when settings file path does not exist and sandbox is enabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        settings: '/nonexistent/path/settings.json',
        sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
      )

      transport = described_class.new('hi', options)
      expect { transport.build_command }.to raise_error(ClaudeAgentSDK::CLIConnectionError, /Settings file not found/)
    end

    it 'passes --system-prompt-file for SystemPromptFile objects' do
      prompt_file = ClaudeAgentSDK::SystemPromptFile.new(path: '/tmp/prompt.txt')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: prompt_file
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt-file', '/tmp/prompt.txt')
      expect(cmd).not_to include('--system-prompt')
    end

    it 'passes --system-prompt-file for Hash with type: file' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: { type: 'file', path: '/tmp/prompt.txt' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt-file', '/tmp/prompt.txt')
    end

    it 'passes --session-id flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        session_id: '550e8400-e29b-41d4-a716-446655440000'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--session-id', '550e8400-e29b-41d4-a716-446655440000')
    end

    it 'passes --task-budget from TaskBudget object' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: ClaudeAgentSDK::TaskBudget.new(total: 50_000)
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '50000')
    end

    it 'passes --task-budget from Hash with symbol keys' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: { total: 30_000 }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '30000')
    end

    it 'passes --task-budget from Hash with string keys' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: { 'total' => 25_000 }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '25000')
    end

    it 'does not add the deprecated enable-file-checkpointing flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        enable_file_checkpointing: true
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--enable-file-checkpointing')
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

  describe 'environment variable handling' do
    it 'converts symbol keys in env to strings for spawn compatibility' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        env: { SYMBOL_KEY: 'value', 'STRING_KEY' => 'value2', 'CLAUDE_CODE_ENTRYPOINT' => 'sdk-rb' }
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO), instance_double(IO), instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['SYMBOL_KEY']).to eq('value')
      expect(captured_env['STRING_KEY']).to eq('value2')
      expect(captured_env.key?(:SYMBOL_KEY)).to be false
      expect(captured_env['CLAUDE_CODE_ENTRYPOINT']).to eq('sdk-rb')
    end

    it 'preserves a caller-provided CLAUDE_CODE_ENTRYPOINT value' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        env: { 'CLAUDE_CODE_ENTRYPOINT' => 'custom-entrypoint' }
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO), instance_double(IO), instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['CLAUDE_CODE_ENTRYPOINT']).to eq('custom-entrypoint')
    end

    it 'enables SDK file checkpointing via environment variable' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        enable_file_checkpointing: true
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO), instance_double(IO), instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING']).to eq('true')
    end

    it 'does not set FGTS env var even when partial messages are requested' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        include_partial_messages: true
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(Open3).to receive(:capture3).and_return(["2.1.22 (Claude Code)\n", '', nil])
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO), instance_double(IO), instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      # FGTS env var was reverted in Python SDK v0.1.48 due to 400 errors on proxies/Bedrock/Vertex
      expect(captured_env).not_to have_key('CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING')
    end
  end
end
