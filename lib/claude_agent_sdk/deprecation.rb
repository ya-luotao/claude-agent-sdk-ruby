# frozen_string_literal: true

module ClaudeAgentSDK
  # One-time deprecation warnings for public API slated for removal in the
  # next major release (see the deprecation policy in issue #126).
  #
  # Emitted with plain Kernel#warn, deliberately NOT `category: :deprecated`:
  # Ruby hides that category unless Warning[:deprecated] is enabled (off by
  # default since 2.7.2, still off on 3.2-3.4), so a category-tagged warning
  # would reach almost nobody before the removal. Plain warn is visible by
  # default and still silenced by `-W0` / `$VERBOSE = nil`.
  #
  # @api private
  module Deprecation
    @warned = Set.new
    @mutex = Mutex.new

    class << self
      # Warn once per process that ClaudeAgentSDK.+name+ is deprecated.
      #
      # Must be called directly from the deprecated method: `uplevel: 2`
      # skips this frame and the deprecated method's, so the warning names
      # the caller's file:line.
      #
      # Best-effort like OptionWarnings#emit: a closed or broken $stderr must
      # not turn a still-supported call into an IOError. The name stays
      # recorded either way (once per process means once).
      #
      # @param name [Symbol] the deprecated ClaudeAgentSDK module method
      # @param replacement [String] the call to use instead, without the
      #   ClaudeAgentSDK. prefix
      # @return [void]
      def warn_once(name, replacement)
        first = @mutex.synchronize { @warned.add?(name) }
        return unless first

        begin
          warn("ClaudeAgentSDK.#{name} is deprecated and will be removed in 1.0; " \
               "use ClaudeAgentSDK.#{replacement}", uplevel: 2)
        rescue StandardError
          nil
        end
      end

      # Warn +message+ once per process per +key+, attributed to the first
      # caller frame outside the SDK's lib/ directory: the user's call site,
      # however deep inside the SDK the deprecated behaviour is detected
      # (e.g. an unknown attribute found by Type#assign_attribute during
      # HookMatcher.new). Best-effort like #warn_once.
      #
      # @param key [Object] once-guard key; any value usable in a Set
      # @param message [String]
      # @return [void]
      def warn_once_at_caller(key, message)
        first = @mutex.synchronize { @warned.add?(key) }
        return unless first

        begin
          locations = caller_locations(1)
          index = locations.index { |location| !sdk_frame?(location) }
          index ? warn(message, uplevel: index + 1) : warn(message)
        rescue StandardError
          nil
        end
      end

      # Test hook: forget which deprecations were already reported.
      def reset!
        @mutex.synchronize { @warned.clear }
      end

      private

      # A frame inside the gem's lib/ (both the loaded and the real path, in
      # case lib/ is reached through a symlink), or a Ruby-internal one
      # (<internal:...>, e.g. Array#each on 3.4). A C frame such as Class#new
      # reports its caller's path, so it counts as the caller's.
      def sdk_frame?(location)
        path = location.absolute_path || location.path
        return true if path.nil? || path.start_with?('<internal:')

        SDK_LIB_DIRS.any? { |dir| path.start_with?(dir) }
      end
    end

    SDK_LIB_DIRS = [File.expand_path('..', File.dirname(__FILE__)), File.expand_path('..', __dir__)]
                   .uniq.map { |dir| "#{dir}/" }.freeze
    private_constant :SDK_LIB_DIRS
  end
end
