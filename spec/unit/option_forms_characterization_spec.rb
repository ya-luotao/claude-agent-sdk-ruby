# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'json'
require 'open3'
require 'pathname'
require 'rbconfig'

# Several options take a typed value "or the equivalent Hash" (docs/options.md),
# and every reader of such a Hash has a rule of its own for the spelling of a
# key and for nil / false under it. This file records what those readers do,
# at the seams a caller can observe:
#
#   - the whole command line CommandBuilder#build returns
#   - the initialize request a session sends through its transport
#   - the class, the message and the raise site of the errors
#   - that an option Hash is stored, read back and re-read as the caller's
#     own object
#
# It was written against the readers as they stood when each lived next to
# its flag, and it is the gate for moving them: an expected value below
# changes only when the behaviour of the SDK is meant to change.
RSpec.describe 'an option given as a Hash, as the SDK reads it' do
  # The command line built for these options.
  def argv(**options)
    ClaudeAgentSDK::CommandBuilder.new('claude', ClaudeAgentSDK::ClaudeAgentOptions.new(**options)).build
  end

  # The whole command line of a session that sets +option+ alone, given the
  # flags that option becomes. An unset system_prompt is the empty prompt.
  def command_line(option, flags)
    prompt = option == :system_prompt ? [] : ['--system-prompt', '']
    ['claude', '--output-format', 'stream-json', '--verbose', *prompt, *flags, '--input-format', 'stream-json']
  end

  # What building the command line for these options raises (nil when it builds).
  def build_error(**options)
    argv(**options)
    nil
  rescue StandardError => e
    e
  end

  # One example per row of +rows+ (form => [value, the flags it becomes]),
  # each asserting the whole command line.
  def self.it_builds(option, rows, **metadata)
    rows.each do |form, (value, flags)|
      it "#{form}: #{flags.empty? ? 'no flag' : flags.map { |flag| flag || 'nil' }.join(' ')}", **metadata do
        expect(argv(option => value)).to eq(command_line(option, flags))
      end
    end
  end

  # One example per row of +rows+ (form => [value, message]), each asserting
  # the class and the message of what the build raises.
  def self.it_refuses(option, rows, **metadata)
    rows.each do |form, (value, message)|
      it "#{form}: raises #{message.inspect}", **metadata do
        expect(build_error(option => value)).to be_a(ArgumentError).and have_attributes(message: message)
      end
    end
  end

  describe 'system_prompt' do
    it_builds :system_prompt, {
      'nil' => [nil, ['--system-prompt', '']],
      'a String' => ['You are terse.', ['--system-prompt', 'You are terse.']],
      'an empty String' => ['', ['--system-prompt', '']],
      'a SystemPromptCustom' => [ClaudeAgentSDK::SystemPromptCustom.new(prompt: 'You are terse.'), ['--system-prompt', 'You are terse.']],
      'a SystemPromptFile' => [ClaudeAgentSDK::SystemPromptFile.new(path: 'prompts/a.md'), ['--system-prompt-file', 'prompts/a.md']],
      'a SystemPromptFile with a Pathname' => [
        ClaudeAgentSDK::SystemPromptFile.new(path: Pathname.new('prompts/a.md')), ['--system-prompt-file', 'prompts/a.md']
      ],
      'a SystemPromptPreset with an append' => [
        ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', append: 'Be brief.'), ['--append-system-prompt', 'Be brief.']
      ],
      'a SystemPromptPreset without an append' => [ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code'), []]
    }

    # The typed file prompt sends its flag whatever its path is; the Hash form
    # below sends it only for a path.
    it_builds :system_prompt, {
      'a SystemPromptFile without a path' => [ClaudeAgentSDK::SystemPromptFile.new, ['--system-prompt-file', nil]]
    }, rbs_incompatible: 'the command line carries nil, outside the signature of CommandBuilder#build'

    describe 'as a custom Hash' do
      it_builds :system_prompt, {
        'Symbol keys' => [{ type: 'custom', prompt: 'p' }, ['--system-prompt', 'p']],
        'String keys' => [{ 'type' => 'custom', 'prompt' => 'p' }, ['--system-prompt', 'p']],
        'a Symbol type' => [{ type: :custom, prompt: 'p' }, ['--system-prompt', 'p']],
        'a nil Symbol-keyed type next to a String-keyed one' => [{ type: nil, 'type' => 'custom', prompt: 'p' }, ['--system-prompt', 'p']],
        'an empty prompt' => [{ type: 'custom', prompt: '' }, ['--system-prompt', '']],
        'both prompt keys (the Symbol key is read)' => [
          { type: 'custom', 'prompt' => 'string key', prompt: 'symbol key' }, ['--system-prompt', 'symbol key']
        ]
      }

      it_refuses :system_prompt, {
        'no prompt' => [{ type: 'custom' }, "system_prompt of type 'custom' requires a :prompt String"],
        'a prompt that is not a String' => [{ type: 'custom', prompt: 5 }, "system_prompt of type 'custom' requires a :prompt String"],
        # Presence, not truthiness: a Symbol key holding nil is the prompt.
        'a nil Symbol-keyed prompt next to a String-keyed one' => [
          { type: 'custom', prompt: nil, 'prompt' => 'p' }, "system_prompt of type 'custom' requires a :prompt String"
        ],
        'a SystemPromptCustom without a prompt' => [
          ClaudeAgentSDK::SystemPromptCustom.new, "system_prompt of type 'custom' requires a :prompt String"
        ]
      }
    end

    describe 'as a file Hash' do
      it_builds :system_prompt, {
        'Symbol keys' => [{ type: 'file', path: 'prompts/a.md' }, ['--system-prompt-file', 'prompts/a.md']],
        'String keys' => [{ 'type' => 'file', 'path' => 'prompts/a.md' }, ['--system-prompt-file', 'prompts/a.md']],
        'a Symbol type' => [{ type: :file, path: 'prompts/a.md' }, ['--system-prompt-file', 'prompts/a.md']],
        'a Pathname' => [{ type: 'file', path: Pathname.new('prompts/a.md') }, ['--system-prompt-file', 'prompts/a.md']],
        'no path' => [{ type: 'file' }, []],
        'a false path' => [{ type: 'file', path: false }, []],
        # Truthiness, not presence: a nil Symbol key falls back to the String key.
        'a nil Symbol-keyed path next to a String-keyed one' => [
          { type: 'file', path: nil, 'path' => 'prompts/b.md' }, ['--system-prompt-file', 'prompts/b.md']
        ],
        'both path keys (the Symbol key is read)' => [
          { type: 'file', 'path' => 'string.md', path: 'symbol.md' }, ['--system-prompt-file', 'symbol.md']
        ]
      }
    end

    describe 'as a preset Hash' do
      it_builds :system_prompt, {
        'Symbol keys' => [{ type: 'preset', preset: 'claude_code', append: 'Be brief.' }, ['--append-system-prompt', 'Be brief.']],
        'String keys' => [
          { 'type' => 'preset', 'preset' => 'claude_code', 'append' => 'Be brief.' }, ['--append-system-prompt', 'Be brief.']
        ],
        'a Symbol type' => [{ type: :preset, append: 'Be brief.' }, ['--append-system-prompt', 'Be brief.']],
        'no append' => [{ type: 'preset', preset: 'claude_code' }, []],
        'an empty append' => [{ type: 'preset', append: '' }, ['--append-system-prompt', '']],
        # Truthiness, not presence.
        'a nil Symbol-keyed append next to a String-keyed one' => [
          { type: 'preset', append: nil, 'append' => 'x' }, ['--append-system-prompt', 'x']
        ],
        'a false Symbol-keyed append next to a String-keyed one' => [
          { type: 'preset', append: false, 'append' => 'x' }, ['--append-system-prompt', 'x']
        ],
        'both append keys (the Symbol key is read)' => [
          { type: 'preset', 'append' => 'string key', append: 'symbol key' }, ['--append-system-prompt', 'symbol key']
        ]
      }
    end

    # Not the empty prompt nil stands for: no prompt flag at all, so the CLI
    # runs with its default prompt.
    describe 'as a Hash the SDK does not recognize' do
      it_builds :system_prompt, {
        'an unknown type' => [{ type: 'bogus', prompt: 'x' }, []],
        'an unknown Symbol type' => [{ type: :bogus, prompt: 'x' }, []],
        'no type' => [{ prompt: 'x' }, []],
        'a nil type' => [{ type: nil }, []],
        'an empty Hash' => [{}, []]
      }
    end

    describe 'as a value that is none of its forms' do
      it_builds :system_prompt, {
        'false' => [false, []],
        'a Symbol' => [:preset, []],
        'an Integer' => [5, []]
      }, rbs_incompatible: 'passes a system_prompt outside its signature'
    end

    # options.rb merges a Hash given per call into a Hash configured as the
    # default, so a Hash with both spellings of a key does not take a caller
    # who wrote one twice.
    describe 'as a per-call Hash merged into a configured default' do
      after { ClaudeAgentSDK.reset_configuration }

      it 'reads the configured String-keyed append when the call passes append: nil' do
        ClaudeAgentSDK.configure { |config| config.default_options = { system_prompt: { 'type' => 'preset', 'append' => 'x' } } }
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: { append: nil })

        expect(options.system_prompt).to eq('type' => 'preset', 'append' => 'x', append: nil)
        expect(ClaudeAgentSDK::CommandBuilder.new('claude', options).build)
          .to eq(command_line(:system_prompt, ['--append-system-prompt', 'x']))
      end
    end
  end

  describe 'tools' do
    it_builds :tools, {
      'nil' => [nil, []],
      'an Array' => [%w[Read Grep], ['--tools', 'Read,Grep']],
      'an empty Array' => [[], ['--tools', '']],
      'a String' => ['Read,Grep', ['--tools', 'Read,Grep']],
      'an empty String' => ['', ['--tools', '']],
      'a ToolsPreset' => [ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code'), ['--tools', 'default']],
      'a preset Hash with Symbol keys' => [{ type: 'preset', preset: 'claude_code' }, ['--tools', 'default']],
      'a preset Hash with String keys' => [{ 'type' => 'preset', 'preset' => 'claude_code' }, ['--tools', 'default']],
      'a preset Hash with a Symbol type' => [{ type: :preset, preset: :claude_code }, ['--tools', 'default']],
      'a preset Hash with a nil Symbol-keyed type next to a String-keyed one' => [{ type: nil, 'type' => 'preset' }, ['--tools', 'default']],
      # Any other Hash is sent as JSON text, as it was written.
      'a Hash with an unknown type' => [{ type: 'bogus', names: ['Read'] }, ['--tools', '{"type":"bogus","names":["Read"]}']],
      'a Hash without a type' => [{ names: ['Read'] }, ['--tools', '{"names":["Read"]}']],
      'an empty Hash' => [{}, ['--tools', '{}']]
    }

    describe 'as a value that is none of its forms' do
      # In particular not the preset: `:default` is not a spelling of it.
      it_builds :tools, {
        'the Symbol :default' => [:default, []],
        'an Integer' => [5, []],
        'true' => [true, []]
      }, rbs_incompatible: 'passes tools outside its signature'
    end
  end

  describe 'sandbox' do
    wire = '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":false,"network":{"deniedDomains":["evil.example"]}}}'

    it_builds :sandbox, {
      'nil' => [nil, []],
      'true' => [true, ['--settings', '{"sandbox":true}']],
      'false' => [false, ['--settings', '{"sandbox":false}']],
      'an empty Hash' => [{}, ['--settings', '{"sandbox":{}}']],
      'a SandboxSettings' => [
        ClaudeAgentSDK::SandboxSettings.new(
          enabled: true, auto_allow_bash_if_sandboxed: false,
          network: ClaudeAgentSDK::SandboxNetworkConfig.new(denied_domains: ['evil.example'])
        ), ['--settings', wire]
      ],
      'a Hash with snake_case Symbol keys' => [
        { enabled: true, auto_allow_bash_if_sandboxed: false, network: { denied_domains: ['evil.example'] } }, ['--settings', wire]
      ],
      'a Hash with snake_case String keys' => [
        { 'enabled' => true, 'auto_allow_bash_if_sandboxed' => false, 'network' => { 'denied_domains' => ['evil.example'] } },
        ['--settings', wire]
      ],
      'a Hash with camelCase Symbol keys' => [
        { enabled: true, autoAllowBashIfSandboxed: false, network: { deniedDomains: ['evil.example'] } }, ['--settings', wire]
      ],
      'a Hash with camelCase String keys' => [
        { 'enabled' => true, 'autoAllowBashIfSandboxed' => false, 'network' => { 'deniedDomains' => ['evil.example'] } },
        ['--settings', wire]
      ],
      'a Hash holding a typed network' => [
        { enabled: true, auto_allow_bash_if_sandboxed: false,
          network: ClaudeAgentSDK::SandboxNetworkConfig.new(denied_domains: ['evil.example']) }, ['--settings', wire]
      ],
      'a Hash with a key the typed classes do not model' => [
        { enabled: true, allowAppleEvents: true }, ['--settings', '{"sandbox":{"enabled":true,"allowAppleEvents":true}}']
      ],
      # Within one spelling the later key is the one sent.
      'a Hash with both enabled keys' => [{ enabled: true, 'enabled' => false }, ['--settings', '{"sandbox":{"enabled":false}}']]
    }
  end

  describe 'task_budget' do
    it_builds :task_budget, {
      'nil' => [nil, []],
      'a TaskBudget' => [ClaudeAgentSDK::TaskBudget.new(total: 5000), ['--task-budget', '5000']],
      'a TaskBudget without a total' => [ClaudeAgentSDK::TaskBudget.new, []],
      'a Hash with a Symbol key' => [{ total: 5000 }, ['--task-budget', '5000']],
      'a Hash with a String key' => [{ 'total' => 5 }, ['--task-budget', '5']],
      'an empty Hash' => [{}, []],
      # Truthiness, not presence.
      'a nil Symbol-keyed total next to a String-keyed one' => [{ total: nil, 'total' => 7 }, ['--task-budget', '7']],
      'a false Symbol-keyed total next to a String-keyed one' => [{ total: false, 'total' => 7 }, ['--task-budget', '7']],
      'both total keys (the Symbol key is read)' => [{ 'total' => 7, total: 3 }, ['--task-budget', '3']]
    }
  end

  describe 'thinking' do
    it_builds :thinking, {
      'nil' => [nil, []],
      'a ThinkingConfigAdaptive' => [ClaudeAgentSDK::ThinkingConfigAdaptive.new, ['--thinking', 'adaptive']],
      'a ThinkingConfigAdaptive with a display' => [
        ClaudeAgentSDK::ThinkingConfigAdaptive.new(display: 'summarized'), ['--thinking', 'adaptive', '--thinking-display', 'summarized']
      ],
      'a ThinkingConfigEnabled' => [ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 2048), ['--max-thinking-tokens', '2048']],
      'a ThinkingConfigEnabled with a display' => [
        ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 2048, display: 'omitted'),
        ['--max-thinking-tokens', '2048', '--thinking-display', 'omitted']
      ],
      'a ThinkingConfigDisabled' => [ClaudeAgentSDK::ThinkingConfigDisabled.new, ['--thinking', 'disabled']],
      'an adaptive Hash with a Symbol key' => [{ type: 'adaptive' }, ['--thinking', 'adaptive']],
      'an adaptive Hash with a String key' => [{ 'type' => 'adaptive' }, ['--thinking', 'adaptive']],
      'an adaptive Hash with a Symbol type' => [{ type: :adaptive }, ['--thinking', 'adaptive']],
      'an adaptive Hash with a display' => [{ type: 'adaptive', display: 'omitted' }, ['--thinking', 'adaptive', '--thinking-display', 'omitted']],
      'an adaptive Hash with a Symbol display' => [
        { 'type' => 'adaptive', 'display' => :summarized }, ['--thinking', 'adaptive', '--thinking-display', 'summarized']
      ],
      'an enabled Hash with Symbol keys' => [{ type: 'enabled', budget_tokens: 2048 }, ['--max-thinking-tokens', '2048']],
      'an enabled Hash with String keys' => [{ 'type' => :enabled, 'budget_tokens' => 2048 }, ['--max-thinking-tokens', '2048']],
      # The typed classes check display; a Hash is forwarded as written.
      'an enabled Hash with a display the typed class refuses' => [
        { type: 'enabled', budget_tokens: 2048, display: 'bogus' }, ['--max-thinking-tokens', '2048', '--thinking-display', 'bogus']
      ],
      # Truthiness, not presence, for every field.
      'a nil Symbol-keyed type next to a String-keyed one' => [{ type: nil, 'type' => 'disabled' }, ['--thinking', 'disabled']],
      'a nil Symbol-keyed budget next to a String-keyed one' => [
        { type: 'enabled', budget_tokens: nil, 'budget_tokens' => 4096 }, ['--max-thinking-tokens', '4096']
      ],
      'a false Symbol-keyed display next to a String-keyed one' => [
        { type: 'adaptive', display: false, 'display' => 'omitted' }, ['--thinking', 'adaptive', '--thinking-display', 'omitted']
      ],
      'a false display' => [{ type: 'adaptive', display: false }, ['--thinking', 'adaptive']],
      'both budget keys (the Symbol key is read)' => [
        { type: 'enabled', 'budget_tokens' => 4096, budget_tokens: 1024 }, ['--max-thinking-tokens', '1024']
      ],
      'a disabled Hash with a display (not sent)' => [{ type: 'disabled', display: 'summarized' }, ['--thinking', 'disabled']]
    }

    it_refuses :thinking, {
      'an enabled Hash without a budget' => [{ type: 'enabled' }, "thinking type 'enabled' requires budget_tokens"],
      'an enabled Hash with a false budget' => [{ type: 'enabled', budget_tokens: false }, "thinking type 'enabled' requires budget_tokens"],
      'a ThinkingConfigEnabled without a budget' => [
        ClaudeAgentSDK::ThinkingConfigEnabled.new, "thinking type 'enabled' requires budget_tokens"
      ],
      'a Hash with an unknown type' => [{ type: 'bogus' }, "unsupported thinking config: #{{ type: 'bogus' }.inspect}"],
      'a Hash without a type' => [{ budget_tokens: 2048 }, "unsupported thinking config: #{{ budget_tokens: 2048 }.inspect}"],
      'an empty Hash' => [{}, 'unsupported thinking config: {}']
    }

    it_refuses :thinking, {
      'a String' => ['adaptive', 'unsupported thinking config: "adaptive"'],
      'true' => [true, 'unsupported thinking config: true']
    }, rbs_incompatible: 'passes thinking outside its signature'

    it 'takes the place of max_thinking_tokens, also as a Hash' do
      expect(argv(thinking: { type: 'adaptive' }, max_thinking_tokens: 512)).to eq(command_line(:thinking, ['--thinking', 'adaptive']))
    end
  end

  describe 'output_format' do
    schema = { type: 'object', properties: { verdict: { type: 'string' } } }.freeze
    other = { type: 'array' }.freeze
    schema_json = '{"type":"object","properties":{"verdict":{"type":"string"}}}'

    it_builds :output_format, {
      'nil' => [nil, []],
      'a json_schema Hash with Symbol keys' => [{ type: 'json_schema', schema: schema }, ['--json-schema', schema_json]],
      'a json_schema Hash with String keys' => [{ 'type' => 'json_schema', 'schema' => schema }, ['--json-schema', schema_json]],
      'a json_schema Hash with a Symbol type' => [{ type: :json_schema, schema: schema }, ['--json-schema', schema_json]],
      'a Symbol-keyed type and a String-keyed schema' => [{ type: 'json_schema', 'schema' => schema }, ['--json-schema', schema_json]],
      'a String-keyed type and a Symbol-keyed schema' => [{ 'type' => 'json_schema', schema: schema }, ['--json-schema', schema_json]],
      # The schema is read under the spelling its type was written in.
      'a String-keyed type and both schema keys' => [
        { 'type' => 'json_schema', 'schema' => schema, schema: other }, ['--json-schema', schema_json]
      ],
      'a Symbol-keyed type and both schema keys' => [
        { type: 'json_schema', 'schema' => other, schema: schema }, ['--json-schema', schema_json]
      ],
      'both type keys, and the Symbol-keyed one is json_schema' => [
        { type: 'json_schema', 'type' => 'text', 'schema' => other, schema: schema }, ['--json-schema', schema_json]
      ],
      'both type keys, and only the String-keyed one is json_schema' => [
        { type: 'text', 'type' => 'json_schema', 'schema' => schema, schema: other }, ['--json-schema', schema_json]
      ],
      # Presence, not truthiness: a nil schema in the type's spelling is no schema.
      'a nil Symbol-keyed schema next to a String-keyed one' => [{ type: 'json_schema', schema: nil, 'schema' => schema }, []],
      'no schema' => [{ type: 'json_schema' }, []],
      # Only nil is left out.
      'a false schema' => [{ type: 'json_schema', schema: false }, ['--json-schema', 'false']],
      'a schema given as JSON text' => [{ type: 'json_schema', schema: '{"type":"object"}' }, ['--json-schema', '{"type":"object"}']],
      # Any other value is the schema itself.
      'a Hash that is the schema' => [schema, ['--json-schema', schema_json]],
      'a Hash with another type under a String key' => [{ 'type' => 'text' }, ['--json-schema', '{"type":"text"}']],
      'an empty Hash' => [{}, ['--json-schema', '{}']],
      'a String' => ['{"type":"object"}', ['--json-schema', '{"type":"object"}']]
    }
  end

  describe 'mcp_servers' do
    server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: []).fetch(:instance)
    sdk_wire = '{"mcpServers":{"calc":{"type":"sdk","name":"calc"}}}'

    it_builds :mcp_servers, {
      'nil' => [nil, []],
      'an empty Hash' => [{}, []],
      'a path' => ['config/mcp.json', ['--mcp-config', 'config/mcp.json']],
      'JSON text' => ['{"mcpServers":{}}', ['--mcp-config', '{"mcpServers":{}}']],
      'a Hash config' => [
        { 'files' => { type: 'stdio', command: 'node', args: ['server.js'] } },
        ['--mcp-config', '{"mcpServers":{"files":{"type":"stdio","command":"node","args":["server.js"]}}}']
      ],
      'a typed config' => [
        { files: ClaudeAgentSDK::McpStdioServerConfig.new(command: 'node', args: ['server.js']) },
        ['--mcp-config', '{"mcpServers":{"files":{"type":"stdio","command":"node","args":["server.js"]}}}']
      ],
      # The live server of an sdk entry never reaches the command line.
      'an sdk Hash with Symbol keys' => [{ 'calc' => { type: 'sdk', name: 'calc', instance: server } }, ['--mcp-config', sdk_wire]],
      'an sdk Hash with String keys' => [
        { 'calc' => { 'type' => 'sdk', 'name' => 'calc', 'instance' => server } }, ['--mcp-config', sdk_wire]
      ],
      'an sdk Hash with a Symbol type' => [{ 'calc' => { type: :sdk, name: 'calc', instance: server } }, ['--mcp-config', sdk_wire]],
      'an sdk Hash with both instance keys' => [
        { 'calc' => { type: 'sdk', name: 'calc', instance: server, 'instance' => server } }, ['--mcp-config', sdk_wire]
      ],
      'a McpSdkServerConfig' => [
        { 'calc' => ClaudeAgentSDK::McpSdkServerConfig.new(name: 'calc', instance: server) }, ['--mcp-config', sdk_wire]
      ],
      # Only an sdk entry loses its instance key.
      'a Hash config of another type with an instance key' => [
        { 'files' => { type: 'stdio', command: 'node', instance: 'kept' } },
        ['--mcp-config', '{"mcpServers":{"files":{"type":"stdio","command":"node","instance":"kept"}}}']
      ]
    }

    # The same recognition picks the live servers a session registers
    # (ClaudeAgentSDK.extract_sdk_mcp_servers, called by Client and query).
    describe 'the live servers of its sdk entries' do
      it 'are found for a Hash in either key style, a Symbol type and the typed config' do
        servers = ClaudeAgentSDK.extract_sdk_mcp_servers(
          'symbols' => { type: 'sdk', name: 'a', instance: server },
          'strings' => { 'type' => 'sdk', 'name' => 'b', 'instance' => server },
          'symbol_type' => { type: :sdk, instance: server },
          'nil_symbol_type' => { type: nil, 'type' => 'sdk', 'instance' => server },
          'typed' => ClaudeAgentSDK::McpSdkServerConfig.new(name: 'c', instance: server),
          'stdio_hash' => { type: 'stdio', command: 'node', instance: server },
          'stdio_typed' => ClaudeAgentSDK::McpStdioServerConfig.new(command: 'node')
        )

        expect(servers.keys).to eq(%w[symbols strings symbol_type nil_symbol_type typed])
        expect(servers.values).to all(equal(server))
      end

      # Presence, not truthiness: a Symbol key holding nil is the instance.
      it 'are read under the Symbol key when it is present, whatever it holds' do
        servers = ClaudeAgentSDK.extract_sdk_mcp_servers(
          'nil_symbol_key' => { type: 'sdk', instance: nil, 'instance' => server },
          'both_keys' => { type: 'sdk', 'instance' => nil, instance: server },
          'no_instance' => { type: 'sdk' }
        )

        expect(servers.keys).to eq(%w[nil_symbol_key both_keys no_instance])
        expect(servers['nil_symbol_key']).to be_nil
        expect(servers['both_keys']).to equal(server)
        expect(servers['no_instance']).to be_nil
      end

      it 'are none for a path or nil' do
        expect([ClaudeAgentSDK.extract_sdk_mcp_servers('config/mcp.json'), ClaudeAgentSDK.extract_sdk_mcp_servers(nil)]).to eq([{}, {}])
      end
    end
  end

  describe 'plugins' do
    it_builds :plugins, {
      'nil' => [nil, []],
      'an empty Array' => [[], []],
      'a SdkPluginConfig' => [[ClaudeAgentSDK::SdkPluginConfig.new(path: '/srv/plugins/review')], ['--plugin-dir', '/srv/plugins/review']],
      'a SdkPluginConfig with a Pathname' => [
        [ClaudeAgentSDK::SdkPluginConfig.new(path: Pathname.new('/srv/plugins/review'))], ['--plugin-dir', '/srv/plugins/review']
      ],
      'a SdkPluginConfig without a path' => [[ClaudeAgentSDK::SdkPluginConfig.new], []],
      'a Hash with Symbol keys' => [[{ type: 'local', path: '/srv/plugins/review' }], ['--plugin-dir', '/srv/plugins/review']],
      'a Hash with String keys' => [[{ 'type' => 'local', 'path' => '/srv/plugins/review' }], ['--plugin-dir', '/srv/plugins/review']],
      'a Hash with a Symbol type' => [[{ type: :local, path: '/srv/plugins/review' }], ['--plugin-dir', '/srv/plugins/review']],
      'a Hash with the older type "plugin"' => [[{ type: 'plugin', path: '/srv/plugins/review' }], ['--plugin-dir', '/srv/plugins/review']],
      'a Hash with a Pathname' => [[{ type: 'local', path: Pathname.new('/srv/plugins/review') }], ['--plugin-dir', '/srv/plugins/review']],
      'a Hash without a path' => [[{ type: 'local' }], []],
      'a Hash with a false path' => [[{ type: 'local', path: false }], []],
      # Truthiness, not presence.
      'a nil Symbol-keyed path next to a String-keyed one' => [[{ type: 'local', path: nil, 'path' => '/b' }], ['--plugin-dir', '/b']],
      'a nil Symbol-keyed type next to a String-keyed one' => [[{ type: nil, 'type' => 'local', path: '/b' }], ['--plugin-dir', '/b']],
      'both path keys (the Symbol key is read)' => [[{ type: 'local', 'path' => '/string', path: '/symbol' }], ['--plugin-dir', '/symbol']],
      'several plugins, in the order given' => [
        [{ type: 'local', path: '/a' }, { type: 'local' }, ClaudeAgentSDK::SdkPluginConfig.new(path: '/c')],
        ['--plugin-dir', '/a', '--plugin-dir', '/c']
      ]
    }

    # The message names the type as it was written.
    it_refuses :plugins, {
      'an unknown type' => [[{ type: 'remote', path: '/x' }], 'Unsupported plugin type: "remote"'],
      'an unknown Symbol type' => [[{ type: :remote, path: '/x' }], 'Unsupported plugin type: :remote'],
      'an unknown type under a String key' => [[{ 'type' => 'remote', 'path' => '/x' }], 'Unsupported plugin type: "remote"'],
      'no type' => [[{ path: '/x' }], 'Unsupported plugin type: nil'],
      'an unknown type without a path' => [[{ type: 'remote' }], 'Unsupported plugin type: "remote"'],
      'an unknown type after a valid plugin' => [[{ type: 'local', path: '/a' }, { type: 'remote' }], 'Unsupported plugin type: "remote"']
    }
  end

  # The four errors a build raises for an option form are raised by
  # CommandBuilder itself, whichever module reads the Hash: the first frame of
  # the backtrace inside lib/ is command_builder.rb. (The file, not the line.)
  describe 'the raise site of a build error' do
    lib = "#{File.expand_path('../../lib', __dir__)}/"

    {
      'a custom system prompt Hash without a prompt' => { system_prompt: { type: 'custom' } },
      'a SystemPromptCustom without a prompt' => { system_prompt: ClaudeAgentSDK::SystemPromptCustom.new },
      'an enabled thinking Hash without a budget' => { thinking: { type: 'enabled' } },
      'a ThinkingConfigEnabled without a budget' => { thinking: ClaudeAgentSDK::ThinkingConfigEnabled.new },
      'a thinking Hash with an unknown type' => { thinking: { type: 'bogus' } },
      'a plugin Hash with an unknown type' => { plugins: [{ type: 'remote', path: '/x' }] }
    }.each do |form, options|
      it "is command_builder.rb for #{form}" do
        error = build_error(**options)
        frame = error.backtrace_locations.find { |location| location.absolute_path.to_s.start_with?(lib) }

        expect(error).to be_a(ArgumentError)
        expect(File.basename(frame.absolute_path)).to eq('command_builder.rb')
      end
    end
  end

  # CommandBuilder#build is public and signed, and command_builder.rb loads
  # what it needs: a process that requires that file alone can build.
  describe 'a process that requires only claude_agent_sdk/command_builder' do
    it 'builds the default command line without the root entry point' do
      script = <<~RUBY
        require 'claude_agent_sdk/command_builder'
        require 'json'
        argv = ClaudeAgentSDK::CommandBuilder.new('claude', ClaudeAgentSDK::ClaudeAgentOptions.new).build
        root_loaded = $LOADED_FEATURES.any? { |feature| feature.end_with?('/lib/claude_agent_sdk.rb') }
        puts JSON.generate('argv' => argv, 'root_loaded' => root_loaded)
      RUBY

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", '-e', script)

      expect(status).to be_success, stderr
      expect(JSON.parse(stdout)).to eq(
        'argv' => ['claude', '--output-format', 'stream-json', '--verbose', '--system-prompt', '', '--input-format', 'stream-json'],
        'root_loaded' => false
      )
    end
  end

  # agents, and the snapshot / exclude_dynamic_sections of a system prompt,
  # travel on the initialize request. End to end through the real control
  # protocol: a fake Transport records what happens to it, in order, and each
  # control request as the CLI's JSON parser sees it, and answers the request.
  # It builds no command line, like any transport that is not the subprocess
  # one.
  describe 'the initialize request' do
    let(:transport_class) do
      Class.new(ClaudeAgentSDK::Transport) do
        def initialize(_options, events:, requests:)
          super()
          @events = events
          @requests = requests
          @queue = Thread::Queue.new
        end

        def connect
          @events << :connect
          @ready = true
        end

        def ready? = @ready

        # The CLI ends its output once its input ends.
        def end_input = @queue.push(:eof)

        def close
          @events << :close
          @queue.push(:eof)
        end

        def write(data)
          message = JSON.parse(data, symbolize_names: true)
          return unless message[:type] == 'control_request'

          @events << :write
          @requests << JSON.parse(data).fetch('request')
          response = { subtype: 'success', request_id: message[:request_id], response: {} }
          @queue.push({ type: 'control_response', response: response })
        end

        def read_messages
          @events << :read_started
          loop do
            message = @queue.pop
            break if message == :eof

            yield message
          end
        end
      end
    end

    let(:events) { [] }
    let(:requests) { [] }

    # Connects a Client with these options. What the connect raised (nil when
    # it connected) is recorded as an :error event at the moment it reached
    # the caller, and returned.
    def connect_with(**options)
      Sync do
        client = ClaudeAgentSDK::Client.new(
          options: ClaudeAgentSDK::ClaudeAgentOptions.new(**options),
          transport_class: transport_class, transport_args: { events: events, requests: requests }
        )
        client.connect
        nil
      rescue StandardError => e
        events << :error
        e
      ensure
        client&.disconnect
      end
    end

    # The initialize request of a session with these options.
    def initialize_request(**options)
      error = connect_with(**options)
      raise error if error

      requests.find { |request| request['subtype'] == 'initialize' }
    end

    def prompt_fields(system_prompt)
      initialize_request(system_prompt: system_prompt).slice('excludeDynamicSections', 'systemPromptSnapshot')
    end

    describe 'for agents' do
      wire_agent = { 'description' => 'Reviews pull requests', 'prompt' => 'You review code.', 'disallowedTools' => ['Bash'], 'maxTurns' => 4 }

      {
        'an AgentDefinition' => ClaudeAgentSDK::AgentDefinition.new(
          description: 'Reviews pull requests', prompt: 'You review code.', disallowed_tools: ['Bash'], max_turns: 4
        ),
        'a Hash with Symbol keys' => { description: 'Reviews pull requests', prompt: 'You review code.', disallowed_tools: ['Bash'], max_turns: 4 },
        'a Hash with String keys' => {
          'description' => 'Reviews pull requests', 'prompt' => 'You review code.', 'disallowed_tools' => ['Bash'], 'max_turns' => 4
        },
        'a Hash with camelCase keys' => wire_agent
      }.each do |form, agent|
        it "carries #{form} under its wire keys" do
          expect(initialize_request(agents: { 'reviewer' => agent }).fetch('agents')).to eq('reviewer' => wire_agent)
        end
      end

      # A Hash is built through AgentDefinition.new, attribute by attribute in
      # the order written: of two spellings of one attribute the later wins.
      it 'reads the later of two spellings of one attribute' do
        agent = { 'prompt' => 'first', prompt: 'second', description: 'd' }

        expect(initialize_request(agents: { reviewer: agent }).fetch('agents')).to eq('reviewer' => { 'description' => 'd', 'prompt' => 'second' })
      end

      it 'carries no agents when there are none' do
        expect(initialize_request.fetch('agents')).to be_nil
      end

      # The Hash is checked where the request is built: after the transport
      # connected and the read loop started, before anything is written.
      it 'refuses a misspelled key once the read loop runs, and writes nothing' do
        error = connect_with(agents: { reviewer: { description: 'Reviews pull requests', promt: 'You review code.' } })

        expect(error).to be_a(ArgumentError)
        expect(error.message).to start_with('ClaudeAgentSDK::AgentDefinition: unknown attribute :promt (known: ')
        expect(events.first(2)).to eq(%i[connect read_started])
        expect(events.index(:read_started)).to be < events.index(:error)
        expect(events).to include(:close)
        expect(events).not_to include(:write)
        expect(requests).to be_empty
      end

      it 'refuses it at the same point in a one-shot query' do
        transport = transport_class.new(nil, events: events, requests: requests)
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(agents: { reviewer: { description: 'Reviews pull requests', promt: 'You review code.' } })

        expect { ClaudeAgentSDK.query(prompt: 'Review this.', options: options, transport: transport) { |_message| nil } }
          .to raise_error(ArgumentError, /\AClaudeAgentSDK::AgentDefinition: unknown attribute :promt \(known: /)
        expect(events.first(2)).to eq(%i[connect read_started])
        expect(events).to include(:close)
        expect(events).not_to include(:write)
        expect(requests).to be_empty
      end
    end

    describe 'for the snapshot and exclude_dynamic_sections of a system prompt' do
      both_false = { 'excludeDynamicSections' => false, 'systemPromptSnapshot' => false }

      {
        'a SystemPromptPreset' => [
          ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', snapshot: false, exclude_dynamic_sections: false), both_false
        ],
        'a preset Hash with Symbol keys' => [{ type: 'preset', snapshot: false, exclude_dynamic_sections: false }, both_false],
        'a preset Hash with String keys' => [{ 'type' => 'preset', 'snapshot' => false, 'exclude_dynamic_sections' => false }, both_false],
        'a preset Hash with a Symbol type' => [{ type: :preset, snapshot: false, exclude_dynamic_sections: false }, both_false],
        'a preset Hash with a nil Symbol-keyed type next to a String-keyed one' => [
          { type: nil, 'type' => 'preset', snapshot: false, exclude_dynamic_sections: false }, both_false
        ],
        'a preset Hash with true values' => [
          { type: 'preset', snapshot: true, exclude_dynamic_sections: true }, { 'excludeDynamicSections' => true, 'systemPromptSnapshot' => true }
        ],
        'a SystemPromptCustom' => [ClaudeAgentSDK::SystemPromptCustom.new(prompt: 'p', snapshot: false), { 'systemPromptSnapshot' => false }],
        # exclude_dynamic_sections belongs to the preset alone.
        'a custom Hash' => [{ type: 'custom', prompt: 'p', snapshot: false, exclude_dynamic_sections: true }, { 'systemPromptSnapshot' => false }],
        # Presence, not truthiness: the Symbol key is the one read when it is there.
        'both keys of each field (the Symbol keys are read)' => [
          { type: 'preset', 'snapshot' => true, snapshot: false, 'exclude_dynamic_sections' => true, exclude_dynamic_sections: false }, both_false
        ],
        'nil Symbol keys next to String keys' => [
          { type: 'preset', snapshot: nil, 'snapshot' => false, exclude_dynamic_sections: nil, 'exclude_dynamic_sections' => true }, {}
        ],
        # Only true and false are sent.
        'values that are not booleans' => [{ type: 'preset', snapshot: 'yes', exclude_dynamic_sections: 1 }, {}],
        'a preset Hash without the fields' => [{ type: 'preset', append: 'x' }, {}],
        'a file Hash' => [{ type: 'file', path: 'prompts/a.md', snapshot: false, exclude_dynamic_sections: true }, {}],
        'a Hash with an unknown type' => [{ type: 'bogus', snapshot: false, exclude_dynamic_sections: true }, {}],
        'a Hash without a type' => [{ snapshot: false, exclude_dynamic_sections: true }, {}],
        'a String' => ['You are terse.', {}],
        'nil' => [nil, {}]
      }.each do |form, (system_prompt, fields)|
        it "carries #{fields.empty? ? 'neither field' : fields.inspect} for #{form}" do
          expect(prompt_fields(system_prompt)).to eq(fields)
        end
      end

      # The command line is where a custom prompt's text is checked. A session
      # over a transport that builds none still gets its snapshot through.
      it 'does not check the text of a custom prompt' do
        expect(prompt_fields({ type: 'custom', prompt: nil, snapshot: false })).to eq('systemPromptSnapshot' => false)
        expect(events.first(3)).to eq(%i[connect read_started write])
        expect(events).not_to include(:error)
      end

      it 'carries them in a one-shot query too' do
        transport = transport_class.new(nil, events: events, requests: requests)
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          system_prompt: { 'type' => :preset, 'snapshot' => false, 'exclude_dynamic_sections' => true },
          agents: { reviewer: { description: 'd', prompt: 'p' } }
        )

        ClaudeAgentSDK.query(prompt: 'Review this.', options: options, transport: transport) { |_message| nil }

        expect(requests.find { |request| request['subtype'] == 'initialize' }).to include(
          'agents' => { 'reviewer' => { 'description' => 'd', 'prompt' => 'p' } },
          'excludeDynamicSections' => true, 'systemPromptSnapshot' => false
        )
      end
    end
  end

  # ClaudeAgentOptions stores the Hash it was given, and every build reads it
  # again: nothing derived from it is kept anywhere.
  describe 'the Hash the caller passed' do
    server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: []).fetch(:instance)

    # option => [the Hash, what the caller then does to it, the flags before, the flags after]
    {
      sandbox: [
        -> { { enabled: true } }, ->(hash) { hash[:enabled] = false },
        ['--settings', '{"sandbox":{"enabled":true}}'], ['--settings', '{"sandbox":{"enabled":false}}']
      ],
      system_prompt: [
        -> { { type: 'preset', append: 'first' } }, ->(hash) { hash[:append] = 'second' },
        ['--append-system-prompt', 'first'], ['--append-system-prompt', 'second']
      ],
      output_format: [
        -> { { type: 'json_schema', schema: { type: 'object' } } }, ->(hash) { hash[:schema] = { type: 'array' } },
        ['--json-schema', '{"type":"object"}'], ['--json-schema', '{"type":"array"}']
      ],
      tools: [
        -> { { type: 'preset', preset: 'claude_code' } }, ->(hash) { hash[:type] = 'list' },
        ['--tools', 'default'], ['--tools', '{"type":"list","preset":"claude_code"}']
      ],
      mcp_servers: [
        -> { { 'calc' => { type: 'sdk', name: 'calc', instance: server } } }, ->(hash) { hash['calc'][:name] = 'renamed' },
        ['--mcp-config', '{"mcpServers":{"calc":{"type":"sdk","name":"calc"}}}'],
        ['--mcp-config', '{"mcpServers":{"calc":{"type":"sdk","name":"renamed"}}}']
      ],
      thinking: [
        -> { { type: 'enabled', budget_tokens: 1024 } }, ->(hash) { hash[:budget_tokens] = 2048 },
        ['--max-thinking-tokens', '1024'], ['--max-thinking-tokens', '2048']
      ],
      task_budget: [
        -> { { total: 100 } }, ->(hash) { hash[:total] = 200 },
        ['--task-budget', '100'], ['--task-budget', '200']
      ],
      plugins: [
        -> { [{ type: 'local', path: '/a' }] }, ->(list) { list.first[:path] = '/b' },
        ['--plugin-dir', '/a'], ['--plugin-dir', '/b']
      ]
    }.each do |option, (given, change, flags_before, flags_after)|
      it "is the #{option} the options hold, unchanged by a build and read again by the next" do
        value = given.call
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(option => value)
        builder = ClaudeAgentSDK::CommandBuilder.new('claude', options)

        expect(options.public_send(option)).to equal(value)
        expect(builder.build).to eq(command_line(option, flags_before))
        expect(options.public_send(option)).to equal(value)
        expect(value).to eq(given.call)

        change.call(value)

        expect(builder.build).to eq(command_line(option, flags_after))
        expect(ClaudeAgentSDK::CommandBuilder.new('claude', options).build).to eq(command_line(option, flags_after))
      end
    end

    it 'is the mcp_servers Hash whose live server a session registers' do
      mcp_servers = { 'calc' => { 'type' => 'sdk', 'name' => 'calc', 'instance' => server } }
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(mcp_servers: mcp_servers)

      expect(ClaudeAgentSDK.extract_sdk_mcp_servers(options.mcp_servers)).to eq('calc' => server)
      expect(options.mcp_servers).to equal(mcp_servers)
      expect(mcp_servers).to eq('calc' => { 'type' => 'sdk', 'name' => 'calc', 'instance' => server })

      mcp_servers['calc']['type'] = 'stdio'

      expect(ClaudeAgentSDK.extract_sdk_mcp_servers(options.mcp_servers)).to eq({})
    end
  end
end
