# frozen_string_literal: true

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
  class Configuration
    attr_accessor :default_options

    def initialize
      @default_options = {}
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
