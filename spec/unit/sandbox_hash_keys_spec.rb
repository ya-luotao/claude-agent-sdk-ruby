# frozen_string_literal: true

require 'spec_helper'
require 'json'

# `sandbox:` takes a typed SandboxSettings or a Hash, and a SandboxSettings
# takes a typed or a Hash `network` / `filesystem`. The typed classes have
# snake_case attributes and write the camelCase keys the CLI reads; a Hash
# used to be forwarded as written. The CLI's sandbox schema keeps unknown keys
# at the top level and strips them below it, so `deny_read`, `denied_domains`
# or `auto_allow_bash_if_sandboxed` were accepted without an error and never
# applied: the session ran with a weaker sandbox than the one written.
#
# The examples assert on the --settings argument the CLI is started with (and
# on SandboxSettings#to_h, the public form of the same section).
RSpec.describe 'sandbox settings written as a Hash' do
  # The --settings argument built for this `sandbox:` option.
  def settings_argument(sandbox, **options)
    cmd = ClaudeAgentSDK::CommandBuilder.new(
      '/usr/bin/claude', ClaudeAgentSDK::ClaudeAgentOptions.new(sandbox: sandbox, **options)
    ).build
    cmd[cmd.index('--settings') + 1]
  end

  # Its sandbox section, as the CLI's JSON parser reads it.
  def sandbox_section(sandbox)
    JSON.parse(settings_argument(sandbox)).fetch('sandbox')
  end

  # What JSON makes of a Ruby value (Symbol keys become Strings).
  def on_the_wire(value)
    JSON.parse(JSON.generate(value))
  end

  describe 'the same sandbox, written three ways' do
    typed = ClaudeAgentSDK::SandboxSettings.new(
      enabled: true, auto_allow_bash_if_sandboxed: false, excluded_commands: ['docker'],
      network: ClaudeAgentSDK::SandboxNetworkConfig.new(denied_domains: ['evil.example']),
      filesystem: ClaudeAgentSDK::SandboxFilesystemConfig.new(deny_read: ['/private/etc/ssh'])
    )
    snake_case_hash = {
      enabled: true, auto_allow_bash_if_sandboxed: false, excluded_commands: ['docker'],
      network: { denied_domains: ['evil.example'] },
      filesystem: { deny_read: ['/private/etc/ssh'] }
    }
    typed_outer_hash_inner = ClaudeAgentSDK::SandboxSettings.new(
      enabled: true, auto_allow_bash_if_sandboxed: false, excluded_commands: ['docker'],
      network: { denied_domains: ['evil.example'] },
      filesystem: { deny_read: ['/private/etc/ssh'] }
    )

    it 'reaches the CLI under its own keys when every level is typed' do
      expect(settings_argument(typed)).to eq(
        '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":false,"excludedCommands":["docker"],' \
        '"network":{"deniedDomains":["evil.example"]},"filesystem":{"denyRead":["/private/etc/ssh"]}}}'
      )
    end

    it 'builds the identical --settings value from a snake_case Hash' do
      expect(settings_argument(snake_case_hash)).to eq(settings_argument(typed))
    end

    it 'builds the identical --settings value from a typed SandboxSettings holding snake_case Hashes' do
      expect(settings_argument(typed_outer_hash_inner)).to eq(settings_argument(typed))
    end

    it 'gives SandboxSettings#to_h the keys a typed network and filesystem give it' do
      expect(typed_outer_hash_inner.to_h).to eq(typed.to_h)
    end

    it 'builds it from a snake_case Hash with String keys, such as one read from YAML or JSON' do
      expect(settings_argument(JSON.parse(JSON.generate(snake_case_hash)))).to eq(settings_argument(typed))
    end

    it 'still merges into settings that carry their own sandbox section' do
      settings = '{"permissions":{"deny":["WebFetch"]},"sandbox":{"enabled":false}}'

      expect(JSON.parse(settings_argument(snake_case_hash, settings: settings))).to eq(
        'permissions' => { 'deny' => ['WebFetch'] }, 'sandbox' => on_the_wire(typed.to_h)
      )
    end
  end

  # Every field of the three sandbox classes: attribute => [wire key, value].
  # The wire keys are spelled out here, not derived from the SDK, so a renamed
  # key on either side fails the examples below.
  network_fields = {
    allowed_domains: ['allowedDomains', %w[rubygems.org *.github.com]],
    denied_domains: ['deniedDomains', %w[evil.example]],
    allow_managed_domains_only: ['allowManagedDomainsOnly', false],
    allow_unix_sockets: ['allowUnixSockets', %w[/var/run/docker.sock]],
    allow_all_unix_sockets: ['allowAllUnixSockets', false],
    allow_local_binding: ['allowLocalBinding', true],
    allow_mach_lookup: ['allowMachLookup', %w[com.apple.coreservices.launchservicesd]],
    http_proxy_port: ['httpProxyPort', 8080],
    socks_proxy_port: ['socksProxyPort', 1080]
  }.freeze

  filesystem_fields = {
    allow_write: ['allowWrite', %w[/work/app/tmp]],
    deny_write: ['denyWrite', %w[/work/app/config]],
    deny_read: ['denyRead', %w[/private/etc/ssh ~/.aws]],
    allow_read: ['allowRead', %w[/work/app]],
    allow_managed_read_paths_only: ['allowManagedReadPathsOnly', false]
  }.freeze

  # `network` and `filesystem` are attributes too; each form below fills them
  # in with the nested section in the spelling it is about.
  top_level_fields = {
    enabled: ['enabled', true],
    fail_if_unavailable: ['failIfUnavailable', true],
    auto_allow_bash_if_sandboxed: ['autoAllowBashIfSandboxed', false],
    excluded_commands: ['excludedCommands', %w[docker]],
    allow_unsandboxed_commands: ['allowUnsandboxedCommands', false],
    network: ['network', nil],
    filesystem: ['filesystem', nil],
    ignore_violations: ['ignoreViolations', { 'file' => ['/tmp/*'], 'network' => ['localhost'] }],
    enable_weaker_nested_sandbox: ['enableWeakerNestedSandbox', false],
    enable_weaker_network_isolation: ['enableWeakerNetworkIsolation', false],
    ripgrep: ['ripgrep', { 'command' => '/usr/bin/rg', 'args' => ['--hidden'] }]
  }.freeze

  # The spellings a Hash may use for those fields.
  spellings = {
    'snake_case Symbol keys' => ->(fields) { fields.transform_values(&:last) },
    'snake_case String keys' => ->(fields) { fields.to_h { |name, (_wire, value)| [name.to_s, value] } },
    'camelCase Symbol keys' => ->(fields) { fields.to_h { |_name, (wire, value)| [wire.to_sym, value] } },
    'camelCase String keys' => ->(fields) { fields.to_h { |_name, (wire, value)| [wire, value] } }
  }.freeze
  attributes_of = spellings.fetch('snake_case Symbol keys')
  wire_form_of = spellings.fetch('camelCase String keys')

  # The top-level fields around one network and one filesystem section.
  around_sections = lambda do |network, filesystem|
    top_level_fields.merge(network: ['network', network], filesystem: ['filesystem', filesystem])
  end

  describe 'every field of every sandbox class' do
    # The section the CLI must receive, whichever way it was written.
    wire = wire_form_of.call(
      around_sections.call(wire_form_of.call(network_fields), wire_form_of.call(filesystem_fields))
    )

    it 'has a field for every attribute' do
      expect(
        'SandboxSettings' => top_level_fields.keys.map(&:to_s).sort,
        'SandboxNetworkConfig' => network_fields.keys.map(&:to_s).sort,
        'SandboxFilesystemConfig' => filesystem_fields.keys.map(&:to_s).sort
      ).to eq(
        'SandboxSettings' => ClaudeAgentSDK::SandboxSettings.attribute_names,
        'SandboxNetworkConfig' => ClaudeAgentSDK::SandboxNetworkConfig.attribute_names,
        'SandboxFilesystemConfig' => ClaudeAgentSDK::SandboxFilesystemConfig.attribute_names
      )
    end

    it 'is written under its wire key when every level is typed' do
      typed = ClaudeAgentSDK::SandboxSettings.new(
        attributes_of.call(
          around_sections.call(
            ClaudeAgentSDK::SandboxNetworkConfig.new(attributes_of.call(network_fields)),
            ClaudeAgentSDK::SandboxFilesystemConfig.new(attributes_of.call(filesystem_fields))
          )
        )
      )

      expect(sandbox_section(typed)).to eq(wire)
    end

    spellings.each do |inner_spelling, inner|
      it "is written the same way from a typed SandboxSettings holding Hashes with #{inner_spelling}" do
        sandbox = ClaudeAgentSDK::SandboxSettings.new(
          attributes_of.call(around_sections.call(inner.call(network_fields), inner.call(filesystem_fields)))
        )

        expect(sandbox_section(sandbox)).to eq(wire)
      end

      spellings.each do |outer_spelling, outer|
        it "is written the same way from a Hash with #{outer_spelling} holding Hashes with #{inner_spelling}" do
          sandbox = outer.call(around_sections.call(inner.call(network_fields), inner.call(filesystem_fields)))

          expect(sandbox_section(sandbox)).to eq(wire)
        end
      end
    end
  end

  # The vocabulary is a hand-written table next to the typed classes. Walk
  # every attribute of every class so the two cannot drift: a new attribute,
  # or a renamed wire key in a #to_h, fails here until the table follows.
  describe 'ClaudeAgentSDK::SandboxKeys' do
    {
      'TOP_LEVEL' => ['SandboxSettings', around_sections.call({ deniedDomains: %w[evil.example] }, { denyRead: %w[~/.aws] })],
      'NETWORK' => ['SandboxNetworkConfig', network_fields],
      'FILESYSTEM' => ['SandboxFilesystemConfig', filesystem_fields]
    }.each do |table_name, (class_name, fields)|
      describe table_name do
        let(:table) { ClaudeAgentSDK::SandboxKeys.const_get(table_name) }
        let(:klass) { ClaudeAgentSDK.const_get(class_name) }

        it "maps every #{class_name} attribute to the key its #to_h emits for it" do
          emitted = klass.attribute_names.to_h do |name|
            [name, klass.new(name => fields.fetch(name.to_sym).last).to_h.keys]
          end

          expect(table.transform_values { |wire_key| [wire_key] }).to eq(emitted)
        end

        it 'agrees with the wire keys this file spells out' do
          expect(table).to eq(fields.to_h { |name, (wire_key, _value)| [name.to_s, wire_key.to_sym] })
        end
      end
    end
  end

  describe 'a key the typed classes do not model' do
    # allowAppleEvents, network.strictAllowlist and filesystem.disabled are
    # fields of CLI 2.1.287's sandbox schema that no typed class has yet; a
    # Hash is the only way to send them.
    it 'is sent as written, at every level' do
      sandbox = {
        enabled: true,
        allowAppleEvents: true,
        future_field: { inner_key: 1 },
        'x-vendor' => nil,
        network: { denied_domains: ['evil.example'], strictAllowlist: true, future_field: 1 },
        filesystem: { deny_read: ['~/.aws'], 'disabled' => false, 'future_field' => [2] }
      }

      expect(sandbox_section(sandbox)).to eq(
        'enabled' => true,
        'allowAppleEvents' => true,
        'future_field' => { 'inner_key' => 1 },
        'x-vendor' => nil,
        'network' => { 'deniedDomains' => ['evil.example'], 'strictAllowlist' => true, 'future_field' => 1 },
        'filesystem' => { 'denyRead' => ['~/.aws'], 'disabled' => false, 'future_field' => [2] }
      )
    end

    it 'is sent as written inside a typed SandboxSettings too' do
      sandbox = ClaudeAgentSDK::SandboxSettings.new(
        enabled: true,
        network: { denied_domains: ['evil.example'], strictAllowlist: true },
        filesystem: { 'deny_read' => ['~/.aws'], 'disabled' => false }
      )

      expect(sandbox_section(sandbox)).to eq(
        'enabled' => true,
        'network' => { 'deniedDomains' => ['evil.example'], 'strictAllowlist' => true },
        'filesystem' => { 'denyRead' => ['~/.aws'], 'disabled' => false }
      )
      expect(sandbox.to_h).to eq(
        enabled: true,
        network: { deniedDomains: ['evil.example'], strictAllowlist: true },
        filesystem: { denyRead: ['~/.aws'], 'disabled' => false }
      )
    end

    it 'includes a name the SDK only knows at another level' do
      sandbox = {
        enabled: true,
        deny_read: ['~/.aws'],
        network: { excluded_commands: ['docker'], deny_read: ['~/.aws'] },
        filesystem: { denied_domains: ['evil.example'], auto_allow_bash_if_sandboxed: false }
      }

      expect(sandbox_section(sandbox)).to eq(
        'enabled' => true,
        'deny_read' => ['~/.aws'],
        'network' => { 'excluded_commands' => ['docker'], 'deny_read' => ['~/.aws'] },
        'filesystem' => { 'denied_domains' => ['evil.example'], 'auto_allow_bash_if_sandboxed' => false }
      )
    end
  end

  describe 'the value of a field' do
    # ignore_violations and ripgrep hold Hashes of their own, and no typed
    # class models what is inside them: a key in there that happens to be
    # spelled like a sandbox field is not one.
    it 'is not rewritten' do
      inner = { command: '/usr/bin/rg', args: ['--hidden'], deny_read: 'kept', 'allowed_domains' => 'kept' }
      sandbox = {
        enabled: true,
        ripgrep: inner,
        ignore_violations: { 'excluded_commands' => ['/tmp/*'], network: { denied_domains: ['kept'] } },
        network: { allow_unix_sockets: ['/var/run/docker.sock'], allow_mach_lookup: [{ deny_read: 'kept' }] }
      }

      expect(sandbox_section(sandbox)).to eq(
        'enabled' => true,
        'ripgrep' => on_the_wire(inner),
        'ignoreViolations' => { 'excluded_commands' => ['/tmp/*'], 'network' => { 'denied_domains' => ['kept'] } },
        'network' => { 'allowUnixSockets' => ['/var/run/docker.sock'], 'allowMachLookup' => [{ 'deny_read' => 'kept' }] }
      )
    end
  end

  describe 'a Hash that spells one field both ways' do
    it 'sends the camelCase spelling at the top level, whichever comes first' do
      sandboxes = [
        { enabled: true, auto_allow_bash_if_sandboxed: true, autoAllowBashIfSandboxed: false },
        { enabled: true, autoAllowBashIfSandboxed: false, auto_allow_bash_if_sandboxed: true },
        { 'enabled' => true, 'auto_allow_bash_if_sandboxed' => true, 'autoAllowBashIfSandboxed' => false },
        { enabled: true, 'autoAllowBashIfSandboxed' => false, auto_allow_bash_if_sandboxed: true }
      ]

      expect(sandboxes.map { |sandbox| sandbox_section(sandbox) })
        .to eq([{ 'enabled' => true, 'autoAllowBashIfSandboxed' => false }] * 4)
    end

    it 'sends the camelCase spelling inside network and filesystem, whichever comes first' do
      sandboxes = [
        { network: { denied_domains: [], deniedDomains: ['evil.example'] },
          filesystem: { denyRead: ['/private/etc/ssh', '~/.aws'], deny_read: [] } },
        { 'network' => { 'deniedDomains' => ['evil.example'], 'denied_domains' => [] },
          'filesystem' => { 'deny_read' => [], 'denyRead' => ['/private/etc/ssh', '~/.aws'] } },
        ClaudeAgentSDK::SandboxSettings.new(
          network: { deniedDomains: ['evil.example'], denied_domains: [] },
          filesystem: { deny_read: [], denyRead: ['/private/etc/ssh', '~/.aws'] }
        )
      ]
      expected = {
        'network' => { 'deniedDomains' => ['evil.example'] },
        'filesystem' => { 'denyRead' => ['/private/etc/ssh', '~/.aws'] }
      }

      expect(sandboxes.map { |sandbox| sandbox_section(sandbox) }).to eq([expected] * 3)
    end

    it 'writes the field once' do
      argument = settings_argument(
        { excluded_commands: ['git'], excludedCommands: ['docker'],
          network: { deniedDomains: ['evil.example'], denied_domains: ['other.example'] } }
      )

      expect(argument.scan('"excludedCommands"').size).to eq(1)
      expect(argument.scan('"deniedDomains"').size).to eq(1)
      expect(argument).not_to include('excluded_commands', 'denied_domains')
    end

    # json 3.x raises on a Hash that carries one key as a Symbol and as a
    # String; json 2.x writes it twice.
    it 'writes a key once when a Symbol and a String spell it, taking the later one' do
      argument = settings_argument(
        { enabled: false, 'enabled' => true,
          'network' => { 'deniedDomains' => ['other.example'] },
          network: { deniedDomains: [], 'deniedDomains' => ['evil.example'] } }
      )

      expect(JSON.parse(argument).fetch('sandbox')).to eq(
        'enabled' => true, 'network' => { 'deniedDomains' => ['evil.example'] }
      )
      expect(%w[enabled network deniedDomains].map { |key| argument.scan("\"#{key}\"").size }).to eq([1, 1, 1])
    end

    it 'takes the later one of a snake_case Symbol and a snake_case String too' do
      sandbox = {
        'excluded_commands' => ['git'], excluded_commands: ['docker'],
        filesystem: { deny_read: [], 'deny_read' => ['~/.aws'] }
      }

      expect(sandbox_section(sandbox)).to eq('excludedCommands' => ['docker'], 'filesystem' => { 'denyRead' => ['~/.aws'] })
    end
  end

  # The typed classes leave a nil attribute out of #to_h. A Hash stands for
  # the typed value with the same fields, so a known key holding nil is left
  # out as well, in either spelling. It matters: CLI 2.1.287 rejects null
  # under every one of these keys ("sandbox.excludedCommands: Expected array,
  # but received null") and then drops the whole --settings value, sandbox
  # included. Written in snake_case the same key used to be one the CLI did
  # not know and ignored.
  describe 'a nil value under a known key' do
    typed = ClaudeAgentSDK::SandboxSettings.new(
      enabled: true, excluded_commands: nil, auto_allow_bash_if_sandboxed: nil, filesystem: nil,
      network: ClaudeAgentSDK::SandboxNetworkConfig.new(denied_domains: ['evil.example'], allowed_domains: nil)
    )
    expected = { 'enabled' => true, 'network' => { 'deniedDomains' => ['evil.example'] } }

    it 'is left out by the typed classes' do
      expect(sandbox_section(typed)).to eq(expected)
    end

    {
      'snake_case keys' => {
        enabled: true, excluded_commands: nil, auto_allow_bash_if_sandboxed: nil, filesystem: nil,
        network: { denied_domains: ['evil.example'], allowed_domains: nil }
      },
      'camelCase keys' => {
        enabled: true, excludedCommands: nil, autoAllowBashIfSandboxed: nil, filesystem: nil,
        network: { deniedDomains: ['evil.example'], allowedDomains: nil }
      },
      'String keys' => {
        'enabled' => true, 'excluded_commands' => nil, 'autoAllowBashIfSandboxed' => nil, 'filesystem' => nil,
        'network' => { 'denied_domains' => ['evil.example'], 'allowedDomains' => nil }
      },
      'a typed SandboxSettings holding a Hash' => ClaudeAgentSDK::SandboxSettings.new(
        enabled: true, network: { denied_domains: ['evil.example'], allowed_domains: nil, 'allowLocalBinding' => nil }
      )
    }.each do |form, sandbox|
      it "is left out of a Hash with #{form}" do
        expect(sandbox_section(sandbox)).to eq(expected)
      end
    end

    it 'does not stand in for a value the other spelling carries' do
      sandbox = { filesystem: { deny_read: ['~/.aws'], denyRead: nil }, excludedCommands: nil, excluded_commands: ['docker'] }

      expect(sandbox_section(sandbox)).to eq('filesystem' => { 'denyRead' => ['~/.aws'] }, 'excludedCommands' => ['docker'])
    end

    it 'keeps false, which is a value' do
      sandbox = { enabled: false, auto_allow_bash_if_sandboxed: false, network: { allow_local_binding: false } }

      expect(sandbox_section(sandbox)).to eq(
        'enabled' => false, 'autoAllowBashIfSandboxed' => false, 'network' => { 'allowLocalBinding' => false }
      )
    end
  end

  describe 'what the caller did not write' do
    it 'is not added: an enabled sandbox is sent without failIfUnavailable' do
      expect([{ enabled: true }, { 'enabled' => true }, ClaudeAgentSDK::SandboxSettings.new(enabled: true)]
        .map { |sandbox| sandbox_section(sandbox) }).to eq([{ 'enabled' => true }] * 3)
    end

    it 'stays an empty section for an empty Hash' do
      expect(settings_argument({})).to eq('{"sandbox":{}}')
    end
  end

  describe 'the Hash the caller passed' do
    it 'is left untouched, so a frozen constant can be used for every session' do
      sandbox = {
        enabled: true, excluded_commands: ['docker'].freeze,
        network: { denied_domains: ['evil.example'].freeze }.freeze
      }.freeze
      expected = { 'enabled' => true, 'excludedCommands' => ['docker'], 'network' => { 'deniedDomains' => ['evil.example'] } }

      expect([sandbox_section(sandbox), sandbox_section(sandbox)]).to eq([expected, expected])
      expect(sandbox).to eq(
        enabled: true, excluded_commands: ['docker'], network: { denied_domains: ['evil.example'] }
      )
    end

    it 'is not modified when a typed SandboxSettings holds it' do
      network = { denied_domains: ['evil.example'], deniedDomains: ['other.example'], allowed_domains: nil }.freeze
      sandbox = ClaudeAgentSDK::SandboxSettings.new(enabled: true, network: network)

      expect(sandbox.to_h).to eq(enabled: true, network: { deniedDomains: ['other.example'] })
      expect(network).to eq(denied_domains: ['evil.example'], deniedDomains: ['other.example'], allowed_domains: nil)
    end
  end
end
