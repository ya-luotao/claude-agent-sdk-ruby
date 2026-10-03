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

    # The wire form. The CLI validates the updatedPermissions of a
    # can_use_tool reply as one unit and drops the whole array when a single
    # entry does not fit its schema, so two things it rejects are never
    # written: a rule without content has no ruleContent key (the schema
    # wants a String or no key, not null), and an update that has a type but
    # no destination goes to 'session' — the narrowest one: it lasts for this
    # run and writes no settings file (the default Python PR #1330 proposes).
    def to_h
      result = { type: @type }
      destination = @destination || ('session' unless @type.nil?)
      result[:destination] = destination if destination

      case @type
      when 'addRules', 'replaceRules', 'removeRules'
        result[:rules] = @rules.map { |rule| rule_to_h(rule) } if @rules
        result[:behavior] = @behavior if @behavior
      when 'setMode'
        result[:mode] = @mode if @mode
      when 'addDirectories', 'removeDirectories'
        result[:directories] = @directories if @directories
      end

      result
    end

    private

    def rule_to_h(rule)
      wire_rule = { toolName: rule.tool_name }
      wire_rule[:ruleContent] = rule.rule_content unless rule.rule_content.nil?
      wire_rule
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
