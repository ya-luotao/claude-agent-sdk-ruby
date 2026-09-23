# frozen_string_literal: true

require 'set'

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

      # Test hook: forget which deprecations were already reported.
      def reset!
        @mutex.synchronize { @warned.clear }
      end
    end
  end
end
