# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
  # Thinking configuration types
  #
  # `display` controls how thinking content appears in responses. Valid values
  # are `"summarized"` (plaintext summary) and `"omitted"` (empty thinking
  # field, signature only). Defaults are model-dependent: Opus 4.6/Sonnet 4.6
  # default to `"summarized"`; Opus 4.7 and every later model default to
  # `"omitted"`. Pass `display: "summarized"` explicitly on those to get
  # visible thinking text. Not supported with `ThinkingConfigDisabled`.
  THINKING_DISPLAY_VALUES = %w[summarized omitted].freeze

  # Adaptive thinking: the model decides when and how much to think
  # (sent as `--thinking adaptive`, no budget); control depth with `effort`.
  class ThinkingConfigAdaptive < Type
    include Type::OptionValue

    strict_attributes

    attr_reader :type, :display

    def initialize(attributes = {})
      super
      @type = 'adaptive'
    end

    def display=(value)
      @display = validate_display(value)
    end

    private

    def validate_display(value)
      return nil if value.nil?
      return value if THINKING_DISPLAY_VALUES.include?(value.to_s)

      raise ArgumentError,
            "invalid thinking display #{value.inspect}; expected one of #{THINKING_DISPLAY_VALUES.inspect}"
    end
  end

  # Enabled thinking: uses a user-specified budget
  class ThinkingConfigEnabled < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :budget_tokens
    attr_reader :type, :display

    def initialize(attributes = {})
      super
      @type = 'enabled'
    end

    def display=(value)
      @display = validate_display(value)
    end

    private

    def validate_display(value)
      return nil if value.nil?
      return value if THINKING_DISPLAY_VALUES.include?(value.to_s)

      raise ArgumentError,
            "invalid thinking display #{value.inspect}; expected one of #{THINKING_DISPLAY_VALUES.inspect}"
    end
  end

  # Disabled thinking: sets thinking tokens to 0
  class ThinkingConfigDisabled < Type
    include Type::OptionValue

    strict_attributes

    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'disabled'
    end
  end

  # Agent definition configuration
  class AgentDefinition < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :description, :prompt, :tools, :disallowed_tools, :model, :skills, :memory, :mcp_servers,
                  :initial_prompt, :max_turns, :background, :effort, :permission_mode
  end

  # SDK Plugin configuration
  class SdkPluginConfig < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :path
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'local'
    end

    def to_h
      { type: @type, path: @path }
    end
  end

  # Sandbox network configuration
  class SandboxNetworkConfig < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :allowed_domains, :denied_domains, :allow_managed_domains_only,
                  :allow_unix_sockets, :allow_all_unix_sockets, :allow_local_binding,
                  :allow_mach_lookup, :http_proxy_port, :socks_proxy_port

    def to_h
      result = {}
      result[:allowedDomains] = @allowed_domains if @allowed_domains
      result[:deniedDomains] = @denied_domains if @denied_domains
      result[:allowManagedDomainsOnly] = @allow_managed_domains_only unless @allow_managed_domains_only.nil?
      result[:allowUnixSockets] = @allow_unix_sockets unless @allow_unix_sockets.nil?
      result[:allowAllUnixSockets] = @allow_all_unix_sockets unless @allow_all_unix_sockets.nil?
      result[:allowLocalBinding] = @allow_local_binding unless @allow_local_binding.nil?
      result[:allowMachLookup] = @allow_mach_lookup if @allow_mach_lookup
      result[:httpProxyPort] = @http_proxy_port if @http_proxy_port
      result[:socksProxyPort] = @socks_proxy_port if @socks_proxy_port
      result
    end
  end

  # Sandbox filesystem configuration
  class SandboxFilesystemConfig < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :allow_write, :deny_write, :deny_read, :allow_read, :allow_managed_read_paths_only

    def to_h
      result = {}
      result[:allowWrite] = @allow_write if @allow_write
      result[:denyWrite] = @deny_write if @deny_write
      result[:denyRead] = @deny_read if @deny_read
      result[:allowRead] = @allow_read if @allow_read
      result[:allowManagedReadPathsOnly] = @allow_managed_read_paths_only unless @allow_managed_read_paths_only.nil?
      result
    end
  end

  # Sandbox settings for isolated command execution.
  #
  # +network+ and +filesystem+ take a SandboxNetworkConfig /
  # SandboxFilesystemConfig or a Hash. A Hash may spell the fields of those
  # classes as their attributes (+denied_domains+) or as the CLI does
  # (+deniedDomains+), with Symbol or String keys; any other key is sent as
  # written. The same holds for a Hash given as +sandbox:+ in place of a
  # SandboxSettings.
  class SandboxSettings < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :enabled, :fail_if_unavailable, :auto_allow_bash_if_sandboxed,
                  :excluded_commands, :allow_unsandboxed_commands, :network, :filesystem,
                  :ignore_violations, :enable_weaker_nested_sandbox,
                  :enable_weaker_network_isolation, :ripgrep

    def to_h
      result = {}
      result[:enabled] = @enabled unless @enabled.nil?
      result[:failIfUnavailable] = @fail_if_unavailable unless @fail_if_unavailable.nil?
      result[:autoAllowBashIfSandboxed] = @auto_allow_bash_if_sandboxed unless @auto_allow_bash_if_sandboxed.nil?
      result[:excludedCommands] = @excluded_commands if @excluded_commands
      result[:allowUnsandboxedCommands] = @allow_unsandboxed_commands unless @allow_unsandboxed_commands.nil?
      result[:network] = SandboxKeys.network(@network) if @network
      result[:filesystem] = SandboxKeys.filesystem(@filesystem) if @filesystem
      result[:ignoreViolations] = @ignore_violations if @ignore_violations
      result[:enableWeakerNestedSandbox] = @enable_weaker_nested_sandbox unless @enable_weaker_nested_sandbox.nil?
      unless @enable_weaker_network_isolation.nil?
        result[:enableWeakerNetworkIsolation] = @enable_weaker_network_isolation
      end
      result[:ripgrep] = @ripgrep if @ripgrep
      result
    end
  end

  # The spellings a sandbox Hash may use for a field of the three sandbox
  # classes above, mapped to the key their #to_h emits, which is the key the
  # CLI reads. A Hash given as the +sandbox:+ option, or as the network /
  # filesystem of a SandboxSettings, stands for the typed value with the same
  # fields: its keys may be Symbols or Strings, the attribute names
  # (snake_case) or the wire keys (camelCase).
  #
  # Every attribute is listed, also the ones whose name is their wire key. A
  # key that is not listed is sent as written, so a field of the CLI that the
  # typed classes do not model (allowAppleEvents, network.strictAllowlist,
  # filesystem.disabled, ...) still gets through, in the CLI's own spelling.
  # spec/unit/sandbox_hash_keys_spec.rb walks the attributes of the three
  # classes and fails when one of them and these tables disagree.
  #
  # @api private
  module SandboxKeys
    # SandboxSettings attribute => wire key.
    TOP_LEVEL = {
      'enabled' => :enabled,
      'fail_if_unavailable' => :failIfUnavailable,
      'auto_allow_bash_if_sandboxed' => :autoAllowBashIfSandboxed,
      'excluded_commands' => :excludedCommands,
      'allow_unsandboxed_commands' => :allowUnsandboxedCommands,
      'network' => :network,
      'filesystem' => :filesystem,
      'ignore_violations' => :ignoreViolations,
      'enable_weaker_nested_sandbox' => :enableWeakerNestedSandbox,
      'enable_weaker_network_isolation' => :enableWeakerNetworkIsolation,
      'ripgrep' => :ripgrep
    }.freeze

    # SandboxNetworkConfig attribute => wire key.
    NETWORK = {
      'allowed_domains' => :allowedDomains,
      'denied_domains' => :deniedDomains,
      'allow_managed_domains_only' => :allowManagedDomainsOnly,
      'allow_unix_sockets' => :allowUnixSockets,
      'allow_all_unix_sockets' => :allowAllUnixSockets,
      'allow_local_binding' => :allowLocalBinding,
      'allow_mach_lookup' => :allowMachLookup,
      'http_proxy_port' => :httpProxyPort,
      'socks_proxy_port' => :socksProxyPort
    }.freeze

    # SandboxFilesystemConfig attribute => wire key.
    FILESYSTEM = {
      'allow_write' => :allowWrite,
      'deny_write' => :denyWrite,
      'deny_read' => :denyRead,
      'allow_read' => :allowRead,
      'allow_managed_read_paths_only' => :allowManagedReadPathsOnly
    }.freeze

    # A Hash +sandbox:+ as the CLI reads it: its known keys under their wire
    # keys, at the top level and inside a Hash network / filesystem. Values
    # are not rewritten: ignore_violations and ripgrep hold structures of
    # the CLI's own.
    def self.normalize(sandbox)
      normalized = rename(sandbox, TOP_LEVEL)
      { network: NETWORK, filesystem: FILESYSTEM }.each do |section, table|
        normalized[section] = rename(normalized[section], table) if normalized[section].is_a?(Hash)
      end
      normalized
    end

    # The network of a SandboxSettings as the CLI reads it.
    def self.network(section)
      case section
      when SandboxNetworkConfig then section.to_h
      when Hash then rename(section, NETWORK)
      else section
      end
    end

    # The filesystem of a SandboxSettings as the CLI reads it.
    def self.filesystem(section)
      case section
      when SandboxFilesystemConfig then section.to_h
      when Hash then rename(section, FILESYSTEM)
      else section
      end
    end

    # A known key ends up as the one Symbol #to_h emits, so the spellings of
    # a field (attribute name or wire key, Symbol or String) cannot reach
    # JSON.generate side by side: json 3.x raises on a key given as a Symbol
    # and as a String, 2.x writes it twice. When a Hash carries both
    # spellings of a field the wire spelling wins, whichever comes first;
    # between two keys in the same spelling the later one does.
    #
    # A known key holding nil is left out, as #to_h leaves out a nil
    # attribute. The CLI rejects null under every one of these keys, and
    # when it does it drops the whole --settings value, sandbox included.
    def self.rename(hash, table)
      renamed = {}
      wire_spelled = {}
      hash.each do |key, value|
        name = key.to_s
        wire = table[name] || table.each_value.find { |candidate| candidate.name == name }
        if wire.nil?
          renamed[key] = value
        elsif value.nil?
          next
        elsif wire.name == name
          wire_spelled[wire] = true
          renamed[wire] = value
        elsif !wire_spelled.key?(wire)
          renamed[wire] = value
        end
      end
      renamed
    end
    private_class_method :rename
  end

  # API-side task budget in tokens.
  # When set, the model is made aware of its remaining token budget so it can
  # pace tool use and wrap up before the limit.
  class TaskBudget < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :total

    def to_h
      { total: @total }
    end
  end

  # System prompt file configuration — loads system prompt from a file path
  class SystemPromptFile < Type
    include Type::OptionValue

    strict_attributes

    attr_accessor :path
    attr_reader :type

    def initialize(attributes = {})
      super
      @type = 'file'
    end

    def to_h
      { type: @type, path: @path }
    end
  end

  # System prompt preset configuration.
  #
  # +snapshot+ controls whether the session keeps the system prompt it
  # recorded on its first request. When true, every later request (including
  # after resume) sends the recorded prompt, so a changed +append+ has no
  # effect until the session is compacted or a new session starts. When
  # false, the prompt is rebuilt on every request — useful while iterating on
  # +append+ text across calls that resume the same session. When nil
  # (omitted), the CLI treats it as true, except in bare mode (+--bare+),
  # where it acts as false. Sent on the control-protocol +initialize+ request
  # (never as a CLI flag); requires Claude Code CLI 2.1.257 or later, and
  # before 2.1.265 a session with an +append+ prompt recorded it only when
  # +snapshot+ was true. Older CLIs silently ignore it.
  class SystemPromptPreset < Type
    include Type::OptionValue

    strict_attributes

    attr_reader :type
    attr_accessor :preset, :append, :exclude_dynamic_sections, :snapshot

    def initialize(attributes = {})
      super
      @type = 'preset'
    end

    def to_h
      result = { type: @type, preset: @preset }
      result[:append] = @append if @append
      result[:exclude_dynamic_sections] = @exclude_dynamic_sections unless @exclude_dynamic_sections.nil?
      result[:snapshot] = @snapshot unless @snapshot.nil?
      result
    end
  end

  # Custom system prompt configuration — the object form of passing a String
  # as +system_prompt+. Reaches the CLI the same way a String does
  # (+--system-prompt <prompt>+); the object form exists so +snapshot+ can be
  # set alongside it (see SystemPromptPreset#snapshot for its semantics).
  class SystemPromptCustom < Type
    include Type::OptionValue

    strict_attributes

    attr_reader :type
    attr_accessor :prompt, :snapshot

    def initialize(attributes = {})
      super
      @type = 'custom'
    end

    def to_h
      result = { type: @type, prompt: @prompt }
      result[:snapshot] = @snapshot unless @snapshot.nil?
      result
    end
  end

  # Tools preset configuration
  class ToolsPreset < Type
    include Type::OptionValue

    strict_attributes

    attr_reader :type
    attr_accessor :preset

    def initialize(attributes = {})
      super
      @type = 'preset'
    end

    def to_h
      { type: @type, preset: @preset }
    end
  end
end
