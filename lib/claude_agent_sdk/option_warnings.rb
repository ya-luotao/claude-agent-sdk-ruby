# frozen_string_literal: true

require 'set'

module ClaudeAgentSDK
  # Advisory warnings for option combinations that silently change behavior.
  module OptionWarnings
    @emitted = Set.new
    @mutex = Mutex.new

    class << self
      # can_use_tool is only consulted when the CLI's permission ladder lands
      # on "ask". Anything that auto-approves a tool call earlier in the
      # ladder means the callback never runs — so a callback written for
      # *security* purposes can silently be dead code (real callers have
      # shipped path-jails that never fired because the same tools were
      # listed bare in allowed_tools).
      #
      # Advisory only (never raises): shadowing can be intentional, e.g. a
      # callback used solely for tools outside allowed_tools. Deliberately
      # silent on permission_mode 'acceptEdits' (it only auto-approves in-cwd
      # file edits, so warning would be a false positive for anyone gating
      # Bash/network/MCP tools) and on real specifiers like "Bash(ls:*)"
      # (they only shadow matching invocations, not the whole tool).
      def warn_if_can_use_tool_shadowed(options)
        return unless options.can_use_tool

        message = can_use_tool_shadowed_message(options)
        emit(message) if message
      end

      # Test hook: forget which messages were already emitted.
      def reset!
        @mutex.synchronize { @emitted.clear }
      end

      private

      # Each distinct message is emitted once per process (mirrors Python's
      # default UserWarning filter), so an app constructing a client per
      # request does not repeat the same warning on every connect.
      def emit(message)
        first = @mutex.synchronize { @emitted.add?(message) }
        warn "Claude SDK: #{message}" if first
      end

      def can_use_tool_shadowed_message(options)
        # bypassPermissions shadows the callback for EVERY tool, so it takes
        # precedence over naming individual allowed_tools entries.
        if options.permission_mode == 'bypassPermissions'
          return 'can_use_tool will not be invoked: permission_mode ' \
                 "'bypassPermissions' auto-approves every tool call (except " \
                 'explicit deny rules) before the callback is consulted. To ' \
                 'gate every tool call, use a PreToolUse hook instead.'
        end

        shadowed = shadowed_tools(options)
        return nil if shadowed.empty?

        "can_use_tool will not be invoked for: #{shadowed.join(', ')}. " \
          'An allowed_tools entry that allows a whole tool auto-approves it ' \
          'before the callback is consulted. To gate every tool call, use a ' \
          'PreToolUse hook; or narrow the entry so calls fall through to ' \
          'can_use_tool. Allow rules from settings files can also shadow the ' \
          'callback but are not visible here.'
      end

      # skills: 'all' makes the command builder append a bare "Skill" to the
      # effective allowed_tools (CommandBuilder#skills_defaults), so it
      # shadows the callback just like a hand-written entry; skills: [names]
      # appends Skill(name) specifiers, which do not.
      def shadowed_tools(options)
        allowed_tools = options.allowed_tools || []
        allowed_tools += ['Skill'] if options.skills == 'all' && !allowed_tools.include?('Skill')
        allowed_tools.filter_map { |entry| whole_tool_allowed(entry) }.uniq
      end

      # Returns the tool an allowed_tools entry allows outright, else nil.
      #
      # Mirrors the CLI's rule parser (permissionRuleValueFromString): an
      # entry allows a whole tool when it has no (...) specifier ("Read"),
      # or when the specifier is empty or a lone wildcard ("Read()",
      # "Read(*)") — the CLI collapses both to a tool-wide rule. A malformed
      # entry ("Bash(ls:*" without the closing paren, "(*)") falls back to
      # being read as a whole-string tool name by the CLI, which then
      # matches nothing — so it shadows nothing and is ignored here.
      def whole_tool_allowed(entry)
        entry = entry.to_s
        return nil if entry.strip.empty?

        open_index = entry.index('(')
        return entry if open_index.nil?
        return nil if open_index.zero? || !entry.end_with?(')')

        specifier = entry[(open_index + 1)...-1]
        ['', '*'].include?(specifier) ? entry[0...open_index] : nil
      end
    end
  end
end
