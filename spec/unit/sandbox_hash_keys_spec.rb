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
# on SandboxSettings#to_h, the public form of the same section). The one
# group that walks every field in every spelling asserts on the section
# OptionForms.sandbox hands CommandBuilder for that argument instead.
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

  # The top-level fields around one network and one filesystem section.
  around_sections = lambda do |network, filesystem|
    top_level_fields.merge(network: ['network', network], filesystem: ['filesystem', filesystem])
  end

  fields_of = {
    'SandboxSettings' => top_level_fields,
    'SandboxNetworkConfig' => network_fields,
    'SandboxFilesystemConfig' => filesystem_fields
  }.freeze

  # What CLI 2.1.287's sandbox schema accepts under each key that has a
  # snake_case spelling: attribute => kind. Read from the schema in the CLI
  # binary and checked against the running CLI, key by key, with get_settings:
  #
  #   boolean        true or false
  #   strings        an Array of Strings
  #   mach_services  an Array of Strings; a "*" only as the last character
  #   port           a number (the CLI takes any it can read; the SDK asks for
  #                  what a port is, an Integer from 0 to 65535)
  #   string_lists   a Hash whose values are Arrays of Strings
  #
  # Spelled out here, not derived from the SDK. enabled, network, filesystem
  # and ripgrep are missing on purpose: their name is their wire key.
  kinds = {
    'SandboxSettings' => {
      fail_if_unavailable: :boolean, auto_allow_bash_if_sandboxed: :boolean, excluded_commands: :strings,
      allow_unsandboxed_commands: :boolean, ignore_violations: :string_lists,
      enable_weaker_nested_sandbox: :boolean, enable_weaker_network_isolation: :boolean
    },
    'SandboxNetworkConfig' => {
      allowed_domains: :strings, denied_domains: :strings, allow_managed_domains_only: :boolean,
      allow_unix_sockets: :strings, allow_all_unix_sockets: :boolean, allow_local_binding: :boolean,
      allow_mach_lookup: :mach_services, http_proxy_port: :port, socks_proxy_port: :port
    },
    'SandboxFilesystemConfig' => {
      allow_write: :strings, deny_write: :strings, deny_read: :strings, allow_read: :strings,
      allow_managed_read_paths_only: :boolean
    }
  }.freeze

  # For each kind, values outside it: a snake_case key holding one is not
  # renamed. The CLI rejects them under the wire key, and one rejected value
  # makes it discard the whole --settings value, sandbox and permissions
  # included. That goes for 10**400 too: it is an Integer, and a number the
  # CLI cannot read (it fails the schema as a non-finite value). 65_536 and -1
  # are the exception, numbers the CLI takes: they are outside the kind
  # because a port is 0..65535, and a bound that is too tight costs nothing.
  ill_shaped = {
    boolean: ['true', 0, []],
    strings: ['docker', ['docker', 1], [nil], true, { 'docker' => true }],
    mach_services: ['com.apple.audio', ['com.*.helper'], ['*.helper'], ['com.apple.**'], [1]],
    port: ['8080', true, [8080], 10**400, 65_536, -1],
    string_lists: [{ 'file' => '/tmp/*' }, { 'file' => [1] }, { 'file' => { 'read' => [] } }, ['/tmp/*'], 'file']
  }.freeze

  # A sandbox Hash with +fields+ at the level of the class: the top, or inside
  # the section the class stands for.
  at_level_of = {
    'SandboxSettings' => ->(fields) { { enabled: true }.merge(fields) },
    'SandboxNetworkConfig' => ->(fields) { { enabled: true, network: fields } },
    'SandboxFilesystemConfig' => ->(fields) { { enabled: true, filesystem: fields } }
  }.freeze

  # Asserted where the section is made, not on the command line: OptionForms
  # is the one reader of a sandbox given either way, and CommandBuilder puts
  # what it answers under "sandbox" in --settings as it is (the groups above
  # and below follow it there).
  describe 'every field of every sandbox class' do
    # The section the CLI must receive, whichever way it was written, under
    # the Symbol keys the typed classes write.
    wire_keys = spellings.fetch('camelCase Symbol keys')
    wire = wire_keys.call(around_sections.call(wire_keys.call(network_fields), wire_keys.call(filesystem_fields)))

    # The sandbox section read out of this `sandbox:` option.
    def section_read_from(sandbox)
      ClaudeAgentSDK::OptionForms.sandbox(sandbox)
    end

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

      expect(section_read_from(typed)).to eq(wire)
    end

    spellings.each do |inner_spelling, inner|
      it "is written the same way from a typed SandboxSettings holding Hashes with #{inner_spelling}" do
        sandbox = ClaudeAgentSDK::SandboxSettings.new(
          attributes_of.call(around_sections.call(inner.call(network_fields), inner.call(filesystem_fields)))
        )

        expect(section_read_from(sandbox)).to eq(wire)
      end

      spellings.each do |outer_spelling, outer|
        it "is written the same way from a Hash with #{outer_spelling} holding Hashes with #{inner_spelling}" do
          sandbox = outer.call(around_sections.call(inner.call(network_fields), inner.call(filesystem_fields)))

          expect(section_read_from(sandbox)).to eq(wire)
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

    describe 'SHAPES' do
      it 'has a kind for every attribute whose name is not its wire key, and for nothing else' do
        with_a_spelling_of_their_own = fields_of.transform_values do |fields|
          fields.reject { |name, (wire_key, _value)| name.to_s == wire_key }.keys
        end

        expect(kinds.transform_values(&:keys)).to eq(with_a_spelling_of_their_own)
      end

      it 'agrees with the kinds this file spells out' do
        spelled_out = kinds.flat_map do |class_name, by_attribute|
          by_attribute.map { |attribute, kind| [fields_of.fetch(class_name).fetch(attribute).first.to_sym, kind] }
        end

        expect(ClaudeAgentSDK::SandboxKeys::SHAPES).to eq(spelled_out.to_h)
      end

      it 'has values outside every kind it uses' do
        expect(ill_shaped.keys).to match_array(kinds.values.flat_map(&:values).uniq)
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
        ignore_violations: { 'excluded_commands' => ['/tmp/*'], denied_domains: ['kept'], network: ['localhost'] },
        network: { allow_unix_sockets: ['/var/run/docker.sock'], allow_mach_lookup: ['com.apple.coresimulator.*'] }
      }

      expect(sandbox_section(sandbox)).to eq(
        'enabled' => true,
        'ripgrep' => on_the_wire(inner),
        'ignoreViolations' => { 'excluded_commands' => ['/tmp/*'], 'denied_domains' => ['kept'], 'network' => ['localhost'] },
        'network' => { 'allowUnixSockets' => ['/var/run/docker.sock'], 'allowMachLookup' => ['com.apple.coresimulator.*'] }
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

  # A snake_case key is one the CLI does not know: it ignores it, value and
  # all. Under its wire name the same value is validated, and one value that
  # fails the CLI's schema makes it discard the whole --settings value (the
  # sandbox, and the permissions passed next to it); the SDK is not told. So a
  # snake_case key is renamed only when its value has the shape the CLI
  # accepts for that key. Otherwise it goes out as written and stays inert,
  # as it always was: renaming must never cost a session its sandbox.
  describe 'a snake_case key whose value the CLI would reject' do
    # allowUnixSockets takes an Array of socket paths; the boolean switch is
    # allow_all_unix_sockets. The shipped signature of allow_unix_sockets
    # allows a bool all the same, which makes `true` the value most likely to
    # be written here. Sent as allowUnixSockets: true it would leave the
    # session with no sandbox at all.
    it 'sends allow_unix_sockets: true as written, not as allowUnixSockets' do
      sandbox = { enabled: true, network: { allow_unix_sockets: true, denied_domains: ['evil.example'] } }

      expect(sandbox_section(sandbox)).to eq(
        'enabled' => true, 'network' => { 'allow_unix_sockets' => true, 'deniedDomains' => ['evil.example'] }
      )
    end

    kinds.each do |class_name, by_attribute|
      by_attribute.each do |attribute, kind|
        it "is sent as written for #{attribute} (#{kind}), under a Symbol or a String key" do
          sandboxes = ill_shaped.fetch(kind).flat_map do |value|
            [attribute, attribute.to_s].map { |key| at_level_of.fetch(class_name).call(key => value) }
          end

          expect(sandboxes.map { |sandbox| sandbox_section(sandbox) }).to eq(sandboxes.map { |sandbox| on_the_wire(sandbox) })
        end
      end
    end

    it 'is left as written inside a typed SandboxSettings too' do
      sandbox = ClaudeAgentSDK::SandboxSettings.new(
        enabled: true, network: { allow_unix_sockets: true }, filesystem: { 'deny_read' => '~/.aws' }
      )

      expect(sandbox.to_h).to eq(
        enabled: true, network: { allow_unix_sockets: true }, filesystem: { 'deny_read' => '~/.aws' }
      )
    end

    it 'stays next to the same field written in a form the CLI accepts, and never replaces it' do
      sandbox = {
        excluded_commands: 'docker', excludedCommands: ['git'],
        filesystem: { deny_read: ['~/.aws'], 'deny_read' => '~/.ssh' }
      }

      expect(sandbox_section(sandbox)).to eq(
        'excluded_commands' => 'docker', 'excludedCommands' => ['git'],
        'filesystem' => { 'denyRead' => ['~/.aws'], 'deny_read' => '~/.ssh' }
      )
    end

    it 'is still renamed for the values the CLI accepts at the edges' do
      sandbox = {
        excluded_commands: [], ignore_violations: {},
        network: { allowed_domains: ['*.example.com', ''], allow_mach_lookup: ['*', 'com.apple.coresimulator.*'],
                   http_proxy_port: 0, socks_proxy_port: 65_535 },
        filesystem: { deny_read: ['/work/**/*.pem'] }
      }

      expect(sandbox_section(sandbox)).to eq(
        'excludedCommands' => [], 'ignoreViolations' => {},
        'network' => { 'allowedDomains' => ['*.example.com', ''], 'allowMachLookup' => ['*', 'com.apple.coresimulator.*'],
                       'httpProxyPort' => 0, 'socksProxyPort' => 65_535 },
        'filesystem' => { 'denyRead' => ['/work/**/*.pem'] }
      )
    end

    # A proxy port is renamed for what a port can be, whichever of the two
    # attributes it is and whichever class its key has. Beyond that range the
    # CLI still takes a number it can read, but not one it cannot: an Integer
    # such as 10**400 reaches it as a non-finite value, and it discards the
    # whole --settings value over that (the examples for the port kind above).
    %i[http_proxy_port socks_proxy_port].each do |attribute|
      it "is renamed for #{attribute} at 0 and at 65535, under a Symbol or a String key" do
        wire_key = network_fields.fetch(attribute).first
        sections = [0, 65_535].flat_map do |port|
          [attribute, attribute.to_s].map { |key| sandbox_section({ enabled: true, network: { key => port } }) }
        end

        expect(sections)
          .to eq([0, 0, 65_535, 65_535].map { |port| { 'enabled' => true, 'network' => { wire_key => port } } })
      end
    end

    # The check is only about renaming. A key the caller wrote in the CLI's
    # own spelling reaches the CLI as before, whatever its value.
    it 'does not concern a key already in wire spelling' do
      sandbox = { enabled: true, excludedCommands: 'docker', 'failIfUnavailable' => 'yes',
                  network: { allowUnixSockets: true, httpProxyPort: 10**400, 'socksProxyPort' => -1 } }

      expect(sandbox_section(sandbox)).to eq(on_the_wire(sandbox))
    end
  end

  # JSON.generate has no way to write a typed value: left inside a Hash it
  # went out as its #inspect text ("#<ClaudeAgentSDK::SandboxNetworkConfig
  # ...>"), a String where the CLI wants an object, and the CLI discarded the
  # whole --settings value over it.
  describe 'a typed network or filesystem inside a Hash' do
    it 'is written like a Hash with the same fields' do
      sandbox = {
        enabled: true,
        network: ClaudeAgentSDK::SandboxNetworkConfig.new(denied_domains: ['evil.example']),
        'filesystem' => ClaudeAgentSDK::SandboxFilesystemConfig.new(deny_read: ['/private/etc/ssh'])
      }

      expect(sandbox_section(sandbox)).to eq(
        'enabled' => true,
        'network' => { 'deniedDomains' => ['evil.example'] },
        'filesystem' => { 'denyRead' => ['/private/etc/ssh'] }
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
