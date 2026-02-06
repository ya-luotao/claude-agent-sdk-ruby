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

      # Test nil behavior for hashes and arrays
      context 'nil behavior for different types' do
        before do
          ClaudeAgentSDK.configure do |config|
            config.default_options = {
              model: 'sonnet',
              env: { 'DEFAULT_KEY' => 'value' },
              allowed_tools: ['Read', 'Write']
            }
          end
        end

        it 'uses default for scalar when nil is provided' do
          options = described_class.new(model: nil)
          expect(options.model).to eq('sonnet')
        end

        # Current behavior: nil for hash does NOT use default (inconsistent with scalars)
        it 'keeps nil for hash when nil is provided' do
          options = described_class.new(env: nil)
          expect(options.env).to be_nil
        end

        it 'replaces with empty array when empty array is provided' do
          options = described_class.new(allowed_tools: [])
          expect(options.allowed_tools).to eq([])
        end

        # Current behavior: empty hash merges with defaults, keeping defaults
        it 'merges empty hash with defaults' do
          options = described_class.new(env: {})
          # Empty hash merges, so defaults are kept
          expect(options.env).to eq({ 'DEFAULT_KEY' => 'value' })
        end

        # To replace defaults with empty hash, you would need to explicitly override all keys
        # This is a limitation of the current merge strategy
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
          original_env = options.env.dup

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
