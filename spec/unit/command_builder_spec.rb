# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::CommandBuilder do
  subject(:cmd) { described_class.new('/usr/bin/claude', options).build }

  let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new }

  describe '#build' do
    it 'starts with cli_path and fixed base flags' do
      expect(cmd[0..3]).to eq(['/usr/bin/claude', '--output-format', 'stream-json', '--verbose'])
    end

    it 'always appends --input-format stream-json at the end' do
      expect(cmd.last(2)).to eq(['--input-format', 'stream-json'])
    end

    it 'emits an empty --system-prompt when system_prompt is nil' do
      idx = cmd.index('--system-prompt')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('')
    end
  end

  describe 'system_prompt variants' do
    it 'handles String' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: 'Hello')
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--system-prompt', 'Hello')
    end

    it 'handles SystemPromptFile' do
      prompt = ClaudeAgentSDK::SystemPromptFile.new(path: '/tmp/prompt.txt')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: prompt)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--system-prompt-file', '/tmp/prompt.txt')
      expect(cmd).not_to include('--system-prompt')
    end

    it 'handles SystemPromptPreset with append' do
      preset = ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', append: 'Extra')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: preset)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--append-system-prompt', 'Extra')
      expect(cmd).not_to include('--system-prompt')
    end

    it 'omits --append-system-prompt for preset with no append' do
      preset = ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: preset)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).not_to include('--append-system-prompt')
      expect(cmd).not_to include('--system-prompt')
    end

    it 'handles Hash with type file' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        system_prompt: { type: 'file', path: '/tmp/prompt.txt' }
      )
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--system-prompt-file', '/tmp/prompt.txt')
    end

    it 'handles Hash with string keys for type preset' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        system_prompt: { 'type' => 'preset', 'append' => 'Extra' }
      )
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--append-system-prompt', 'Extra')
    end
  end

  describe 'tools' do
    it 'skips --tools when nil' do
      expect(cmd).not_to include('--tools')
    end

    it 'passes array values joined by commas' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: %w[Read Write])
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--tools', 'Read,Write')
    end

    it 'passes empty string for an empty array' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: [])
      cmd = described_class.new('/usr/bin/claude', options).build
      idx = cmd.index('--tools')
      expect(cmd[idx + 1]).to eq('')
    end

    it 'passes default for ToolsPreset' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: ClaudeAgentSDK::ToolsPreset.new(preset: 'default'))
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--tools', 'default')
    end

    it 'passes default for Hash preset' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: { type: 'preset' })
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--tools', 'default')
    end
  end

  describe 'skills defaults' do
    def build(options)
      described_class.new('/usr/bin/claude', options).build
    end

    def flag_value(cmd, flag)
      idx = cmd.index(flag)
      idx && cmd[idx + 1]
    end

    it "skills: 'all' allows the bare Skill tool and defaults setting sources" do
      cmd = build(ClaudeAgentSDK::ClaudeAgentOptions.new(skills: 'all'))

      expect(flag_value(cmd, '--allowedTools')).to eq('Skill')
      expect(flag_value(cmd, '--setting-sources')).to eq('user,project')
    end

    it 'skills list allows Skill(name) per entry without duplicating existing entries' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        skills: %w[pdf docx], allowed_tools: ['Read', 'Skill(pdf)']
      )
      cmd = build(options)

      expect(flag_value(cmd, '--allowedTools')).to eq('Read,Skill(pdf),Skill(docx)')
      # non-mutating: the options object is untouched
      expect(options.allowed_tools).to eq(['Read', 'Skill(pdf)'])
    end

    it 'never overrides explicit setting_sources, including []' do
      cmd = build(ClaudeAgentSDK::ClaudeAgentOptions.new(skills: 'all', setting_sources: []))

      expect(flag_value(cmd, '--setting-sources')).to eq('')
    end

    it 'skills: [] adds no Skill entries but still defaults setting sources' do
      cmd = build(ClaudeAgentSDK::ClaudeAgentOptions.new(skills: []))

      expect(cmd).not_to include('--allowedTools')
      expect(flag_value(cmd, '--setting-sources')).to eq('user,project')
    end

    it 'raises a clear ArgumentError for invalid skills values' do
      [:all, 'pdf', { name: 'pdf' }].each do |bad|
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(skills: bad)
        expect { build(options) }.to raise_error(ArgumentError, /skills must be 'all' or an Array/)
      end
    end

    it 'skills: nil leaves both flags untouched' do
      cmd = build(ClaudeAgentSDK::ClaudeAgentOptions.new(allowed_tools: %w[Read]))

      expect(flag_value(cmd, '--allowedTools')).to eq('Read')
      expect(cmd).not_to include('--setting-sources')
    end
  end

  describe 'allow/disallow lists' do
    it 'joins allowed_tools with commas' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(allowed_tools: %w[Read Write])
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--allowedTools', 'Read,Write')
    end

    it 'joins disallowed_tools with commas' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(disallowed_tools: %w[Bash])
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--disallowedTools', 'Bash')
    end

    it 'omits empty allowed_tools' do
      expect(cmd).not_to include('--allowedTools')
    end
  end

  describe 'session flags' do
    it 'adds --continue when continue_conversation is true' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(continue_conversation: true)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--continue')
    end

    it 'passes --resume with session id' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(resume: 'abc-123')
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--resume', 'abc-123')
    end

    it 'passes --session-id' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(session_id: 'sess-xyz')
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--session-id', 'sess-xyz')
    end

    describe '--resume-session-at' do
      let(:message_uuid) { 'b3a8f2e6-1c4d-4e9a-9c5d-1f2a3b4c5d6e' }

      it 'passes --resume-session-at alongside --resume' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          resume: 'sess-source',
          resume_session_at: message_uuid
        )
        cmd = described_class.new('/usr/bin/claude', options).build
        expect(cmd).to include('--resume', 'sess-source')
        expect(cmd).to include('--resume-session-at', message_uuid)
      end

      it 'omits --resume-session-at when not set' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(resume: 'sess-source')
        cmd = described_class.new('/usr/bin/claude', options).build
        expect(cmd).not_to include('--resume-session-at')
      end

      it 'raises ArgumentError when used without resume' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(resume_session_at: message_uuid)
        builder = described_class.new('/usr/bin/claude', options)
        expect { builder.build }.to raise_error(
          ArgumentError,
          /resume_session_at requires resume to be set/
        )
      end

      it 'stringifies non-string values' do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          resume: 'sess-source',
          resume_session_at: :"#{message_uuid}"
        )
        cmd = described_class.new('/usr/bin/claude', options).build
        expect(cmd).to include('--resume-session-at', message_uuid)
      end
    end
  end

  describe 'thinking config' do
    it 'passes adaptive' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--thinking', 'adaptive')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'passes --max-thinking-tokens for enabled budget' do
      thinking = ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 50_000)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: thinking)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--max-thinking-tokens', '50000')
    end

    it 'passes disabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: ClaudeAgentSDK::ThinkingConfigDisabled.new)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--thinking', 'disabled')
    end

    it 'falls back to max_thinking_tokens when thinking is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(max_thinking_tokens: 10_000)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--max-thinking-tokens', '10000')
    end

    it 'prefers thinking over deprecated max_thinking_tokens' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new,
        max_thinking_tokens: 10_000
      )
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--thinking', 'adaptive')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'passes --thinking-display summarized for adaptive with display' do
      thinking = ClaudeAgentSDK::ThinkingConfigAdaptive.new(display: 'summarized')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: thinking)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--thinking', 'adaptive')
      expect(cmd).to include('--thinking-display', 'summarized')
    end

    it 'passes --thinking-display omitted for adaptive with display' do
      thinking = ClaudeAgentSDK::ThinkingConfigAdaptive.new(display: 'omitted')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: thinking)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--thinking-display', 'omitted')
    end

    it 'passes --thinking-display for enabled with display' do
      thinking = ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 5_000, display: 'summarized')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: thinking)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--max-thinking-tokens', '5000')
      expect(cmd).to include('--thinking-display', 'summarized')
    end

    it 'omits --thinking-display when display is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).not_to include('--thinking-display')
    end

    it 'raises when display value is invalid' do
      expect do
        ClaudeAgentSDK::ThinkingConfigAdaptive.new(display: 'full')
      end.to raise_error(ArgumentError, /invalid thinking display/)
    end
  end

  describe 'mcp_servers' do
    it 'serializes Hash to --mcp-config JSON' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        mcp_servers: { 'local' => { command: 'node', args: ['server.js'] } }
      )
      cmd = described_class.new('/usr/bin/claude', options).build
      idx = cmd.index('--mcp-config')
      parsed = JSON.parse(cmd[idx + 1])
      expect(parsed['mcpServers']['local']['command']).to eq('node')
    end

    it 'strips :instance from SDK MCP server configs' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        mcp_servers: { 'sdk' => { type: 'sdk', name: 'sdk', instance: Object.new } }
      )
      cmd = described_class.new('/usr/bin/claude', options).build
      idx = cmd.index('--mcp-config')
      expect(cmd[idx + 1]).not_to include('instance')
    end
  end

  describe 'extra_args' do
    it 'passes boolean flags with no value' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(extra_args: { 'debug-to-stderr' => nil })
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--debug-to-stderr')
    end

    it 'passes flags with value' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(extra_args: { 'log-level' => 'debug' })
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--log-level', 'debug')
    end

    it 'accepts symbol keys' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(extra_args: { debug: nil })
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--debug')
    end

    it 'rejects keys with spaces' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        extra_args: { 'bad flag' => nil }
      )
      expect { described_class.new('/usr/bin/claude', options).build }
        .to raise_error(ArgumentError, /Invalid extra_args flag name/)
    end

    it 'rejects keys starting with --' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        extra_args: { '--prefixed' => nil }
      )
      expect { described_class.new('/usr/bin/claude', options).build }
        .to raise_error(ArgumentError, /Invalid extra_args flag name/)
    end
  end

  describe 'plugins' do
    it 'emits --plugin-dir per plugin' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        plugins: [
          { type: 'local', path: '/tmp/plugin-a' },
          { type: 'plugin', path: '/tmp/plugin-b' }
        ]
      )
      cmd = described_class.new('/usr/bin/claude', options).build
      paths = []
      cmd.each_with_index do |arg, i|
        paths << cmd[i + 1] if arg == '--plugin-dir'
      end
      expect(paths).to eq(['/tmp/plugin-a', '/tmp/plugin-b'])
    end

    it 'raises on unsupported plugin type' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        plugins: [{ type: 'remote', path: '/tmp/x' }]
      )
      expect { described_class.new('/usr/bin/claude', options).build }
        .to raise_error(ArgumentError, /Unsupported plugin type/)
    end
  end

  describe 'settings + sandbox merge' do
    it 'merges a SandboxSettings into an inline settings hash' do
      sandbox = ClaudeAgentSDK::SandboxSettings.new(enabled: true)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        settings: { existingKey: 'value' },
        sandbox: sandbox
      )
      cmd = described_class.new('/usr/bin/claude', options).build
      idx = cmd.index('--settings')
      parsed = JSON.parse(cmd[idx + 1])
      expect(parsed['existingKey']).to eq('value')
      expect(parsed['sandbox']).to include('enabled' => true)
    end

    it 'treats unparseable settings strings as file paths when no sandbox' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(settings: '/path/to/settings.json')
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--settings', '/path/to/settings.json')
    end
  end

  describe 'boolean flags' do
    it 'passes --include-partial-messages' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(include_partial_messages: true)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--include-partial-messages')
    end

    it 'passes --fork-session' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(fork_session: true)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--fork-session')
    end

    it 'passes --bare' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(bare: true)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--bare')
    end

    it 'passes --include-hook-events' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(include_hook_events: true)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--include-hook-events')
    end

    it 'passes --strict-mcp-config' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(strict_mcp_config: true)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--strict-mcp-config')
    end

    it 'omits --include-hook-events and --strict-mcp-config by default' do
      cmd = described_class.new('/usr/bin/claude', ClaudeAgentSDK::ClaudeAgentOptions.new).build
      expect(cmd).not_to include('--include-hook-events')
      expect(cmd).not_to include('--strict-mcp-config')
    end

    it 'passes --session-mirror when a session_store is set' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: ClaudeAgentSDK::InMemorySessionStore.new)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--session-mirror')
    end

    it 'omits --session-mirror by default' do
      cmd = described_class.new('/usr/bin/claude', ClaudeAgentSDK::ClaudeAgentOptions.new).build
      expect(cmd).not_to include('--session-mirror')
    end
  end

  describe 'mutually exclusive session flags' do
    it 'raises ArgumentError when both continue_conversation and resume are set' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        continue_conversation: true,
        resume: 'session-id'
      )
      expect { described_class.new('/usr/bin/claude', options).build }
        .to raise_error(ArgumentError, /continue_conversation and resume are mutually exclusive/)
    end

    it 'allows continue_conversation alone' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(continue_conversation: true)
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--continue')
    end

    it 'allows resume alone' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(resume: 'session-id')
      cmd = described_class.new('/usr/bin/claude', options).build
      expect(cmd).to include('--resume', 'session-id')
    end
  end

  describe 'standalone loading' do
    it 'CommandBuilder can be required on its own' do
      output = `#{RbConfig.ruby} -Ilib -rclaude_agent_sdk/command_builder -e "puts ClaudeAgentSDK::CommandBuilder.name" 2>&1`
      expect(output.strip).to eq('ClaudeAgentSDK::CommandBuilder')
    end
  end
end
