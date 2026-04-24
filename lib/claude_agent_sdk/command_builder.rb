# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "types"

module ClaudeAgentSDK
  # Builds the CLI argv array from a ClaudeAgentOptions instance.
  class CommandBuilder
    EXTRA_ARG_FLAG_REGEXP = /\A[a-z0-9][a-z0-9-]*\z/

    def initialize(cli_path, options)
      @cli_path = cli_path
      @options = options
    end

    def build
      cmd = [@cli_path, "--output-format", "stream-json", "--verbose"]

      append_system_prompt(cmd)
      append_tools(cmd)
      append_allowed_tools(cmd)
      append_disallowed_tools(cmd)
      append_max_turns(cmd)
      append_model(cmd)
      append_permission(cmd)
      append_session(cmd)
      append_settings(cmd)
      append_budget(cmd)
      append_thinking(cmd)
      append_effort(cmd)
      append_betas(cmd)
      append_append_allowed_tools(cmd)
      append_output_format(cmd)
      append_additional_dirs(cmd)
      append_mcp_servers(cmd)
      append_boolean_flags(cmd)
      append_plugins(cmd)
      append_setting_sources(cmd)
      append_extra_args(cmd)

      # Always use streaming mode for bidirectional control protocol.
      # Prompts and agents are sent via stdin (initialize + user messages),
      # which avoids OS ARG_MAX limits for large prompts and agent configurations.
      cmd.push("--input-format", "stream-json")

      cmd
    end

    private

    def append_system_prompt(cmd)
      case @options.system_prompt
      when nil
        # When nil, pass empty string to ensure predictable behavior without default Claude Code system prompt
        cmd.push("--system-prompt", "")
      when String
        cmd.push("--system-prompt", @options.system_prompt)
      when SystemPromptFile
        cmd.push("--system-prompt-file", @options.system_prompt.path)
      when SystemPromptPreset
        # Preset activates the default Claude Code system prompt by not passing --system-prompt ""
        # Only --append-system-prompt is passed if append text is provided
        cmd.push("--append-system-prompt", @options.system_prompt.append) if @options.system_prompt.append
      when Hash
        append_hash_system_prompt(cmd, @options.system_prompt)
      end
    end

    def append_hash_system_prompt(cmd, prompt_hash)
      prompt_type = prompt_hash[:type] || prompt_hash["type"]
      case prompt_type
      when "file"
        prompt_path = prompt_hash[:path] || prompt_hash["path"]
        cmd.push("--system-prompt-file", prompt_path) if prompt_path
      when "preset"
        append = prompt_hash[:append] || prompt_hash["append"]
        # Preset activates the default Claude Code system prompt by not passing --system-prompt ""
        cmd.push("--append-system-prompt", append) if append
      end
    end

    def append_allowed_tools(cmd)
      cmd.push("--allowedTools", @options.allowed_tools.join(",")) unless @options.allowed_tools.empty?
    end

    def append_disallowed_tools(cmd)
      cmd.push("--disallowedTools", @options.disallowed_tools.join(",")) unless @options.disallowed_tools.empty?
    end

    def append_max_turns(cmd)
      cmd.push("--max-turns", @options.max_turns.to_s) if @options.max_turns
    end

    def append_model(cmd)
      cmd.push("--model", @options.model) if @options.model
      cmd.push("--fallback-model", @options.fallback_model) if @options.fallback_model
    end

    def append_permission(cmd)
      cmd.push("--permission-prompt-tool", @options.permission_prompt_tool_name) if @options.permission_prompt_tool_name
      cmd.push("--permission-mode", @options.permission_mode) if @options.permission_mode
    end

    def append_session(cmd)
      cmd.push("--continue") if @options.continue_conversation
      cmd.push("--resume", @options.resume) if @options.resume
      cmd.push("--session-id", @options.session_id) if @options.session_id
    end

    def append_settings(cmd)
      return unless @options.settings || @options.sandbox

      settings_hash = {}
      settings_is_path = false

      if @options.settings
        if @options.settings.is_a?(String)
          begin
            settings_hash = JSON.parse(@options.settings)
          rescue JSON::ParserError
            if @options.sandbox
              settings_hash = load_settings_file(@options.settings)
            else
              settings_is_path = true
              cmd.push("--settings", @options.settings)
            end
          end
        elsif @options.settings.is_a?(Hash)
          settings_hash = @options.settings.dup
        end
      end

      if !settings_is_path && @options.sandbox
        sandbox_hash = @options.sandbox.is_a?(SandboxSettings) ? @options.sandbox.to_h : @options.sandbox
        settings_hash[:sandbox] = sandbox_hash unless sandbox_hash.empty?
      end

      cmd.push("--settings", JSON.generate(settings_hash)) if !settings_is_path && !settings_hash.empty?
    end

    def append_budget(cmd)
      cmd.push("--max-budget-usd", @options.max_budget_usd.to_s) if @options.max_budget_usd

      return unless @options.task_budget

      total = if @options.task_budget.is_a?(TaskBudget)
                @options.task_budget.total
              else
                @options.task_budget[:total] || @options.task_budget["total"]
              end
      cmd.push("--task-budget", total.to_s) if total
    end

    # Thinking configuration takes precedence over deprecated max_thinking_tokens
    def append_thinking(cmd)
      if @options.thinking
        case @options.thinking
        when ThinkingConfigAdaptive
          cmd.push("--thinking", "adaptive")
          append_thinking_display(cmd, @options.thinking.display)
        when ThinkingConfigEnabled
          cmd.push("--max-thinking-tokens", @options.thinking.budget_tokens.to_s)
          append_thinking_display(cmd, @options.thinking.display)
        when ThinkingConfigDisabled
          cmd.push("--thinking", "disabled")
        end
      elsif @options.max_thinking_tokens
        cmd.push("--max-thinking-tokens", @options.max_thinking_tokens.to_s)
      end
    end

    # `--thinking-display` toggles between `"summarized"` (visible thinking
    # text) and `"omitted"` (empty thinking, signature only). Opus 4.7 defaults
    # to `"omitted"`, so pass `display: "summarized"` to see reasoning.
    def append_thinking_display(cmd, display)
      return if display.nil?

      cmd.push("--thinking-display", display.to_s)
    end

    # The set of supported levels is model-dependent; the CLI falls back to
    # the highest supported level at or below the one requested
    # (e.g. `xhigh` → `high` on Opus 4.6).
    def append_effort(cmd)
      cmd.push("--effort", @options.effort.to_s) if @options.effort
    end

    def append_betas(cmd)
      return unless @options.betas && !@options.betas.empty?

      cmd.push("--betas", @options.betas.join(","))
    end

    def append_tools(cmd)
      return if @options.tools.nil?

      case @options.tools
      when Array
        tools_value = @options.tools.empty? ? "" : @options.tools.join(",")
        cmd.push("--tools", tools_value)
      when ToolsPreset
        cmd.push("--tools", "default")
      when Hash
        if (@options.tools[:type] || @options.tools["type"]) == "preset"
          cmd.push("--tools", "default")
        else
          cmd.push("--tools", JSON.generate(@options.tools))
        end
      end
    end

    def append_append_allowed_tools(cmd)
      return unless @options.append_allowed_tools && !@options.append_allowed_tools.empty?

      cmd.push("--append-allowed-tools", @options.append_allowed_tools.join(","))
    end

    def append_output_format(cmd)
      return unless @options.output_format

      schema = if @options.output_format.is_a?(Hash) && @options.output_format[:type] == "json_schema"
                 @options.output_format[:schema]
               elsif @options.output_format.is_a?(Hash) && @options.output_format["type"] == "json_schema"
                 @options.output_format["schema"]
               else
                 @options.output_format
               end
      schema_json = schema.is_a?(String) ? schema : JSON.generate(schema)
      cmd.push("--json-schema", schema_json)
    end

    def append_additional_dirs(cmd)
      @options.add_dirs.each { |dir| cmd.push("--add-dir", dir.to_s) }
    end

    def append_mcp_servers(cmd)
      return unless @options.mcp_servers && !@options.mcp_servers.empty?

      if @options.mcp_servers.is_a?(Hash)
        servers_for_cli = {}
        @options.mcp_servers.each do |name, config|
          servers_for_cli[name] = if config.is_a?(Hash) && config[:type] == "sdk"
                                    config.except(:instance)
                                  else
                                    config
                                  end
        end
        cmd.push("--mcp-config", JSON.generate({ mcpServers: servers_for_cli })) unless servers_for_cli.empty?
      else
        cmd.push("--mcp-config", @options.mcp_servers.to_s)
      end
    end

    # NOTE: agents are sent via the initialize control request (not CLI args)
    # to avoid OS ARG_MAX limits with large agent configurations.
    def append_boolean_flags(cmd)
      cmd.push("--include-partial-messages") if @options.include_partial_messages
      cmd.push("--fork-session") if @options.fork_session
      cmd.push("--bare") if @options.bare
    end

    def append_plugins(cmd)
      return unless @options.plugins && !@options.plugins.empty?

      @options.plugins.each do |plugin|
        plugin_config = plugin.is_a?(SdkPluginConfig) ? plugin.to_h : plugin
        plugin_type = plugin_config[:type] || plugin_config["type"]
        plugin_path = plugin_config[:path] || plugin_config["path"]

        raise ArgumentError, "Unsupported plugin type: #{plugin_type.inspect}" unless %w[local plugin].include?(plugin_type)
        next unless plugin_path

        cmd.push("--plugin-dir", plugin_path)
      end
    end

    def append_setting_sources(cmd)
      return unless @options.setting_sources

      cmd.push("--setting-sources", @options.setting_sources.join(","))
    end

    def append_extra_args(cmd)
      @options.extra_args.each do |flag, value|
        raise ArgumentError, "Invalid extra_args flag name: #{flag.inspect} (expected lowercase kebab-case)" unless EXTRA_ARG_FLAG_REGEXP.match?(flag)

        if value.nil?
          cmd.push("--#{flag}")
        else
          cmd.push("--#{flag}", value.to_s)
        end
      end
    end

    def load_settings_file(path)
      raise CLIConnectionError, "Settings file not found: #{path}" unless File.file?(path)

      JSON.parse(File.read(path))
    end
  end
end
