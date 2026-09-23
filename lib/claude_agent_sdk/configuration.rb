# frozen_string_literal: true

# default_options= copies through Type.deep_dup_for_options: keep this file
# loadable on its own (require 'claude_agent_sdk/configuration').
require_relative 'types'

module ClaudeAgentSDK
  # Configuration class for setting default options
  #
  # Use this to set default options that will be merged with every request.
  # This is especially useful in Rails applications where you want to
  # configure defaults once during initialization.
  #
  # @example In a Rails initializer (config/initializers/claude_agent_sdk.rb)
  #   ClaudeAgentSDK.configure do |config|
  #     config.default_options = {
  #       env: {
  #         'ANTHROPIC_API_KEY' => ENV['ANTHROPIC_API_KEY'],
  #         'CUSTOM_VAR' => 'value'
  #       },
  #       permission_mode: 'bypassPermissions',
  #       model: 'sonnet'
  #     }
  #   end
  #
  # @example Then use ClaudeAgentSDK without repeating options
  #   # env and other defaults will be automatically applied
  #   ClaudeAgentSDK.query(prompt: "Hello!")
  #
  #   # You can still override defaults when needed
  #   ClaudeAgentSDK.query(
  #     prompt: "Hello!",
  #     options: ClaudeAgentOptions.new(model: 'opus')  # overrides default
  #   )
  #
  # Assignment stores a frozen deep copy of the Hash (containers, typed
  # option values such as SandboxSettings, and mutable Strings are copied;
  # procs, observers, SDK MCP server instances and store adapters keep
  # identity). To change the defaults, assign a new Hash — in-place mutation
  # of the stored one (including `<<` on one of its Strings) raises
  # FrozenError, and later changes to the Hash or Strings you passed in have
  # no effect.
  class Configuration
    # The configured defaults: a frozen snapshot (see class docs).
    #
    # @return [Hash]
    attr_reader :default_options

    EMPTY_DEFAULTS = {}.freeze
    private_constant :EMPTY_DEFAULTS

    def initialize
      @default_options = EMPTY_DEFAULTS
    end

    # The defaults are read at request time by every ClaudeAgentOptions.new
    # (merge_with_defaults) with no lock, possibly from many threads at once.
    # A live, caller-owned Hash made that a race: an in-place write from one
    # thread while another iterated the merge raised "can't add a new key
    # into hash during iteration" or tore the read. Storing a private frozen
    # snapshot removes the shared mutable state instead of guarding it — the
    # ivar swap is atomic, a reader only ever sees a complete Hash, and an
    # in-place write fails loudly. Only the copy is frozen: the caller's
    # Hash and objects, and identity leaves, are left untouched.
    #
    # @param value [Hash, nil] nil clears the defaults
    def default_options=(value)
      @default_options = value.nil? ? EMPTY_DEFAULTS : deep_freeze(Type.deep_dup_for_options(value))
    end

    private

    # Mirrors Type.deep_dup_for_options' recursion: freeze the containers,
    # option value copies and String copies it produced (and their nested
    # state), never a leaf it returned by identity — freezing an
    # SdkMcpServer or a store adapter would break it. A String reaching here
    # is either the copier's own copy or was already frozen, so freezing it
    # never touches a caller's mutable String.
    def deep_freeze(value)
      case value
      when Hash then value.each_value { |v| deep_freeze(v) }
      when Array then value.each { |v| deep_freeze(v) }
      when Type::OptionValue then value.instance_variables.each { |ivar| deep_freeze(value.instance_variable_get(ivar)) }
      when String then nil # nothing nested; fall through to freeze the copy
      else return value
      end
      value.freeze
    end
  end

  class << self
    # Configure the SDK with default options
    #
    # @yield [Configuration] The configuration object
    #
    # @example Set default env and other options
    #   ClaudeAgentSDK.configure do |config|
    #     config.default_options = {
    #       env: { 'API_KEY' => 'xxx' },
    #       permission_mode: 'bypassPermissions'
    #     }
    #   end
    def configure
      yield(configuration)
    end

    # Get the configuration object
    #
    # @return [Configuration] The current configuration
    def configuration
      @configuration ||= Configuration.new
    end

    # Reset configuration to defaults (useful for testing)
    def reset_configuration
      @configuration = Configuration.new
    end

    # Get merged default options for use with ClaudeAgentOptions
    #
    # @return [Hash] Default options hash
    def default_options
      configuration.default_options || {}
    end
  end
end
