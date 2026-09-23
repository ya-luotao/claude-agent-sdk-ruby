# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

# Issue #126: value types the user constructs and passes IN raise
# ArgumentError on an unknown key (1.0; 0.37 warned once); types parsed from
# CLI output — and every construction through .from_hash / .wrap — stay
# lenient.
RSpec.describe 'strict attributes on user-constructed types' do
  def capture_stderr
    captured = +''
    original = $stderr
    $stderr = StringIO.new(captured)
    begin
      yield
    ensure
      $stderr = original
    end
    captured
  end

  def camelize(name)
    name.to_s.gsub(/_([a-z\d])/) { Regexp.last_match(1).upcase }
  end

  # The classification the PR table documents. A new Type subclass must be
  # placed on one side deliberately.
  strict_names = %w[
    ThinkingConfigAdaptive ThinkingConfigEnabled ThinkingConfigDisabled AgentDefinition SdkPluginConfig
    SandboxNetworkConfig SandboxFilesystemConfig SandboxSettings TaskBudget
    SystemPromptFile SystemPromptPreset SystemPromptCustom ToolsPreset
    McpStdioServerConfig McpSSEServerConfig McpHttpServerConfig McpSdkServerConfig
    HookMatcher
    SetupHookSpecificOutput PreToolUseHookSpecificOutput PostToolUseHookSpecificOutput
    PostToolUseFailureHookSpecificOutput UserPromptSubmitHookSpecificOutput NotificationHookSpecificOutput
    SubagentStartHookSpecificOutput PermissionRequestHookSpecificOutput SessionStartHookSpecificOutput
    PermissionDeniedHookSpecificOutput CwdChangedHookSpecificOutput FileChangedHookSpecificOutput
    AsyncHookJSONOutput SyncHookJSONOutput
    PermissionRuleValue PermissionUpdate PermissionResultAllow PermissionResultDeny
  ].freeze

  all_types = ClaudeAgentSDK.constants.filter_map do |name|
    value = ClaudeAgentSDK.const_get(name)
    value if value.is_a?(Class) && value < ClaudeAgentSDK::Type
  end

  # Populated instances of every strict type, setting every attribute.
  hook = ->(_input, _tool_use_id, _context) { {} }
  fixtures = {
    'ThinkingConfigAdaptive' => { display: 'summarized' },
    'ThinkingConfigEnabled' => { budget_tokens: 2048, display: 'omitted' },
    'ThinkingConfigDisabled' => {},
    'AgentDefinition' => {
      description: 'Reviews code', prompt: 'You review code', tools: %w[Read Grep], disallowed_tools: %w[Bash],
      model: 'sonnet', skills: %w[review], memory: 'project', mcp_servers: %w[docs], initial_prompt: 'Start',
      max_turns: 4, background: true, effort: 'high', permission_mode: 'plan'
    },
    'SdkPluginConfig' => { path: '/plugins/demo' },
    'SandboxNetworkConfig' => {
      allowed_domains: %w[example.com], denied_domains: %w[evil.test], allow_managed_domains_only: false,
      allow_unix_sockets: %w[/tmp/s], allow_all_unix_sockets: false, allow_local_binding: true,
      allow_mach_lookup: %w[com.apple.x], http_proxy_port: 8080, socks_proxy_port: 1080
    },
    'SandboxFilesystemConfig' => {
      allow_write: %w[/tmp], deny_write: %w[/etc], deny_read: %w[/secret], allow_read: %w[/data],
      allow_managed_read_paths_only: false
    },
    'SandboxSettings' => {
      enabled: true, fail_if_unavailable: false, auto_allow_bash_if_sandboxed: true, excluded_commands: %w[git],
      allow_unsandboxed_commands: false, network: { allowedDomains: %w[example.com] },
      filesystem: { allowWrite: %w[/tmp] }, ignore_violations: { 'file' => ['/tmp/*'] },
      enable_weaker_nested_sandbox: false, enable_weaker_network_isolation: false, ripgrep: { command: 'rg' }
    },
    'TaskBudget' => { total: 50_000 },
    'SystemPromptFile' => { path: 'prompts/system.md' },
    'SystemPromptPreset' => { preset: 'claude_code', append: 'Be brief.', exclude_dynamic_sections: true, snapshot: false },
    'SystemPromptCustom' => { prompt: 'You are terse.', snapshot: true },
    'ToolsPreset' => { preset: 'claude_code' },
    'McpStdioServerConfig' => { command: 'npx', args: %w[server], env: { 'TOKEN' => 'x' } },
    'McpSSEServerConfig' => { url: 'https://example.com/sse', headers: { 'Authorization' => 'Bearer x' } },
    'McpHttpServerConfig' => { url: 'https://example.com/mcp', headers: { 'Authorization' => 'Bearer x' } },
    'McpSdkServerConfig' => { name: 'calc', instance: Object.new },
    'HookMatcher' => { matcher: 'Bash', hooks: [hook], timeout: 30 },
    'SetupHookSpecificOutput' => { additional_context: 'ctx' },
    'PreToolUseHookSpecificOutput' => {
      permission_decision: 'deny', permission_decision_reason: 'no', updated_input: { command: 'ls' },
      additional_context: 'ctx'
    },
    'PostToolUseHookSpecificOutput' => {
      additional_context: 'ctx', updated_mcp_tool_output: { ok: true }, updated_tool_output: 'out'
    },
    'PostToolUseFailureHookSpecificOutput' => { additional_context: 'ctx' },
    'UserPromptSubmitHookSpecificOutput' => { additional_context: 'ctx' },
    'NotificationHookSpecificOutput' => { additional_context: 'ctx' },
    'SubagentStartHookSpecificOutput' => { additional_context: 'ctx' },
    'PermissionRequestHookSpecificOutput' => { decision: { behavior: 'allow' } },
    'SessionStartHookSpecificOutput' => { additional_context: 'ctx' },
    'PermissionDeniedHookSpecificOutput' => { retry: true },
    'CwdChangedHookSpecificOutput' => { watch_paths: %w[/src] },
    'FileChangedHookSpecificOutput' => { watch_paths: %w[/src] },
    'AsyncHookJSONOutput' => { async: true, async_timeout: 1000 },
    'SyncHookJSONOutput' => {
      continue: false, suppress_output: true, stop_reason: 'done', decision: 'block', system_message: 'msg',
      reason: 'because', hook_specific_output: { hookEventName: 'PreToolUse', permissionDecision: 'deny' }
    },
    'PermissionRuleValue' => { tool_name: 'Bash', rule_content: 'git status' },
    'PermissionUpdate' => {
      type: 'addRules', behavior: 'allow', destination: 'localSettings',
      rules: [{ tool_name: 'Bash', rule_content: 'git status' }]
    },
    'PermissionResultAllow' => {
      updated_input: { command: 'ls' },
      updated_permissions: [{ type: 'setMode', mode: 'plan', destination: 'session' }]
    },
    'PermissionResultDeny' => { message: 'nope', interrupt: true }
  }

  it 'declares exactly the user-constructed types strict' do
    expect(all_types.select(&:strict_attributes?).map { |k| k.name.delete_prefix('ClaudeAgentSDK::') })
      .to match_array(strict_names)
  end

  it 'keeps ClaudeAgentOptions on its own raising validation' do
    expect(ClaudeAgentSDK::ClaudeAgentOptions.strict_attributes?).to be_falsey
    expect { ClaudeAgentSDK::ClaudeAgentOptions.new(modle: 'x') }
      .to raise_error(ArgumentError, /unknown ClaudeAgentOptions option/)
  end

  it 'has a populated fixture for every strict type' do
    expect(fixtures.keys).to match_array(strict_names)
  end

  strict_names.each do |name|
    describe "ClaudeAgentSDK::#{name}" do
      let(:klass) { ClaudeAgentSDK.const_get(name) }
      let(:instance) { klass.new(fixtures.fetch(name)) }

      it 'raises ArgumentError on an unknown attribute, naming the class, the key and the known attributes' do
        expect { klass.new(bogus_key: 1) }
          .to raise_error(ArgumentError, "ClaudeAgentSDK::#{name}: unknown attribute :bogus_key " \
                                         "(known: #{klass.attribute_names.join(', ')})")
        expect { klass.new('bogusKey' => 1) }
          .to raise_error(ArgumentError, /\AClaudeAgentSDK::#{name}: unknown attribute "bogusKey" \(known: /)
      end

      it 'constructs silently from its own attributes in any accepted spelling' do
        attributes = instance.instance_variables.to_h { |ivar| [ivar.to_s.delete_prefix('@').to_sym, instance.instance_variable_get(ivar)] }
        output = capture_stderr do
          klass.new(instance.to_h)
          klass.new(instance.to_h.transform_keys(&:to_s))
          klass.new(attributes)
          klass.new(attributes.transform_keys(&:to_s))
          klass.new(attributes.transform_keys { |key| camelize(key).to_sym })
          klass.new(klass.new.to_h)
        end

        expect(output).to eq('')
      end

      it 'stays lenient through from_hash and wrap' do
        output = capture_stderr do
          expect(klass.from_hash(bogus_key: 1)).to be_a(klass)
          expect(klass.wrap(bogus_key: 1)).to be_a(klass)
        end

        expect(output).to eq('')
      end
    end
  end

  it 'names the first unknown key it meets' do
    expect { ClaudeAgentSDK::HookMatcher.new(matchr: 'Bash') }
      .to raise_error(ArgumentError, 'ClaudeAgentSDK::HookMatcher: unknown attribute :matchr ' \
                                     '(known: hooks, matcher, timeout)')
    expect { ClaudeAgentSDK::HookMatcher.new('matcher' => 'Bash', timout: 5) }
      .to raise_error(ArgumentError, /unknown attribute :timout \(known: hooks, matcher, timeout\)/)
  end

  it 'raises on an unknown key assigned with #[]= and leaves the object unchanged' do
    matcher = ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash')

    expect { matcher[:matchr] = 'Read' }
      .to raise_error(ArgumentError, /ClaudeAgentSDK::HookMatcher: unknown attribute :matchr/)
    expect(matcher.matcher).to eq('Bash')
  end

  it 'names the nested type for an unknown key inside a nested value' do
    expect do
      ClaudeAgentSDK::PermissionUpdate.new(type: 'addRules', rules: [{ tool_name: 'Bash', rule_contnt: 'x' }])
    end.to raise_error(ArgumentError, /\AClaudeAgentSDK::PermissionRuleValue: unknown attribute :rule_contnt /)
  end

  it 'accepts every known spelling and the read-only discriminator' do
    expect { ClaudeAgentSDK::McpStdioServerConfig.new(type: 'stdio', command: 'npx', 'args' => []) }.not_to raise_error
    expect { ClaudeAgentSDK::PreToolUseHookSpecificOutput.new(hookEventName: 'PreToolUse', permissionDecision: 'deny') }
      .not_to raise_error
    expect { ClaudeAgentSDK::PermissionResultAllow.new(behavior: 'allow', updatedInput: {}) }.not_to raise_error
  end

  it 'keeps nested CLI data lenient under from_hash' do
    wire = { type: 'addRules', futureField: 1, rules: [{ toolName: 'Bash', ruleContent: 'ls', ruleScope: 'x' }] }
    update = nil
    output = capture_stderr { update = ClaudeAgentSDK::PermissionUpdate.from_hash(wire) }

    expect(output).to eq('')
    expect(update.rules.first.tool_name).to eq('Bash')
  end

  it 'restores the strict check after a lenient construction raises' do
    expect { ClaudeAgentSDK::ThinkingConfigAdaptive.from_hash(display: 'loud') }.to raise_error(ArgumentError)
    expect { ClaudeAgentSDK::ThinkingConfigAdaptive.new(bogus_key: 1) }
      .to raise_error(ArgumentError, /unknown attribute :bogus_key/)
  end

  it 'leaves CLI-parsed types lenient' do
    output = capture_stderr do
      (all_types - all_types.select(&:strict_attributes?) - [ClaudeAgentSDK::ClaudeAgentOptions]).each do |klass|
        expect { klass.new(future_cli_field: 1) }.not_to raise_error
      end
    end

    expect(output).to eq('')
  end
end
