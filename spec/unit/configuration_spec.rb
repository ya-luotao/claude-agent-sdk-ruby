# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK do
  describe '.configure' do
    after { ClaudeAgentSDK.reset_configuration }

    it 'yields configuration object' do
      yielded_config = nil
      ClaudeAgentSDK.configure do |config|
        yielded_config = config
      end

      expect(yielded_config).to be_a(ClaudeAgentSDK::Configuration)
    end

    it 'sets default_options' do
      ClaudeAgentSDK.configure do |config|
        config.default_options = { model: 'sonnet', permission_mode: 'bypassPermissions' }
      end

      expect(ClaudeAgentSDK.default_options).to eq({
                                                     model: 'sonnet',
                                                     permission_mode: 'bypassPermissions'
                                                   })
    end
  end

  describe '.default_options' do
    after { ClaudeAgentSDK.reset_configuration }

    it 'returns empty hash when not configured' do
      expect(ClaudeAgentSDK.default_options).to eq({})
    end

    it 'returns configured default options' do
      ClaudeAgentSDK.configure do |config|
        config.default_options = {
          env: { 'API_KEY' => 'secret' },
          model: 'opus'
        }
      end

      expect(ClaudeAgentSDK.default_options).to eq({
                                                     env: { 'API_KEY' => 'secret' },
                                                     model: 'opus'
                                                   })
    end
  end

  describe '.reset_configuration' do
    it 'clears configured defaults' do
      ClaudeAgentSDK.configure do |config|
        config.default_options = { model: 'sonnet' }
      end

      expect(ClaudeAgentSDK.default_options).not_to be_empty

      ClaudeAgentSDK.reset_configuration

      expect(ClaudeAgentSDK.default_options).to eq({})
    end
  end

  describe ClaudeAgentSDK::Configuration do
    it 'initializes with empty default_options' do
      config = described_class.new
      expect(config.default_options).to eq({})
    end

    it 'stores default_options' do
      config = described_class.new
      config.default_options = { model: 'haiku' }

      expect(config.default_options).to eq({ model: 'haiku' })
    end
  end

  describe ClaudeAgentSDK::ClaudeAgentOptions do
    after { ClaudeAgentSDK.reset_configuration }

    context 'when default options are configured' do
      before do
        ClaudeAgentSDK.configure do |config|
          config.default_options = {
            env: { 'DEFAULT_KEY' => 'default_value', 'SHARED_KEY' => 'default_shared' },
            permission_mode: 'bypassPermissions',
            model: 'sonnet',
            max_turns: 50
          }
        end
      end

      it 'merges defaults with provided options' do
        options = described_class.new(
          model: 'opus',
          env: { 'SHARED_KEY' => 'provided_value', 'PROVIDED_KEY' => 'provided_value' }
        )

        # Provided values override defaults
        expect(options.model).to eq('opus')

        # env is deep merged
        expect(options.env['DEFAULT_KEY']).to eq('default_value')  # from default
        expect(options.env['SHARED_KEY']).to eq('provided_value')  # provided overrides
        expect(options.env['PROVIDED_KEY']).to eq('provided_value') # provided only

        # Non-provided values use defaults
        expect(options.permission_mode).to eq('bypassPermissions')
        expect(options.max_turns).to eq(50)
      end

      it 'uses all defaults when no options provided' do
        options = described_class.new

        expect(options.model).to eq('sonnet')
        expect(options.permission_mode).to eq('bypassPermissions')
        expect(options.max_turns).to eq(50)
        expect(options.env).to eq({ 'DEFAULT_KEY' => 'default_value', 'SHARED_KEY' => 'default_shared' })
      end

      it 'uses default value when nil is explicitly provided' do
        options = described_class.new(model: nil)

        # nil uses the default value
        expect(options.model).to eq('sonnet')
        expect(options.permission_mode).to eq('bypassPermissions')
      end

      it 'replaces arrays instead of merging' do
        ClaudeAgentSDK.configure do |config|
          config.default_options = { allowed_tools: %w[Read Write] }
        end

        options = described_class.new(allowed_tools: ['Bash'])

        expect(options.allowed_tools).to eq(['Bash'])
      end

      it 'replaces mcp_servers hash with deep merge' do
        ClaudeAgentSDK.configure do |config|
          config.default_options = {
            mcp_servers: {
              server1: { type: 'stdio', command: 'cmd1' },
              server2: { type: 'stdio', command: 'cmd2' }
            }
          }
        end

        options = described_class.new(
          mcp_servers: {
            server2: { type: 'http', url: 'http://localhost' },
            server3: { type: 'stdio', command: 'cmd3' }
          }
        )

        # server1 from defaults
        expect(options.mcp_servers[:server1]).to eq({ type: 'stdio', command: 'cmd1' })
        # server2 overridden
        expect(options.mcp_servers[:server2]).to eq({ type: 'http', url: 'http://localhost' })
        # server3 from provided
        expect(options.mcp_servers[:server3]).to eq({ type: 'stdio', command: 'cmd3' })
      end

      # Shallow merge behavior for mcp_servers with nested configs
      context 'with nested hashes in mcp_servers' do
        before do
          ClaudeAgentSDK.configure do |config|
            config.default_options = {
              mcp_servers: {
                server1: {
                  type: 'stdio',
                  command: 'cmd1',
                  args: ['--verbose', '--log-level=debug'],
                  env: { 'DEBUG' => 'true' }
                }
              }
            }
          end
        end

        it 'performs shallow merge - provided value replaces entire nested config' do
          options = described_class.new(
            mcp_servers: {
              server1: { type: 'http', url: 'http://localhost' }
            }
          )

          # Shallow merge: provided server config completely replaces default
          # Nested args and env from defaults are not preserved
          expect(options.mcp_servers[:server1]).to eq({
                                                        type: 'http',
                                                        url: 'http://localhost'
                                                      })
          # To preserve args/env, include them in the provided config:
          # mcp_servers: {
          #   server1: {
          #     type: 'http',
          #     url: 'http://localhost',
          #     args: ['--verbose', '--log-level=debug'],
          #     env: { 'DEBUG' => 'true' }
          #   }
          # }
        end
      end

      context 'nil behavior for different types' do
        before do
          ClaudeAgentSDK.configure do |config|
            config.default_options = {
              model: 'sonnet',
              env: { 'DEFAULT_KEY' => 'value' },
              allowed_tools: %w[Read Write]
            }
          end
        end

        it 'uses default for scalar when nil is provided' do
          options = described_class.new(model: nil)
          expect(options.model).to eq('sonnet')
        end

        it 'uses default for hash when nil is provided' do
          options = described_class.new(env: nil)
          expect(options.env).to eq({ 'DEFAULT_KEY' => 'value' })
        end

        it 'replaces with empty array when empty array is provided' do
          options = described_class.new(allowed_tools: [])
          expect(options.allowed_tools).to eq([])
        end

        it 'merges empty hash with defaults' do
          options = described_class.new(env: {})
          expect(options.env).to eq({ 'DEFAULT_KEY' => 'value' })
        end

        it 'uses configured array default when not explicitly provided' do
          options = described_class.new
          expect(options.allowed_tools).to eq(%w[Read Write])
        end
      end

      # A tri-state Boolean option: nil means "no preference", so only an
      # explicit false may override a configured true.
      context 'agent_progress_summaries against a configured default' do
        it 'lets a per-call false override a global true' do
          ClaudeAgentSDK.configure { |config| config.default_options = { agent_progress_summaries: true } }

          expect(described_class.new(agent_progress_summaries: false).agent_progress_summaries).to be(false)
        end

        it 'inherits the global value when the per-call option is unset or nil' do
          ClaudeAgentSDK.configure { |config| config.default_options = { agent_progress_summaries: true } }

          expect(described_class.new.agent_progress_summaries).to be(true)
          expect(described_class.new(agent_progress_summaries: nil).agent_progress_summaries).to be(true)
        end

        it 'inherits a global false rather than collapsing it to nil' do
          ClaudeAgentSDK.configure { |config| config.default_options = { agent_progress_summaries: false } }

          expect(described_class.new.agent_progress_summaries).to be(false)
          expect(described_class.new(agent_progress_summaries: true).agent_progress_summaries).to be(true)
        end

        it 'stays nil when neither the defaults nor the call set it' do
          ClaudeAgentSDK.configure { |config| config.default_options = { model: 'sonnet' } }

          expect(described_class.new.agent_progress_summaries).to be_nil
        end

        it 'keeps false and nil across dup_with under a configured default' do
          ClaudeAgentSDK.configure { |config| config.default_options = { agent_progress_summaries: true } }
          off = described_class.new(agent_progress_summaries: false)

          expect(off.dup_with(model: 'opus').agent_progress_summaries).to be(false)
          expect(off.dup_with(agent_progress_summaries: true).agent_progress_summaries).to be(true)
          expect(off.agent_progress_summaries).to be(false)
        end
      end

      # Test for env hash mutation
      context 'env hash isolation from defaults' do
        before do
          ClaudeAgentSDK.configure do |config|
            config.default_options = {
              env: { 'API_KEY' => 'secret', 'DEBUG' => 'false' }
            }
          end
        end

        it 'isolates provided env from defaults' do
          options = described_class.new
          options.env.dup

          # Mutate the returned env
          options.env['NEW_KEY'] = 'new_value'
          options.env['API_KEY'] = 'modified'

          # Create new options - should have original defaults
          new_options = described_class.new
          expect(new_options.env['API_KEY']).to eq('secret')
          expect(new_options.env).not_to have_key('NEW_KEY')
        end

        it 'isolates merged env from defaults' do
          options = described_class.new(env: { 'PROVIDED_KEY' => 'provided' })

          # Mutate the merged env
          options.env['PROVIDED_KEY'] = 'modified'
          options.env['API_KEY'] = 'also_modified'

          # Defaults should be unchanged
          new_options = described_class.new
          expect(new_options.env['API_KEY']).to eq('secret')
          expect(new_options.env).not_to have_key('PROVIDED_KEY')
        end
      end
    end

    context 'container isolation from defaults' do
      it 'appending to a default-sourced array does not mutate the global default' do
        ClaudeAgentSDK.configure { |c| c.default_options = { allowed_tools: %w[Read Write] } }

        described_class.new.allowed_tools << 'Bash'

        expect(ClaudeAgentSDK.default_options[:allowed_tools]).to eq(%w[Read Write])
        expect(described_class.new.allowed_tools).to eq(%w[Read Write])
      end

      it 'mutating a nested default hash does not leak into the global default' do
        ClaudeAgentSDK.configure do |c|
          c.default_options = { mcp_servers: { server1: { command: 'cmd1' } } }
        end

        described_class.new.mcp_servers[:server1][:command] = 'evil'

        expect(described_class.new.mcp_servers[:server1][:command]).to eq('cmd1')
      end

      it 'appending to a nested default array does not leak' do
        ClaudeAgentSDK.configure do |c|
          c.default_options = { mcp_servers: { server1: { args: ['--verbose'] } } }
        end

        described_class.new.mcp_servers[:server1][:args] << '--evil'

        expect(described_class.new.mcp_servers[:server1][:args]).to eq(['--verbose'])
      end

      it 'keeps leaf object identity (SDK MCP server instances are not duped)' do
        server = Object.new
        ClaudeAgentSDK.configure do |c|
          c.default_options = { mcp_servers: { tools: { type: 'sdk', instance: server } } }
        end

        expect(described_class.new.mcp_servers[:tools][:instance]).to equal(server)
      end
    end

    # Regression (#69): the defaults copier recursed into Hash/Array only, so
    # typed option values (SystemPromptPreset, SandboxSettings, AgentDefinition,
    # ...) in configured defaults were ONE instance shared by every session —
    # a per-session change to sandbox rules or the system prompt silently
    # changed what every other session sent to the CLI.
    context 'typed option values from configured defaults' do
      it 'gives each options instance its own copy of a default SystemPromptPreset' do
        preset = ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude', append: 'base')
        ClaudeAgentSDK.configure { |c| c.default_options = { system_prompt: preset } }
        o1 = described_class.new
        o2 = described_class.new

        expect(o1.system_prompt).not_to equal(o2.system_prompt)
        o1.system_prompt.append = 'SESSION A OVERRIDE'

        expect(o2.system_prompt.append).to eq('base')
        expect(described_class.new.system_prompt.append).to eq('base')
        expect(preset.append).to eq('base')
        expect(o1.system_prompt.to_h).to eq(type: 'preset', preset: 'claude', append: 'SESSION A OVERRIDE')
      end

      it 'isolates a default SandboxSettings, including its nested config objects and arrays' do
        sandbox = ClaudeAgentSDK::SandboxSettings.new(
          enabled: true,
          excluded_commands: ['git'],
          network: ClaudeAgentSDK::SandboxNetworkConfig.new(allowed_domains: ['example.com']),
          filesystem: ClaudeAgentSDK::SandboxFilesystemConfig.new(deny_write: ['/etc'])
        )
        ClaudeAgentSDK.configure { |c| c.default_options = { sandbox: sandbox } }
        expected = sandbox.to_h
        o1 = described_class.new
        o2 = described_class.new

        expect(o1.sandbox).not_to equal(o2.sandbox)
        expect(o1.sandbox.network).not_to equal(o2.sandbox.network)
        o1.sandbox.enabled = false
        o1.sandbox.excluded_commands << 'rm'
        o1.sandbox.network.allowed_domains << 'evil.example'
        o1.sandbox.filesystem.deny_write.clear

        expect(o2.sandbox.to_h).to eq(expected)
        expect(described_class.new.sandbox.to_h).to eq(expected)
        expect(sandbox.to_h).to eq(expected)
      end

      it 'isolates default AgentDefinitions nested inside the agents Hash' do
        agent = ClaudeAgentSDK::AgentDefinition.new(description: 'r', prompt: 'p', skills: ['one'])
        ClaudeAgentSDK.configure { |c| c.default_options = { agents: { reviewer: agent } } }
        o1 = described_class.new
        o2 = described_class.new

        o1.agents[:reviewer].skills << 'two'
        o1.agents[:reviewer].tools = ['Bash']

        expect(o2.agents[:reviewer].skills).to eq(['one'])
        expect(o2.agents[:reviewer].tools).to be_nil
        expect(agent.skills).to eq(['one'])
      end

      it 'copies a ThinkingConfig and ToolsPreset while keeping their wire form' do
        thinking = ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 1000)
        tools = ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code')
        ClaudeAgentSDK.configure { |c| c.default_options = { thinking: thinking, tools: tools } }
        o1 = described_class.new

        expect(o1.thinking).not_to equal(thinking)
        expect(o1.thinking.type).to eq('enabled')
        expect(o1.thinking.budget_tokens).to eq(1000)
        o1.thinking.budget_tokens = 5
        o1.tools.preset = 'other'

        expect(described_class.new.thinking.budget_tokens).to eq(1000)
        expect(described_class.new.tools.to_h).to eq(type: 'preset', preset: 'claude_code')
      end

      it 'keeps the identity of everything that is not an SDK value type' do
        server = Object.new
        hook = ->(_input, _id, _ctx) { {} }
        callback = ->(_tool, _input, _ctx) {}
        observer = Object.new
        factory = -> { observer }
        store = Object.new
        wrapper = lambda(&:call)
        ClaudeAgentSDK.configure do |c|
          c.default_options = {
            mcp_servers: {
              typed: ClaudeAgentSDK::McpSdkServerConfig.new(name: 'typed', instance: server),
              plain: { type: 'sdk', instance: server }
            },
            hooks: { 'PreToolUse' => [ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [hook])] },
            can_use_tool: callback,
            observers: [observer, factory],
            session_store: store,
            callback_wrapper: wrapper
          }
        end

        options = described_class.new

        expect(options.mcp_servers[:typed].instance).to equal(server)
        expect(options.mcp_servers[:plain][:instance]).to equal(server)
        expect(options.hooks['PreToolUse'].first.hooks.first).to equal(hook)
        expect(options.can_use_tool).to equal(callback)
        expect(options.observers).to eq([observer, factory])
        expect(options.observers.first).to equal(observer)
        expect(options.observers.last).to equal(factory)
        expect(options.session_store).to equal(store)
        expect(options.callback_wrapper).to equal(wrapper)
        # The HookMatcher itself is a value type: its hooks list is per session.
        options.hooks['PreToolUse'].first.hooks << hook
        expect(described_class.new.hooks['PreToolUse'].first.hooks).to eq([hook])
      end
    end

    # Regression (#92): the stored defaults were the caller's live Hash, read
    # at request time with no synchronization — an in-place write from another
    # thread raced the merge's iteration. Assignment now stores a frozen deep
    # copy, so there is no shared mutable state to race and in-place mutation
    # fails loudly instead of silently reaching (or corrupting) later sessions.
    context 'default_options snapshot' do
      it 'stores a copy, so later in-place changes to the assigned Hash do not reach requests' do
        defaults = { allowed_tools: ['Read'], env: { 'A' => '1' } }
        ClaudeAgentSDK.configure { |c| c.default_options = defaults }

        defaults[:allowed_tools] << 'Bash'
        defaults[:env]['B'] = '2'
        defaults[:model] = 'opus'

        expect(ClaudeAgentSDK.default_options).to eq(allowed_tools: ['Read'], env: { 'A' => '1' })
        expect(described_class.new.allowed_tools).to eq(['Read'])
        expect(described_class.new.model).to be_nil
      end

      it 'rejects in-place mutation of the stored defaults instead of racing request-time merges' do
        ClaudeAgentSDK.configure do |c|
          c.default_options = {
            allowed_tools: ['Read'],
            sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true, excluded_commands: ['git']),
            agents: { reviewer: ClaudeAgentSDK::AgentDefinition.new(skills: ['one']) }
          }
        end
        stored = ClaudeAgentSDK.default_options

        expect { stored[:model] = 'opus' }.to raise_error(FrozenError)
        expect { stored[:allowed_tools] << 'Bash' }.to raise_error(FrozenError)
        expect { stored[:sandbox].enabled = false }.to raise_error(FrozenError)
        expect { stored[:sandbox].excluded_commands << 'rm' }.to raise_error(FrozenError)
        expect { stored[:agents][:reviewer].skills << 'two' }.to raise_error(FrozenError)
        expect { ClaudeAgentSDK.configuration.default_options[:model] = 'opus' }.to raise_error(FrozenError)
        # Sessions still get their own mutable copies of the frozen snapshot.
        options = described_class.new
        options.allowed_tools << 'Bash'
        options.sandbox.enabled = false
        options.sandbox.excluded_commands << 'rm'
        options.agents[:reviewer].skills << 'two'
        expect(described_class.new.allowed_tools).to eq(['Read'])
        expect(described_class.new.sandbox.to_h).to eq(enabled: true, excludedCommands: ['git'])
      end

      it 'freezes only its own copy — never the caller objects or identity-preserved leaves' do
        server = Object.new
        factory = -> { Object.new }
        sandbox = ClaudeAgentSDK::SandboxSettings.new(enabled: true)
        defaults = { sandbox: sandbox, mcp_servers: { tools: { type: 'sdk', instance: server } }, observers: [factory] }
        ClaudeAgentSDK.configure { |c| c.default_options = defaults }

        expect(defaults).not_to be_frozen
        expect(defaults[:mcp_servers]).not_to be_frozen
        expect(sandbox).not_to be_frozen
        expect(server).not_to be_frozen
        expect(factory).not_to be_frozen
        stored = ClaudeAgentSDK.default_options
        expect(stored[:mcp_servers][:tools][:instance]).to equal(server)
        expect(stored[:observers].first).to equal(factory)
      end

      it 'starts frozen and treats a nil assignment as no defaults' do
        expect(ClaudeAgentSDK.default_options).to be_frozen
        expect { ClaudeAgentSDK.configuration.default_options[:model] = 'opus' }.to raise_error(FrozenError)

        ClaudeAgentSDK.configure { |c| c.default_options = { model: 'opus' } }
        ClaudeAgentSDK.configure { |c| c.default_options = nil }

        expect(ClaudeAgentSDK.default_options).to eq({})
        expect(described_class.new.model).to be_nil
      end
    end

    # Type accepts symbol/string and snake_case/camelCase option names, so the
    # defaults merge must resolve them to one option before deciding whether a
    # nil inherits, a Hash merges, or a value overrides.
    context 'when the caller and the configured defaults spell a key differently' do
      spellings = { 'symbol snake_case' => :permission_mode, 'string snake_case' => 'permission_mode',
                    'symbol camelCase' => :permissionMode, 'string camelCase' => 'permissionMode' }

      spellings.each do |default_label, default_key|
        spellings.each do |caller_label, caller_key|
          it "inherits on nil and overrides on a value (default: #{default_label}, caller: #{caller_label})" do
            ClaudeAgentSDK.configure { |config| config.default_options = { default_key => 'plan' } }

            expect(described_class.new(caller_key => nil).permission_mode).to eq('plan')
            expect(described_class.new(caller_key => 'acceptEdits').permission_mode).to eq('acceptEdits')
            expect(described_class.new.permission_mode).to eq('plan')
          end
        end
      end

      it 'merges Hash options across spellings instead of replacing the default' do
        ClaudeAgentSDK.configure { |config| config.default_options = { env: { 'A' => '1', 'B' => '2' } } }

        expect(described_class.new('env' => { 'B' => 'override', 'C' => '3' }).env)
          .to eq('A' => '1', 'B' => 'override', 'C' => '3')
        expect(described_class.new('extraArgs' => nil, 'env' => nil).env).to eq('A' => '1', 'B' => '2')
      end

      it 'keeps an explicit false distinct from nil across spellings' do
        ClaudeAgentSDK.configure { |config| config.default_options = { forward_subagent_text: true } }

        expect(described_class.new('forwardSubagentText' => false).forward_subagent_text).to be false
        expect(described_class.new('forwardSubagentText' => nil).forward_subagent_text).to be true
      end

      it 'lets the later of two caller spellings win, with nil still meaning no preference' do
        ClaudeAgentSDK.configure { |config| config.default_options = { model: 'opus' } }

        expect(described_class.new(model: 'haiku', 'model' => 'sonnet').model).to eq('sonnet')
        expect(described_class.new(model: 'haiku', 'model' => nil).model).to eq('haiku')
      end

      it 'does not mutate the configured defaults or the caller hash' do
        defaults = { 'allowedTools' => ['Read'] }
        ClaudeAgentSDK.configure { |config| config.default_options = defaults }
        attributes = { allowed_tools: nil, 'model' => 'haiku' }

        options = described_class.new(attributes)
        options.allowed_tools << 'Bash'

        expect(defaults).to eq('allowedTools' => ['Read'])
        expect(attributes).to eq(allowed_tools: nil, 'model' => 'haiku')
        expect(described_class.new.allowed_tools).to eq(['Read'])
      end

      it "reports an unknown option with the caller's own spelling" do
        ClaudeAgentSDK.configure { |config| config.default_options = { model: 'opus' } }

        expect { described_class.new('modlE' => 'haiku') }
          .to raise_error(ArgumentError, /unknown ClaudeAgentOptions option: "modlE"/)
      end

      it 'reports an unknown configured default with its own spelling' do
        ClaudeAgentSDK.configure { |config| config.default_options = { 'modlE' => 'opus' } }

        expect { described_class.new }.to raise_error(ArgumentError, /unknown ClaudeAgentOptions option: "modlE"/)
      end
    end

    context 'when no default options are configured' do
      it 'creates options with defaults unchanged' do
        options = described_class.new(model: 'haiku')

        expect(options.model).to eq('haiku')
        expect(options.allowed_tools).to eq([])
        expect(options.mcp_servers).to eq({})
      end

      it 'creates empty options when nothing provided' do
        options = described_class.new

        expect(options.model).to be_nil
        expect(options.allowed_tools).to eq([])
        expect(options.mcp_servers).to eq({})
      end
    end
  end
end
