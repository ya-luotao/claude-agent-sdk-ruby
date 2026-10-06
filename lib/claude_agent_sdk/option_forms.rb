# frozen_string_literal: true

require_relative 'types'

module ClaudeAgentSDK
  # How the SDK reads a Hash that stands for an option value, behind one set
  # of functions. Several options take a typed value "or the equivalent
  # Hash"; each function here reads one such option in both forms and answers
  # what its caller needs: a small frozen record (Prompt, Thinking, Plugin),
  # a plain value, the value as it was given, or a new Hash made from it.
  # Only the records are frozen, never a value the caller owns.
  #
  # The functions are stateless. They keep nothing, they do not change the
  # value they are given, and they check nothing: a caller that raises on a
  # bad value (CommandBuilder, for a custom prompt without text, an enabled
  # thinking config without a budget, an unknown thinking or plugin type)
  # still does so itself, from what a function answers. The one exception is
  # .agent_definition, which builds a Hash through AgentDefinition.new, so a
  # misspelled key raises there. Flag names, path conversion and JSON
  # encoding stay with the caller as well.
  #
  # The readers were written one at a time, and each option kept the key rule
  # its reader had. They are not one rule, on purpose: a Hash that carries
  # both spellings of a key, or nil / false under one of them, reads as it
  # always did. The rules are
  #
  #   truthy    hash[:key] || hash['key']: a nil or false Symbol key falls
  #             back to the String key
  #   presence  hash.fetch(:key) { hash['key'] }: a Symbol key that is there
  #             is the one read, whatever it holds
  #
  # and HashForm, which holds the field lookups that used to sit in the
  # consumers of these options, says for each key which of them applies.
  # Two kinds of Hash are not read there but handed whole to the code that
  # read them before, with rules of its own: a sandbox Hash to
  # SandboxKeys.normalize (types/option_values.rb), by .sandbox, and an agent
  # Hash to AgentDefinition.new and the Type attribute machinery, by
  # .agent_definition. spec/unit/option_forms_characterization_spec.rb pins
  # the rules at the command line and the initialize request; a change of
  # rule is a change of behaviour, not a cleanup.
  #
  # @api private
  module OptionForms
    # What .system_prompt answers. +kind+ says what the command line gets:
    #
    #   :empty   --system-prompt ''             (the option is nil)
    #   :none    no prompt flag at all          (see .system_prompt)
    #   :text    --system-prompt value          (value is whatever the custom
    #                                           form holds; the caller raises
    #                                           unless it is a String)
    #   :file    --system-prompt-file value
    #   :append  --append-system-prompt value
    class Prompt
      attr_reader :kind, :value

      def initialize(kind, value = nil)
        @kind = kind
        @value = value
        freeze
      end

      # +kind+ when there is a value to send, no prompt flag otherwise: a
      # preset activates the default Claude Code prompt by sending no
      # --system-prompt, with its append text only when it has any, and a
      # file Hash names a file only when it has a path.
      def self.optional(kind, value)
        value ? new(kind, value) : new(:none)
      end
    end

    # What .thinking answers: the fields of a thinking config, typed or Hash.
    # +type+ is nil for a value that is no thinking config.
    class Thinking
      attr_reader :type, :budget_tokens, :display

      def initialize(type: nil, budget_tokens: nil, display: nil)
        @type = type
        @budget_tokens = budget_tokens
        @display = display
        freeze
      end
    end

    # What .plugin answers. +type_tag+ is the type as a String, to compare.
    class Plugin
      attr_reader :type_tag, :path

      def initialize(type_tag:, path:, config:)
        @type_tag = type_tag
        @path = path
        @config = config
        freeze
      end

      # The type as it was written, for the message of the caller that
      # refuses the plugin. Read from the entry anew each time it is asked
      # for, and not when the record is made: the reader this replaces looked
      # the type up a second time for its message, and only once it had
      # refused the plugin, which a Hash that computes its values can tell.
      def raw_type
        HashForm.plugin_type(@config)
      end
    end

    # The direct field lookups on an option Hash that were moved out of its
    # consumers (CommandBuilder, the root extractors, the transport's sandbox
    # warning), each under the rule its option has always had (truthy or
    # presence, see OptionForms). The functions of OptionForms tell the forms
    # of an option apart by class and come here for the Hash one.
    #
    # This is not every read of an option Hash in the SDK. The fields of a
    # sandbox Hash are read and renamed by SandboxKeys.normalize
    # (types/option_values.rb), which OptionForms.sandbox delegates to; only
    # the `enabled` of the warning predicate is looked up here. The
    # attributes of an agent Hash are assigned by the strict
    # AgentDefinition.new, through the Type machinery, which
    # OptionForms.agent_definition delegates to.
    module HashForm
      # The type tag, as a String: `type: :preset` is the natural Ruby
      # spelling of `type: 'preset'`. Truthy, so a nil Symbol-keyed tag falls
      # back to the String-keyed one. A missing tag is '', which is no tag
      # the SDK knows.
      def self.tag(hash)
        (hash[:type] || hash['type']).to_s
      end

      # system_prompt, by its tag: +path+ and +append+ are truthy, +prompt+
      # is by presence (a Symbol key holding nil is the prompt, and the
      # caller refuses it). Any other tag, or none, is no prompt flag.
      def self.system_prompt(hash)
        case tag(hash)
        when 'file' then Prompt.optional(:file, hash[:path] || hash['path'])
        when 'custom' then Prompt.new(:text, hash.fetch(:prompt) { hash['prompt'] })
        when 'preset' then Prompt.optional(:append, hash[:append] || hash['append'])
        else Prompt.new(:none)
        end
      end

      # +snapshot+ of a preset or custom system prompt, by presence.
      def self.snapshot(hash)
        hash.fetch(:snapshot) { hash['snapshot'] } if %w[preset custom].include?(tag(hash))
      end

      # +exclude_dynamic_sections+ of a preset system prompt, by presence.
      def self.exclude_dynamic_sections(hash)
        hash.fetch(:exclude_dynamic_sections) { hash['exclude_dynamic_sections'] } if tag(hash) == 'preset'
      end

      # thinking: all three fields are truthy, so `budget_tokens: false` is
      # no budget. The type stays nil when there is none; +display+ is not
      # checked the way the typed classes check theirs.
      def self.thinking(hash)
        Thinking.new(type: (hash[:type] || hash['type'])&.to_s,
                     budget_tokens: hash[:budget_tokens] || hash['budget_tokens'],
                     display: hash[:display] || hash['display'])
      end

      # output_format: the Symbol-keyed tag is looked at before the
      # String-keyed one, and +schema+ is read by presence under the key
      # style the matching tag was written in, or under the other one when
      # that key is absent ({ 'type' => 'json_schema', schema: {...} }). A
      # Hash that is not tagged json_schema is the schema itself.
      def self.output_schema(hash)
        if hash[:type].to_s == 'json_schema'
          hash.fetch(:schema) { hash['schema'] }
        elsif hash['type'].to_s == 'json_schema'
          hash.fetch('schema') { hash[:schema] }
        else
          hash
        end
      end

      # task_budget: +total+ is truthy.
      def self.total(hash)
        hash[:total] || hash['total']
      end

      # One plugin: +path+ is truthy and read first, then the tag, once.
      def self.plugin(hash)
        path = hash[:path] || hash['path']
        Plugin.new(type_tag: tag(hash), path: path, config: hash)
      end

      # The type of a plugin as it was written (truthy), for Plugin#raw_type.
      def self.plugin_type(hash)
        hash[:type] || hash['type']
      end

      # sandbox, for the warning alone (.sandbox_requested?): either key
      # being true will do, whatever the other one holds.
      def self.enabled?(hash)
        hash[:enabled] == true || hash['enabled'] == true
      end

      # The live server of an sdk MCP server config, by presence.
      def self.instance(hash)
        hash.key?(:instance) ? hash[:instance] : hash['instance']
      end
    end
    private_constant :HashForm

    # What .tools answers for the preset. An object of its own rather than a
    # Symbol: a caller can write `tools: :default`, which is none of the forms
    # of the option and sends no flag.
    #
    # @api private
    DEFAULT_TOOLS = Object.new.freeze

    # The system prompt as the command line takes it (see Prompt).
    #
    # nil is the empty prompt, and it is the only value that is. No prompt
    # flag at all, so that the CLI runs with its default prompt, is the answer
    # for a preset without an append, a file Hash without a path, a Hash with
    # an unknown tag or none, and a value that is none of the forms of the
    # option. A typed SystemPromptFile is a file prompt whatever its path
    # holds.
    def self.system_prompt(value)
      case value
      when nil then Prompt.new(:empty)
      when String then Prompt.new(:text, value)
      when SystemPromptFile then Prompt.new(:file, value.path)
      when SystemPromptCustom then Prompt.new(:text, value.prompt)
      when SystemPromptPreset then Prompt.optional(:append, value.append)
      when Hash then HashForm.system_prompt(value)
      else Prompt.new(:none)
      end
    end

    # The +snapshot+ of a preset or custom system prompt, for the initialize
    # request: true, false, or nil when there is none to send. Only a genuine
    # true or false is answered (`snapshot: false` is the value callers set).
    # The prompt text is not looked at: a session over a transport that
    # builds no command line still gets its snapshot through.
    def self.system_prompt_snapshot(value)
      case value
      when SystemPromptPreset, SystemPromptCustom then boolean(value.snapshot)
      when Hash then boolean(HashForm.snapshot(value))
      end
    end

    # The +exclude_dynamic_sections+ of a preset system prompt, for the
    # initialize request: true, false, or nil when there is none to send.
    def self.exclude_dynamic_sections(value)
      case value
      when SystemPromptPreset then boolean(value.exclude_dynamic_sections)
      when Hash then boolean(HashForm.exclude_dynamic_sections(value))
      end
    end

    # The fields of a thinking config (see Thinking). The typed classes are
    # told apart by class, never by respond_to?: Kernel#display exists on
    # every object and prints the receiver to $stdout.
    def self.thinking(value)
      case value
      when Hash then HashForm.thinking(value)
      when ThinkingConfigAdaptive then Thinking.new(type: value.type, display: value.display)
      when ThinkingConfigEnabled
        Thinking.new(type: value.type, budget_tokens: value.budget_tokens, display: value.display)
      when ThinkingConfigDisabled then Thinking.new(type: value.type)
      else Thinking.new
      end
    end

    # DEFAULT_TOOLS for the tools preset, typed or as a Hash tagged 'preset';
    # any other value as it was given (an Array of names, the CLI's own
    # String syntax, a Hash the caller sends as JSON text).
    def self.tools(value)
      case value
      when ToolsPreset then DEFAULT_TOOLS
      when Hash then HashForm.tag(value) == 'preset' ? DEFAULT_TOOLS : value
      else value
      end
    end

    # The schema of a { type: 'json_schema', schema: ... } output format; any
    # other value is the schema itself. The value found is answered as it
    # is, false included; only the caller leaves out nil.
    def self.output_schema(value)
      value.is_a?(Hash) ? HashForm.output_schema(value) : value
    end

    # The total of a task budget, or nil when there is none. Any value that
    # is not a TaskBudget is read as a Hash, which is how one that is no
    # budget at all still fails loudly.
    def self.task_budget_total(value)
      return unless value
      return value.total if value.is_a?(TaskBudget)

      HashForm.total(value)
    end

    # One entry of +plugins+ (see Plugin); a typed SdkPluginConfig is read
    # through its #to_h, taken once. The caller refuses a type that is no
    # plugin type, asking for Plugin#raw_type only then, and skips an entry
    # without a path.
    def self.plugin(value)
      HashForm.plugin(value.is_a?(SdkPluginConfig) ? value.to_h : value)
    end

    # The sandbox section as the CLI reads it. A Hash stands for the
    # SandboxSettings with the same fields: the CLI only knows the camelCase
    # keys that class writes, and it ignores the others without an error, so
    # a Hash in Ruby spelling (deny_read, denied_domains) is renamed like the
    # typed value would be (SandboxKeys, which has key rules of its own).
    # Every other value, booleans and nil included, is answered as it is.
    def self.sandbox(value)
      case value
      when SandboxSettings then value.to_h
      when Hash then SandboxKeys.normalize(value)
      else value
      end
    end

    # True when the option enables the sandbox: `true`, a SandboxSettings
    # with +enabled+ true, or a Hash that says so under either key, which is
    # not what .sandbox sends for a Hash carrying both. Deliberately a
    # shallow read and nothing else: the transport asks from its stderr
    # threads, where walking the Hash or calling a #to_h a user can override
    # has no place.
    def self.sandbox_requested?(value)
      case value
      when SandboxSettings then value.enabled == true
      when Hash then HashForm.enabled?(value)
      else value == true
      end
    end

    # The MCP servers as the command line takes them. A Hash of servers is
    # answered as a new Hash: a typed Mcp*ServerConfig as its wire Hash
    # (as JSON it would otherwise read "#<...>"), and an sdk entry
    # (.sdk_server?) without its +instance+, under either key: the live
    # server is never serialized. Any other value (the path of a config
    # file, JSON text) is answered as it was given.
    def self.mcp_servers(value)
      return value unless value.is_a?(Hash)

      servers = {}
      value.each do |name, config|
        config = config.to_h if config.is_a?(Type)
        servers[name] = sdk_server?(config) ? config.except(:instance, 'instance') : config
      end
      servers
    end

    # The live SDK MCP servers of an +mcp_servers+ Hash, by server name: the
    # +instance+ of every sdk entry, typed or Hash. The entries are
    # recognized exactly as .mcp_servers recognizes them, which strips the
    # instance from the same ones. Empty for any other value.
    def self.sdk_mcp_servers(value)
      return {} unless value.is_a?(Hash)

      servers = {}
      value.each do |name, config|
        config = config.to_h if config.is_a?(Type)
        servers[name] = HashForm.instance(config) if sdk_server?(config)
      end
      servers
    end

    # One value of +agents+ as an AgentDefinition. A Hash stands for the
    # AgentDefinition with the same attributes and is built through .new:
    # the user wrote it, so a misspelled key raises as on the typed class.
    def self.agent_definition(value)
      value.is_a?(Hash) ? AgentDefinition.new(value) : value
    end

    # An MCP server config (a typed one already as its wire Hash) that is an
    # in-process SDK server: a Hash tagged 'sdk'.
    def self.sdk_server?(config)
      config.is_a?(Hash) && HashForm.tag(config) == 'sdk'
    end

    def self.boolean(value)
      value if [true, false].include?(value)
    end

    private_class_method :sdk_server?, :boolean
  end
end
