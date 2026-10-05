# frozen_string_literal: true

require 'spec_helper'
require 'pathname'

# OptionForms reads every option that takes a typed value or the equivalent
# Hash. One group per function, each naming the key rule the option has
# always had:
#
#   truthy    hash[:key] || hash['key']
#   presence  hash.fetch(:key) { hash['key'] }
#
# option_forms_characterization_spec.rb pins the same rows where a caller
# sees them, on the command line and the initialize request.
RSpec.describe ClaudeAgentSDK::OptionForms do
  describe '.system_prompt' do
    # [kind, value] of the Prompt a system_prompt stands for.
    def prompt(value)
      result = described_class.system_prompt(value)
      [result.kind, result.value]
    end

    {
      'nil is the empty prompt' => [nil, [:empty, nil]],
      'a String is the text' => ['You are terse.', [:text, 'You are terse.']],
      'an empty String is a text, not the empty prompt' => ['', [:text, '']],
      'a SystemPromptCustom is its prompt' => [ClaudeAgentSDK::SystemPromptCustom.new(prompt: 'p'), [:text, 'p']],
      'a SystemPromptCustom without a prompt is a nil text, for the caller to refuse' => [
        ClaudeAgentSDK::SystemPromptCustom.new, [:text, nil]
      ],
      'a SystemPromptFile is its path' => [ClaudeAgentSDK::SystemPromptFile.new(path: 'a.md'), [:file, 'a.md']],
      'a SystemPromptFile without a path is still a file' => [ClaudeAgentSDK::SystemPromptFile.new, [:file, nil]],
      'a SystemPromptPreset with an append is the append' => [
        ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', append: 'x'), [:append, 'x']
      ],
      'a SystemPromptPreset without an append is no flag' => [ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code'), [:none, nil]],
      'custom Hash, Symbol keys' => [{ type: 'custom', prompt: 'p' }, [:text, 'p']],
      'custom Hash, String keys' => [{ 'type' => 'custom', 'prompt' => 'p' }, [:text, 'p']],
      'custom Hash, Symbol type' => [{ type: :custom, prompt: 'p' }, [:text, 'p']],
      'custom Hash, truthy tag: type nil then String key' => [{ type: nil, 'type' => 'custom', prompt: 'p' }, [:text, 'p']],
      'custom Hash, presence: prompt nil then String key is nil' => [{ type: 'custom', prompt: nil, 'prompt' => 'p' }, [:text, nil]],
      'custom Hash, presence: both prompt keys is the Symbol one' => [{ type: 'custom', 'prompt' => 's', prompt: 'p' }, [:text, 'p']],
      'custom Hash without a prompt is a nil text' => [{ type: 'custom' }, [:text, nil]],
      'custom Hash with a prompt that is no String keeps it' => [{ type: 'custom', prompt: 5 }, [:text, 5]],
      'file Hash, Symbol keys' => [{ type: 'file', path: 'a.md' }, [:file, 'a.md']],
      'file Hash, String keys' => [{ 'type' => :file, 'path' => 'a.md' }, [:file, 'a.md']],
      'file Hash, truthy fallback: path nil then String key' => [{ type: 'file', path: nil, 'path' => 'b.md' }, [:file, 'b.md']],
      'file Hash, truthy fallback: both path keys is the Symbol one' => [{ type: 'file', 'path' => 's.md', path: 'p.md' }, [:file, 'p.md']],
      'file Hash without a path is no flag' => [{ type: 'file' }, [:none, nil]],
      'file Hash with a false path is no flag' => [{ type: 'file', path: false }, [:none, nil]],
      'preset Hash, Symbol keys' => [{ type: 'preset', preset: 'claude_code', append: 'x' }, [:append, 'x']],
      'preset Hash, String keys' => [{ 'type' => 'preset', 'append' => 'x' }, [:append, 'x']],
      'preset Hash, truthy fallback: append nil then String key' => [{ type: 'preset', append: nil, 'append' => 'x' }, [:append, 'x']],
      'preset Hash, truthy fallback: append false then String key' => [{ type: 'preset', append: false, 'append' => 'x' }, [:append, 'x']],
      'preset Hash, truthy fallback: both append keys is the Symbol one' => [{ type: 'preset', 'append' => 's', append: 'x' }, [:append, 'x']],
      'preset Hash with an empty append sends it' => [{ type: 'preset', append: '' }, [:append, '']],
      'preset Hash without an append is no flag' => [{ type: 'preset' }, [:none, nil]],
      'a Hash with an unknown type is no flag' => [{ type: 'bogus', prompt: 'x' }, [:none, nil]],
      'a Hash without a type is no flag' => [{ prompt: 'x' }, [:none, nil]],
      'a Hash with a nil type is no flag' => [{ type: nil }, [:none, nil]],
      'an empty Hash is no flag' => [{}, [:none, nil]],
      'false is no flag, not the empty prompt' => [false, [:none, nil]],
      'a Symbol is no flag' => [:preset, [:none, nil]],
      'an Integer is no flag' => [5, [:none, nil]]
    }.each do |rule, (value, expected)|
      it(rule) { expect(prompt(value)).to eq(expected) }
    end

    it 'hands a Pathname on as it is, typed or in a Hash (the caller converts it)' do
      path = Pathname.new('prompts/a.md')

      expect(described_class.system_prompt(ClaudeAgentSDK::SystemPromptFile.new(path: path)).value).to equal(path)
      expect(described_class.system_prompt({ type: 'file', path: path }).value).to equal(path)
    end

    it 'answers a frozen record' do
      expect([nil, 'p', { type: 'preset' }].map { |value| described_class.system_prompt(value) }).to all(be_frozen)
    end
  end

  describe '.system_prompt_snapshot' do
    {
      'a SystemPromptPreset' => [ClaudeAgentSDK::SystemPromptPreset.new(snapshot: false), false],
      'a SystemPromptCustom' => [ClaudeAgentSDK::SystemPromptCustom.new(prompt: 'p', snapshot: true), true],
      'a SystemPromptPreset that leaves it unset' => [ClaudeAgentSDK::SystemPromptPreset.new, nil],
      'a SystemPromptFile' => [ClaudeAgentSDK::SystemPromptFile.new(path: 'a.md'), nil],
      'preset Hash, Symbol keys' => [{ type: 'preset', snapshot: false }, false],
      'preset Hash, String keys' => [{ 'type' => :preset, 'snapshot' => true }, true],
      'custom Hash' => [{ type: 'custom', prompt: 'p', snapshot: false }, false],
      'custom Hash whose prompt is no String (not looked at)' => [{ type: 'custom', prompt: nil, snapshot: false }, false],
      'truthy tag: type nil then String key' => [{ type: nil, 'type' => 'preset', snapshot: false }, false],
      'presence: snapshot nil then String key is nil' => [{ type: 'preset', snapshot: nil, 'snapshot' => false }, nil],
      'presence: both snapshot keys is the Symbol one' => [{ type: 'preset', 'snapshot' => true, snapshot: false }, false],
      'a value that is not a boolean' => [{ type: 'preset', snapshot: 'yes' }, nil],
      'file Hash' => [{ type: 'file', path: 'a.md', snapshot: false }, nil],
      'a Hash with an unknown type' => [{ type: 'bogus', snapshot: false }, nil],
      'a Hash without a type' => [{ snapshot: false }, nil],
      'a String' => ['You are terse.', nil],
      'nil' => [nil, nil]
    }.each do |form, (value, expected)|
      it("is #{expected.inspect} for #{form}") { expect(described_class.system_prompt_snapshot(value)).to eq(expected) }
    end
  end

  describe '.exclude_dynamic_sections' do
    {
      'a SystemPromptPreset' => [ClaudeAgentSDK::SystemPromptPreset.new(exclude_dynamic_sections: false), false],
      'a SystemPromptPreset that leaves it unset' => [ClaudeAgentSDK::SystemPromptPreset.new, nil],
      'a SystemPromptCustom' => [ClaudeAgentSDK::SystemPromptCustom.new(prompt: 'p'), nil],
      'preset Hash, Symbol keys' => [{ type: 'preset', exclude_dynamic_sections: true }, true],
      'preset Hash, String keys' => [{ 'type' => :preset, 'exclude_dynamic_sections' => false }, false],
      'truthy tag: type nil then String key' => [{ type: nil, 'type' => 'preset', exclude_dynamic_sections: true }, true],
      'presence: nil then String key is nil' => [
        { type: 'preset', exclude_dynamic_sections: nil, 'exclude_dynamic_sections' => true }, nil
      ],
      'presence: both keys is the Symbol one' => [
        { type: 'preset', 'exclude_dynamic_sections' => true, exclude_dynamic_sections: false }, false
      ],
      'a value that is not a boolean' => [{ type: 'preset', exclude_dynamic_sections: 1 }, nil],
      'custom Hash (the preset alone carries it)' => [{ type: 'custom', prompt: 'p', exclude_dynamic_sections: true }, nil],
      'a Hash without a type' => [{ exclude_dynamic_sections: true }, nil],
      'a String' => ['You are terse.', nil],
      'nil' => [nil, nil]
    }.each do |form, (value, expected)|
      it("is #{expected.inspect} for #{form}") { expect(described_class.exclude_dynamic_sections(value)).to eq(expected) }
    end
  end

  describe '.thinking' do
    # [type, budget_tokens, display] of the Thinking a value stands for.
    def fields(value)
      result = described_class.thinking(value)
      [result.type, result.budget_tokens, result.display]
    end

    {
      'a ThinkingConfigAdaptive' => [ClaudeAgentSDK::ThinkingConfigAdaptive.new(display: 'summarized'), ['adaptive', nil, 'summarized']],
      'a ThinkingConfigEnabled' => [ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 2048, display: 'omitted'), ['enabled', 2048, 'omitted']],
      'a ThinkingConfigEnabled without a budget' => [ClaudeAgentSDK::ThinkingConfigEnabled.new, ['enabled', nil, nil]],
      'a ThinkingConfigDisabled' => [ClaudeAgentSDK::ThinkingConfigDisabled.new, ['disabled', nil, nil]],
      'Hash, Symbol keys' => [{ type: 'enabled', budget_tokens: 2048, display: 'omitted' }, ['enabled', 2048, 'omitted']],
      'Hash, String keys' => [{ 'type' => 'adaptive', 'display' => :summarized }, ['adaptive', nil, :summarized]],
      'Hash, Symbol type as a String' => [{ type: :adaptive }, ['adaptive', nil, nil]],
      'Hash, truthy fallback: type nil then String key' => [{ type: nil, 'type' => 'disabled' }, ['disabled', nil, nil]],
      'Hash, truthy fallback: budget_tokens nil then String key' => [
        { type: 'enabled', budget_tokens: nil, 'budget_tokens' => 4096 }, ['enabled', 4096, nil]
      ],
      'Hash, truthy fallback: budget_tokens false is no budget' => [{ type: 'enabled', budget_tokens: false }, ['enabled', nil, nil]],
      'Hash, truthy fallback: display false then String key' => [
        { type: 'adaptive', display: false, 'display' => 'omitted' }, ['adaptive', nil, 'omitted']
      ],
      'Hash, truthy fallback: both budget keys is the Symbol one' => [
        { type: 'enabled', 'budget_tokens' => 4096, budget_tokens: 1024 }, ['enabled', 1024, nil]
      ],
      'Hash with a display the typed class refuses (not checked)' => [{ type: 'enabled', budget_tokens: 1, display: 'bogus' }, ['enabled', 1, 'bogus']],
      'Hash with a budget that is no Integer (not checked)' => [{ type: 'enabled', budget_tokens: '1' }, ['enabled', '1', nil]],
      'Hash with an unknown type keeps it, for the caller to refuse' => [{ type: 'bogus' }, ['bogus', nil, nil]],
      'Hash without a type has a nil type' => [{ budget_tokens: 2048 }, [nil, 2048, nil]],
      'a String has a nil type' => ['adaptive', [nil, nil, nil]],
      'true has a nil type' => [true, [nil, nil, nil]]
    }.each do |form, (value, expected)|
      it("reads #{form}") { expect(fields(value)).to eq(expected) }
    end

    it 'answers a frozen record' do
      expect(described_class.thinking({ type: 'adaptive' })).to be_frozen
    end
  end

  describe '.tools' do
    it 'is DEFAULT_TOOLS for the preset, typed or as a Hash in any spelling' do
      presets = [
        ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code'), { type: 'preset', preset: 'claude_code' },
        { 'type' => 'preset' }, { type: :preset }, { type: nil, 'type' => 'preset' }
      ]

      expect(presets.map { |value| described_class.tools(value) }).to all(equal(described_class::DEFAULT_TOOLS))
    end

    it 'is the value as it was given for every other one' do
      values = [%w[Read Grep], [], 'Read,Grep', '', { type: 'bogus', names: ['Read'] }, { names: ['Read'] }, {}, nil, 5, true]

      values.each { |value| expect(described_class.tools(value)).to equal(value) }
    end

    # `tools: :default` sends no flag, so the preset is not a Symbol.
    it 'does not take the Symbol :default for the preset' do
      expect(described_class.tools(:default)).to equal(:default)
      expect(described_class::DEFAULT_TOOLS).not_to eq(:default)
    end
  end

  describe '.output_schema' do
    schema = { type: 'object' }.freeze
    other = { type: 'array' }.freeze

    {
      'Symbol keys' => [{ type: 'json_schema', schema: schema }, schema],
      'String keys' => [{ 'type' => 'json_schema', 'schema' => schema }, schema],
      'a Symbol type' => [{ type: :json_schema, schema: schema }, schema],
      'a Symbol-keyed type and a String-keyed schema' => [{ type: 'json_schema', 'schema' => schema }, schema],
      'a String-keyed type and a Symbol-keyed schema' => [{ 'type' => 'json_schema', schema: schema }, schema],
      'tag spelling: a String-keyed type reads the String-keyed schema first' => [
        { 'type' => 'json_schema', 'schema' => schema, schema: other }, schema
      ],
      'tag spelling: a Symbol-keyed type reads the Symbol-keyed schema first' => [
        { type: 'json_schema', 'schema' => other, schema: schema }, schema
      ],
      'tag spelling: the Symbol-keyed type is looked at first' => [
        { type: 'json_schema', 'type' => 'text', 'schema' => other, schema: schema }, schema
      ],
      'tag spelling: the String-keyed type is looked at when the Symbol-keyed one is another' => [
        { type: 'text', 'type' => 'json_schema', 'schema' => schema, schema: other }, schema
      ],
      'presence: schema nil then String key is nil' => [{ type: 'json_schema', schema: nil, 'schema' => schema }, nil],
      'no schema is nil' => [{ type: 'json_schema' }, nil],
      'a false schema is false' => [{ type: 'json_schema', schema: false }, false],
      'a schema given as JSON text' => [{ type: 'json_schema', schema: '{}' }, '{}']
    }.each do |rule, (value, expected)|
      it(rule) { expect(described_class.output_schema(value)).to equal(expected) }
    end

    it 'is the value itself when it is not tagged json_schema' do
      [schema, { 'type' => 'text' }, {}, '{"type":"object"}', nil, false, :json].each do |value|
        expect(described_class.output_schema(value)).to equal(value)
      end
    end
  end

  describe '.task_budget_total' do
    {
      'a TaskBudget' => [ClaudeAgentSDK::TaskBudget.new(total: 5000), 5000],
      'a TaskBudget without a total' => [ClaudeAgentSDK::TaskBudget.new, nil],
      'Hash, Symbol key' => [{ total: 5000 }, 5000],
      'Hash, String key' => [{ 'total' => 5 }, 5],
      'truthy fallback: total nil then String key' => [{ total: nil, 'total' => 7 }, 7],
      'truthy fallback: total false then String key' => [{ total: false, 'total' => 7 }, 7],
      'truthy fallback: both total keys is the Symbol one' => [{ 'total' => 7, total: 3 }, 3],
      'an empty Hash' => [{}, nil],
      'nil' => [nil, nil],
      'false' => [false, nil]
    }.each do |form, (value, expected)|
      it("is #{expected.inspect} for #{form}") { expect(described_class.task_budget_total(value)).to eq(expected) }
    end

    # Read as a Hash, like every value that is not a TaskBudget.
    it 'fails loudly for a value that is no budget at all' do
      expect { described_class.task_budget_total(5) }.to raise_error(TypeError)
    end
  end

  describe '.plugin' do
    # [type_tag, path, raw_type] of the Plugin an entry stands for.
    def fields(value)
      result = described_class.plugin(value)
      [result.type_tag, result.path, result.raw_type]
    end

    {
      'a SdkPluginConfig' => [ClaudeAgentSDK::SdkPluginConfig.new(path: '/p'), ['local', '/p', 'local']],
      'a SdkPluginConfig without a path' => [ClaudeAgentSDK::SdkPluginConfig.new, ['local', nil, 'local']],
      'Hash, Symbol keys' => [{ type: 'local', path: '/p' }, ['local', '/p', 'local']],
      'Hash, String keys' => [{ 'type' => 'plugin', 'path' => '/p' }, ['plugin', '/p', 'plugin']],
      'Hash, Symbol type: the tag is a String, the raw type as written' => [{ type: :local, path: '/p' }, ['local', '/p', :local]],
      'Hash, truthy fallback: path nil then String key' => [{ type: 'local', path: nil, 'path' => '/b' }, ['local', '/b', 'local']],
      'Hash, truthy fallback: path false is no path' => [{ type: 'local', path: false }, ['local', nil, 'local']],
      'Hash, truthy fallback: type nil then String key' => [{ type: nil, 'type' => 'local', path: '/p' }, ['local', '/p', 'local']],
      'Hash, truthy fallback: both path keys is the Symbol one' => [{ type: 'local', 'path' => '/s', path: '/p' }, ['local', '/p', 'local']],
      'Hash with an unknown type keeps it, for the caller to refuse' => [{ type: :remote, path: '/x' }, ['remote', '/x', :remote]],
      'Hash without a type' => [{ path: '/x' }, ['', '/x', nil]]
    }.each do |form, (value, expected)|
      it("reads #{form}") { expect(fields(value)).to eq(expected) }
    end

    it 'hands a Pathname on as it is and answers a frozen record' do
      path = Pathname.new('/srv/plugins/review')
      result = described_class.plugin({ type: 'local', path: path })

      expect(result.path).to equal(path)
      expect(result).to be_frozen
      expect(path).not_to be_frozen
    end
  end

  describe '.sandbox' do
    wire = { enabled: true, autoAllowBashIfSandboxed: false, network: { deniedDomains: ['evil.example'] } }

    {
      'a SandboxSettings is its #to_h' => ClaudeAgentSDK::SandboxSettings.new(
        enabled: true, auto_allow_bash_if_sandboxed: false, network: { denied_domains: ['evil.example'] }
      ),
      'a snake_case Hash is renamed like the typed value' => {
        enabled: true, auto_allow_bash_if_sandboxed: false, network: { denied_domains: ['evil.example'] }
      },
      'a snake_case Hash with String keys' => {
        'enabled' => true, 'auto_allow_bash_if_sandboxed' => false, 'network' => { 'denied_domains' => ['evil.example'] }
      },
      'a camelCase Hash' => { 'enabled' => true, 'autoAllowBashIfSandboxed' => false, 'network' => { 'deniedDomains' => ['evil.example'] } },
      'a Hash holding a typed network' => {
        enabled: true, auto_allow_bash_if_sandboxed: false,
        network: ClaudeAgentSDK::SandboxNetworkConfig.new(denied_domains: ['evil.example'])
      }
    }.each do |rule, value|
      it(rule) { expect(described_class.sandbox(value)).to eq(wire) }
    end

    it 'sends the later of the two enabled keys of a Hash' do
      expect(described_class.sandbox({ enabled: true, 'enabled' => false })).to eq(enabled: false)
    end

    it 'is the value itself for a boolean, nil and anything else' do
      [true, false, nil, 'yes', [1]].each { |value| expect(described_class.sandbox(value)).to equal(value) }
    end

    it 'leaves the Hash it was given as it was' do
      given = { enabled: true, network: { denied_domains: ['evil.example'] } }

      described_class.sandbox(given)

      expect(given).to eq(enabled: true, network: { denied_domains: ['evil.example'] })
    end
  end

  describe '.sandbox_requested?' do
    {
      'true' => [true, true],
      'false' => [false, false],
      'nil' => [nil, false],
      'a SandboxSettings with enabled true' => [ClaudeAgentSDK::SandboxSettings.new(enabled: true), true],
      'a SandboxSettings with enabled false' => [ClaudeAgentSDK::SandboxSettings.new(enabled: false), false],
      'a SandboxSettings that leaves enabled unset' => [ClaudeAgentSDK::SandboxSettings.new, false],
      'Hash, Symbol key' => [{ enabled: true }, true],
      'Hash, String key' => [{ 'enabled' => true }, true],
      'any-true: Symbol key true, String key false' => [{ enabled: true, 'enabled' => false }, true],
      'any-true: Symbol key false, String key true' => [{ enabled: false, 'enabled' => true }, true],
      'Hash with enabled false' => [{ enabled: false }, false],
      'Hash whose enabled is truthy but not true' => [{ enabled: 'true', 'enabled' => 1 }, false],
      'an empty Hash' => [{}, false],
      'a truthy value that is not true' => ['true', false]
    }.each do |form, (value, expected)|
      it("is #{expected} for #{form}") { expect(described_class.sandbox_requested?(value)).to be(expected) }
    end

    # The transport asks from its stderr threads: nothing but the one read.
    it 'does not build the wire form of a typed value' do
      settings = ClaudeAgentSDK::SandboxSettings.new(enabled: true)
      allow(settings).to receive(:to_h).and_raise('to_h called')

      expect(described_class.sandbox_requested?(settings)).to be(true)
    end
  end

  describe '.mcp_servers and .sdk_mcp_servers' do
    server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: []).fetch(:instance)

    it 'strip the instance from the sdk entries whose instance they collect' do
      servers = {
        'symbols' => { type: 'sdk', name: 'a', instance: server },
        'strings' => { 'type' => 'sdk', 'name' => 'b', 'instance' => server },
        'symbol_type' => { type: :sdk, name: 'c', instance: server },
        'both_keys' => { type: 'sdk', name: 'd', instance: server, 'instance' => server },
        'typed' => ClaudeAgentSDK::McpSdkServerConfig.new(name: 'e', instance: server),
        'stdio_hash' => { type: 'stdio', command: 'node', instance: 'kept' },
        'stdio_typed' => ClaudeAgentSDK::McpStdioServerConfig.new(command: 'node')
      }

      expect(described_class.mcp_servers(servers)).to eq(
        'symbols' => { type: 'sdk', name: 'a' },
        'strings' => { 'type' => 'sdk', 'name' => 'b' },
        'symbol_type' => { type: :sdk, name: 'c' },
        'both_keys' => { type: 'sdk', name: 'd' },
        'typed' => { type: 'sdk', name: 'e' },
        'stdio_hash' => { type: 'stdio', command: 'node', instance: 'kept' },
        'stdio_typed' => { type: 'stdio', command: 'node' }
      )
      expect(described_class.sdk_mcp_servers(servers).keys).to eq(%w[symbols strings symbol_type both_keys typed])
      expect(described_class.sdk_mcp_servers(servers).values).to all(equal(server))
    end

    it 'recognize an sdk entry by a truthy tag: type nil then String key' do
      servers = { 'calc' => { type: nil, 'type' => 'sdk', 'instance' => server } }

      expect(described_class.mcp_servers(servers)).to eq('calc' => { type: nil, 'type' => 'sdk' })
      expect(described_class.sdk_mcp_servers(servers)).to eq('calc' => server)
    end

    it 'read the instance by presence: nil under the Symbol key is the instance' do
      servers = {
        'nil_symbol_key' => { type: 'sdk', instance: nil, 'instance' => server },
        'both_keys' => { type: 'sdk', 'instance' => nil, instance: server },
        'no_instance' => { type: 'sdk' }
      }

      expect(described_class.sdk_mcp_servers(servers)).to eq('nil_symbol_key' => nil, 'both_keys' => server, 'no_instance' => nil)
    end

    it 'hand a config that is neither typed nor a Hash on as it is' do
      expect(described_class.mcp_servers({ 'a' => 'x' })).to eq('a' => 'x')
      expect(described_class.sdk_mcp_servers({ 'a' => 'x' })).to eq({})
    end

    it 'answer a new Hash and leave the given one, its configs and its live server as they were' do
      config = { type: 'sdk', name: 'calc', instance: server }
      servers = { 'calc' => config }

      result = described_class.mcp_servers(servers)

      expect(result).not_to equal(servers)
      expect(servers).to eq('calc' => { type: 'sdk', name: 'calc', instance: server })
      expect(servers['calc']).to equal(config)
      expect(described_class.sdk_mcp_servers(servers)['calc']).to equal(server)
    end

    it 'hand a path, JSON text or nil on as they are, with no live servers' do
      ['config/mcp.json', '{"mcpServers":{}}', nil].each do |value|
        expect(described_class.mcp_servers(value)).to equal(value)
        expect(described_class.sdk_mcp_servers(value)).to eq({})
      end
    end
  end

  describe '.agent_definition' do
    it 'is the AgentDefinition itself' do
      agent = ClaudeAgentSDK::AgentDefinition.new(description: 'd', prompt: 'p')

      expect(described_class.agent_definition(agent)).to equal(agent)
    end

    it 'builds a Hash through AgentDefinition.new, in any key style' do
      agents = [
        { description: 'd', prompt: 'p', max_turns: 4 }, { 'description' => 'd', 'prompt' => 'p', 'max_turns' => 4 },
        { 'description' => 'd', 'prompt' => 'p', 'maxTurns' => 4 }
      ].map { |hash| described_class.agent_definition(hash) }

      expect(agents).to all(be_a(ClaudeAgentSDK::AgentDefinition))
      expect(agents.map { |agent| [agent.description, agent.prompt, agent.max_turns] }).to eq([['d', 'p', 4]] * 3)
    end

    # Attribute by attribute, in the order written.
    it 'reads the later of two spellings of one attribute' do
      expect(described_class.agent_definition({ 'prompt' => 'first', prompt: 'second' }).prompt).to eq('second')
    end

    it 'raises the strict-attribute error for a misspelled key' do
      expect { described_class.agent_definition({ description: 'd', promt: 'p' }) }
        .to raise_error(ArgumentError, /\AClaudeAgentSDK::AgentDefinition: unknown attribute :promt \(known: /)
    end
  end

  it 'keeps its Hash reader to itself' do
    expect { described_class::HashForm }.to raise_error(NameError, /private constant/)
  end
end
