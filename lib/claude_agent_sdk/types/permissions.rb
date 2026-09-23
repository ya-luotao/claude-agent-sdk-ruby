# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
  # Type constants for permission modes
  PERMISSION_MODES = %w[default acceptEdits plan bypassPermissions dontAsk auto].freeze

  # Type constants for permission update destinations
  PERMISSION_UPDATE_DESTINATIONS = %w[userSettings projectSettings localSettings session].freeze

  # Type constants for permission behaviors
  PERMISSION_BEHAVIORS = %w[allow deny ask].freeze

  # Permission rule value
  class PermissionRuleValue < Type
    strict_attributes

    attr_accessor :tool_name, :rule_content
  end

  # Permission update configuration
  class PermissionUpdate < Type
    strict_attributes

    attr_accessor :type, :behavior, :mode, :directories, :destination
    attr_reader :rules

    # Wire-format parity with Python PermissionUpdate.from_dict (#920): the CLI
    # sends rules as camelCase hashes ({toolName:, ruleContent:}); hydrate them
    # into PermissionRuleValue (Type#assign_attribute normalizes the camelCase
    # keys). Already-typed PermissionRuleValue entries pass through unchanged.
    def rules=(value)
      @rules = value&.map { |rule| rule.is_a?(Hash) ? PermissionRuleValue.new(rule) : rule }
    end

    def to_h
      result = { type: @type }
      result[:destination] = @destination if @destination

      case @type
      when 'addRules', 'replaceRules', 'removeRules'
        if @rules
          result[:rules] = @rules.map do |rule|
            {
              toolName: rule.tool_name,
              ruleContent: rule.rule_content
            }
          end
        end
        result[:behavior] = @behavior if @behavior
      when 'setMode'
        result[:mode] = @mode if @mode
      when 'addDirectories', 'removeDirectories'
        result[:directories] = @directories if @directories
      end

      result
    end
  end

  # Tool permission context delivered to `can_use_tool` callbacks.
  # CLI 2.1.110+ began populating the four pre-formatted display fields
  # (`title`, `display_name`, `description`, `blocked_path`,
  # `decision_reason`) so the SDK consumer can render the same prompt UI
  # the CLI would have shown. Older fields (`signal`, `suggestions`,
  # `tool_use_id`, `agent_id`) remain unchanged.
  # `signal` is a CancellationSignal on dispatched callbacks; `request_id`
  # identifies this permission request (distinct from the tool invocation).
  class ToolPermissionContext < Type
    attr_accessor :signal, :request_id, :suggestions, :tool_use_id, :agent_id,
                  :title, :display_name, :description,
                  :blocked_path, :decision_reason

    def initialize(attributes = {})
      super
      @suggestions ||= []
    end
  end

  # Permission results
  class PermissionResultAllow < Type
    strict_attributes

    attr_accessor :updated_input, :updated_permissions
    attr_reader :behavior

    def initialize(attributes = {})
      super
      @behavior = 'allow'
    end
  end

  class PermissionResultDeny < Type
    strict_attributes

    attr_accessor :message, :interrupt
    attr_reader :behavior

    def initialize(attributes = {})
      super
      @behavior = 'deny'
      @message ||= ''
      @interrupt = false if @interrupt.nil?
    end
  end
end
