# frozen_string_literal: true

require_relative '../deprecation'

module ClaudeAgentSDK
  # Base class for all types.
  class Type
    # What a strict type (see .strict_attributes) does with an unknown
    # attribute: :warn (once per class and key) through 0.x, :raise from 1.0.
    UNKNOWN_ATTRIBUTE_ACTION = :warn

    LENIENT_KEY = :__claude_agent_sdk_lenient_attributes
    private_constant :UNKNOWN_ATTRIBUTE_ACTION, :LENIENT_KEY

    # Lenient, like every parse path: never warns or raises on an unknown key.
    def self.wrap(object)
      return object if object.is_a?(self)
      return nil if object.nil?

      lenient { new(object) }
    end

    # Lenient, like every parse path: never warns or raises on an unknown key.
    def self.from_hash(hash)
      return unless hash.is_a?(Hash)

      lenient { new(hash) }
    end

    # Declares a type the user constructs and passes IN (option values, hook
    # matchers and outputs, permission results and updates). Constructing
    # one directly (.new or #[]=) with a key that is neither a setter nor a
    # public reader warns once per class and key — a typo would otherwise be
    # dropped silently — and raises ArgumentError from 1.0. Types the SDK
    # parses from CLI output stay lenient so a newer CLI's extra fields never
    # break an older SDK; so does every construction through .from_hash or
    # .wrap. Inherited by subclasses.
    #
    # @api private
    def self.strict_attributes
      @strict_attributes = true
    end

    # @api private
    def self.strict_attributes?
      @strict_attributes || (superclass <= Type && superclass.strict_attributes?)
    end

    # The attribute names (snake_case) a strict type accepts: its setters
    # plus its public readers, so the discriminator a type sets itself
    # (+type+, +hook_event_name+, +behavior+) — which its own #to_h emits —
    # round-trips silently. Type's own methods (#to_h, #inspect, ...) are
    # not attributes.
    #
    # @api private
    def self.known_attribute_names
      public_instance_methods.filter_map do |method_name|
        owner = instance_method(method_name).owner
        next unless owner.is_a?(Class) && owner < Type && !Type.public_method_defined?(method_name, false)

        method_name.to_s.delete_suffix('=') if method_name.match?(/\A[a-z_]\w*=?\z/)
      end.uniq.sort
    end

    # Runs the block with the strict-attribute check off on this fiber, for
    # the SDK's own parse paths (CLI payloads and their nested values).
    def self.lenient
      previous = Thread.current[LENIENT_KEY]
      Thread.current[LENIENT_KEY] = true
      yield
    ensure
      Thread.current[LENIENT_KEY] = previous
    end
    private_class_method :lenient

    def initialize(attributes = {})
      assign_attributes(attributes) if attributes
      super()
    end

    def [](name)
      read_attribute(name)
    end

    def []=(name, value)
      assign_attribute(name, value)
    end

    # Subclasses should override this to return a hash representation of the object.
    def to_h
      {}
    end

    # The copy hook used wherever ClaudeAgentOptions are copied (dup_with and
    # the configured-defaults merge). Identity by default: most Type instances
    # are messages or callback payloads that never live inside options, and a
    # user-supplied object that does (an observer, a store adapter) must stay
    # the same object. Option VALUE types include OptionValue to opt in to
    # copying, so a per-session change to e.g. sandbox rules can never reach
    # another session or the configured defaults.
    #
    # @api private
    def dup_for_options
      self
    end

    # Mixed into the mutable value types that ClaudeAgentOptions holds
    # (SandboxSettings, SystemPromptPreset, AgentDefinition, ...). The copy
    # recurses into the value's own state with Type.deep_dup_for_options, so
    # nested containers and nested value types (SandboxSettings#network) are
    # copied too while identity leaves (McpSdkServerConfig#instance, the
    # callables in HookMatcher#hooks) stay shared. #dup never copies frozen
    # state, so a copy of a frozen value (the configured-defaults snapshot) is
    # mutable.
    #
    # @api private
    module OptionValue
      def dup_for_options
        copy = dup
        copy.instance_variables.each do |ivar|
          copy.instance_variable_set(ivar, Type.deep_dup_for_options(copy.instance_variable_get(ivar)))
        end
        copy
      end
    end

    # Recurse into Hash/Array containers and option value types, and copy
    # mutable (unfrozen) Strings — a caller-built prompt, model or
    # allowed_tools entry is as much shared state as an Array, and `str <<
    # 'x'` on one copy would otherwise change every other. A frozen String
    # (any literal under frozen_string_literal) is immutable and keeps
    # identity. Every other leaf keeps object identity (observer factories,
    # callbacks, SDK MCP server instances must not be duped). Rebuild
    # containers via dup.clear (never Hash#to_h / Array#map) to preserve
    # container SUBCLASSES: to_h flattens e.g. Rails'
    # HashWithIndifferentAccess into a plain Hash, silently breaking symbol
    # lookups on the copy (config[:type] == 'sdk' → nil). Hash keys: Ruby
    # already stores a dup'd, frozen copy of an unfrozen plain String key, but
    # not of a String SUBCLASS key, so those are copied (and frozen, as keys
    # should be) here. A compare_by_identity Hash is left keyed by the
    # caller's objects: copying a key would break the caller's own lookups.
    #
    # @api private
    def self.deep_dup_for_options(value)
      case value
      when Hash
        copy = value.dup.clear
        value.each { |k, v| copy[option_hash_key(k, value)] = deep_dup_for_options(v) }
        copy
      when Array
        copy = value.dup.clear
        value.each { |v| copy << deep_dup_for_options(v) }
        copy
      when Type then value.dup_for_options
      when String then value.frozen? ? value : value.dup # #dup keeps subclass and encoding
      else value
      end
    end

    def self.option_hash_key(key, hash)
      return key unless key.is_a?(String) && !key.frozen? && !hash.compare_by_identity?

      key.dup.freeze
    end
    private_class_method :option_hash_key

    # Bounded, human-oriented #inspect listing the non-nil instance variables
    # in definition order:
    #
    #   #<ClaudeAgentSDK::ResultMessage subtype="success" num_turns=3 ...>
    #
    # Messages carry whole transcripts, tool payloads and usage maps, so the
    # output is bounded rather than faithful: long Strings are truncated,
    # long Arrays/Hashes abbreviated, and nesting past INSPECT_MAX_DEPTH (or
    # a reference cycle) collapses to a placeholder. Other objects keep their
    # own #inspect (truncated) unless they only have Kernel#inspect, which
    # dumps every ivar recursively — those (SDK MCP server instances, store
    # adapters, observers) show as `#<ClassName>`. For display only: nothing
    # sent to the CLI goes through #inspect or #to_s (wire output uses #to_h).
    def inspect
      inspect_with(0, {}.compare_by_identity)
    end

    # Object#to_s ignores instance variables, so `puts message` would print
    # only a class name and an address. Types with a natural textual form
    # (UserMessage, AssistantMessage, TextBlock, ResultMessage, SystemMessage)
    # override this.
    def to_s
      inspect
    end

    # Declares attributes that carry credentials (env vars, auth headers).
    # Objects get logged, so #inspect shows them filtered; #to_h and
    # everything sent to the CLI are unaffected. Inherited by subclasses.
    #
    # @api private
    def self.inspect_filtered(*names)
      @inspect_filtered_attributes = (inspect_filtered_attributes + names.map(&:to_s)).uniq.freeze
    end

    # @api private
    def self.inspect_filtered_attributes
      @inspect_filtered_attributes || (superclass <= Type ? superclass.inspect_filtered_attributes : [].freeze)
    end

    INSPECT_MAX_STRING = 80
    INSPECT_MAX_ITEMS = 5
    INSPECT_MAX_DEPTH = 2
    private_constant :INSPECT_MAX_STRING, :INSPECT_MAX_ITEMS, :INSPECT_MAX_DEPTH

    protected

    # `seen` holds the Types/containers on the current rendering path (not
    # every one rendered so far), so a shared-but-acyclic value still renders
    # in full wherever it appears.
    def inspect_with(depth, seen)
      return "#<#{inspect_class_name} …>" if depth > INSPECT_MAX_DEPTH || seen.key?(self)

      seen[self] = true
      begin
        attributes = inspect_attributes.map do |name, value|
          " #{name}=#{inspect_bounded(value, depth + 1, seen)}"
        end
        "#<#{inspect_class_name}#{attributes.join}>"
      ensure
        seen.delete(self)
      end
    end

    private

    # [name, value] pairs rendered by #inspect. Subclasses override to hide
    # redundant state or redact secrets — never by mutating the object.
    def inspect_attributes
      filtered = self.class.inspect_filtered_attributes
      instance_variables.filter_map do |ivar|
        value = instance_variable_get(ivar)
        next if value.nil?

        name = ivar.to_s.delete_prefix('@')
        [name, filtered.include?(name) ? inspect_filter(value) : value]
      end
    end

    # A credential-bearing Hash keeps its keys (useful when debugging which
    # variables are set) with every value replaced; anything else is replaced
    # outright. Builds a new Hash; the object itself is never touched.
    def inspect_filter(value)
      value.respond_to?(:each_key) ? value.each_key.to_h { |key| [key, '[FILTERED]'] } : '[FILTERED]'
    end

    def inspect_class_name
      self.class.name || self.class.inspect
    end

    def inspect_bounded(value, depth, seen)
      case value
      when Type then value.inspect_with(depth, seen)
      when String then inspect_truncated(value)
      when Array then inspect_container(value, '[', ']', depth, seen) { |item| inspect_bounded(item, depth + 1, seen) }
      when Hash
        inspect_container(value, '{', '}', depth, seen) do |key, item|
          "#{inspect_hash_key(key, depth + 1, seen)}#{inspect_bounded(item, depth + 1, seen)}"
        end
      when Proc, Method, UnboundMethod then inspect_callable(value)
      else inspect_leaf(value)
      end
    end

    def inspect_container(value, open, close, depth, seen, &)
      return "#{open}#{close}" if value.empty?
      return "#{open}…(#{value.size})#{close}" if depth > INSPECT_MAX_DEPTH || seen.key?(value)

      seen[value] = true
      begin
        parts = value.first(INSPECT_MAX_ITEMS).map(&)
        parts << "…(+#{value.size - INSPECT_MAX_ITEMS} more)" if value.size > INSPECT_MAX_ITEMS
        "#{open}#{parts.join(', ')}#{close}"
      ensure
        seen.delete(value)
      end
    end

    # Rendered by hand rather than via Hash#inspect, whose format differs
    # between Ruby 3.3 (`{:a=>1}`) and 3.4 (`{a: 1}`).
    def inspect_hash_key(key, depth, seen)
      return "#{key.name}: " if key.is_a?(Symbol) && key.inspect.match?(/\A:\w+[?!]?\z/)

      "#{inspect_bounded(key, depth, seen)} => "
    end

    def inspect_truncated(string)
      return string.inspect if string.length <= INSPECT_MAX_STRING

      "#{string[0, INSPECT_MAX_STRING].inspect}…(+#{string.length - INSPECT_MAX_STRING} chars)"
    end

    # Callbacks (can_use_tool, hooks, callback_wrapper, ...) are user-supplied:
    # render them from source_location rather than their own #inspect, which
    # a subclass may override (and raise from) and which embeds an absolute
    # path — `#<Proc(lambda) permissions.rb:17>`, `#<Method Policy#call>`.
    def inspect_callable(value)
      label = if value.is_a?(Proc)
                value.lambda? ? 'Proc(lambda)' : 'Proc'
              else
                "#{value.class.name} #{value.owner.name || value.owner.inspect}##{value.name}"
              end
      file, line = value.source_location
      rendered = file ? "#<#{label} #{File.basename(file)}:#{line}>" : "#<#{label}>"
      inspect_truncated_text(rendered)
    rescue StandardError
      inspect_leaf(value)
    end

    def inspect_truncated_text(rendered)
      return rendered if rendered.length <= INSPECT_MAX_STRING

      "#{rendered[0, INSPECT_MAX_STRING]}…(+#{rendered.length - INSPECT_MAX_STRING} chars)"
    end

    # Printing must never raise (it runs inside loggers and `puts`), so an
    # object whose #inspect raises, or a BasicObject without one, falls back
    # to a placeholder.
    def inspect_leaf(value)
      return "#<#{value.class}>" if kernel_inspect_only?(value)

      inspect_truncated_text(value.inspect)
    rescue StandardError
      begin
        "#<#{value.class}>"
      rescue StandardError
        '#<?>'
      end
    end

    def kernel_inspect_only?(value)
      Kernel.instance_method(:method).bind_call(value, :inspect).owner == Kernel
    rescue TypeError # not a Kernel object: BasicObject, Delegator
      false
    end

    # Allow camelCase attribute access
    def method_missing(method_name, ...)
      normalized = normalize_name(method_name)

      if normalized != method_name.to_s && respond_to?(normalized)
        public_send(normalized, ...)
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      normalized = normalize_name(method_name)
      (normalized != method_name.to_s && respond_to?(normalized)) || super
    end

    def assign_attributes(attributes)
      raise ArgumentError, "When assigning attributes, you must pass a hash as an argument, #{attributes.inspect} passed." unless attributes.respond_to?(:each_pair)

      return if attributes.empty?

      attributes.each_pair { |name, value| assign_attribute(name, value) }
    end

    def assign_attribute(name, value)
      normalized = normalize_name(name)
      setter = :"#{normalized}="
      if respond_to?(setter)
        public_send(setter, value)
      elsif self.class.strict_attributes? && !Thread.current[LENIENT_KEY] &&
            !self.class.known_attribute_names.include?(normalized)
        unknown_attribute(name, normalized)
      end
    end

    def unknown_attribute(name, normalized)
      klass = self.class
      class_name = klass.name || klass.inspect
      known = klass.known_attribute_names.join(', ')
      raise ArgumentError, "#{class_name}: unknown attribute #{name.inspect} (known: #{known})" if UNKNOWN_ATTRIBUTE_ACTION == :raise

      Deprecation.warn_once_at_caller(
        [:unknown_attribute, klass, normalized],
        "#{class_name}: unknown attribute #{name.inspect} ignored; " \
        "this will raise ArgumentError in 1.0 (known: #{known})"
      )
    end

    def read_attribute(name)
      getter = normalize_name(name)
      public_send(getter) if respond_to?(getter)
    end

    def normalize_name(name)
      name = name.to_s.dup
      name.gsub!(/(?<=[A-Z])(?=[A-Z][a-z])|(?<=[a-z\d])(?=[A-Z])/, "_")
      name.tr!("-", "_")
      name.downcase!
      name
    end

    FALSE_VALUES = [
      false, 0,
      "0", :'0',
      "f", :f,
      "F", :F,
      "false", :false, # rubocop:disable Lint/BooleanSymbol
      "FALSE", :FALSE,
      "off", :off,
      "OFF", :OFF
    ].to_set.freeze

    private_constant :FALSE_VALUES

    def coerce_boolean(value)
      return if value.nil?

      if value == ""
        nil
      else
        !FALSE_VALUES.include?(value)
      end
    end
  end
end
