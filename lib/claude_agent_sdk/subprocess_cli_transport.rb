# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'transport'
require_relative 'errors'
require_relative 'version'

module ClaudeAgentSDK
  # Subprocess transport using Claude Code CLI
  class SubprocessCLITransport < Transport
    DEFAULT_MAX_BUFFER_SIZE = 1024 * 1024 # 1MB buffer limit
    MINIMUM_CLAUDE_CODE_VERSION = '2.0.0'

    def initialize(prompt, options)
      @prompt = prompt
      @is_streaming = !prompt.is_a?(String)
      @options = options
      @cli_path = options.cli_path || find_cli
      @cwd = options.cwd
      @process = nil
      @stdin = nil
      @stdout = nil
      @stderr = nil
      @ready = false
      @exit_error = nil
      @max_buffer_size = options.max_buffer_size || DEFAULT_MAX_BUFFER_SIZE
      @stderr_task = nil
    end

    def find_cli
      # Try which command first
      cli = `which claude 2>/dev/null`.strip
      return cli unless cli.empty?

      # Try common locations
      locations = [
        File.join(Dir.home, '.claude/local/claude'),  # Claude Code default install location
        File.join(Dir.home, '.npm-global/bin/claude'),
        '/usr/local/bin/claude',
        File.join(Dir.home, '.local/bin/claude'),
        File.join(Dir.home, 'node_modules/.bin/claude'),
        File.join(Dir.home, '.yarn/bin/claude')
      ]

      locations.each do |path|
        return path if File.exist?(path) && File.file?(path)
      end

      raise CLINotFoundError.new(
        "Claude Code not found. Install with:\n" \
        "  npm install -g @anthropic-ai/claude-code\n" \
        "\nIf already installed locally, try:\n" \
        '  export PATH="$HOME/node_modules/.bin:$PATH"' \
        "\n\nOr provide the path via ClaudeAgentOptions:\n" \
        "  ClaudeAgentOptions.new(cli_path: '/path/to/claude')"
      )
    end

    def build_command
      cmd = [@cli_path, '--output-format', 'stream-json', '--verbose']

      # System prompt handling
      if @options.system_prompt
        if @options.system_prompt.is_a?(String)
          cmd.concat(['--system-prompt', @options.system_prompt])
        elsif @options.system_prompt.is_a?(SystemPromptPreset)
          cmd.concat(['--system-prompt-preset', @options.system_prompt.preset]) if @options.system_prompt.preset
          cmd.concat(['--append-system-prompt', @options.system_prompt.append]) if @options.system_prompt.append
        elsif @options.system_prompt.is_a?(Hash)
          prompt_type = @options.system_prompt[:type] || @options.system_prompt['type']
          if prompt_type == 'preset'
            preset = @options.system_prompt[:preset] || @options.system_prompt['preset']
            append = @options.system_prompt[:append] || @options.system_prompt['append']
            cmd.concat(['--system-prompt-preset', preset]) if preset
            cmd.concat(['--append-system-prompt', append]) if append
          end
        end
      end

      cmd.concat(['--allowedTools', @options.allowed_tools.join(',')]) unless @options.allowed_tools.empty?
      cmd.concat(['--max-turns', @options.max_turns.to_s]) if @options.max_turns
      cmd.concat(['--disallowedTools', @options.disallowed_tools.join(',')]) unless @options.disallowed_tools.empty?
      cmd.concat(['--model', @options.model]) if @options.model
      cmd.concat(['--fallback-model', @options.fallback_model]) if @options.fallback_model
      cmd.concat(['--permission-prompt-tool', @options.permission_prompt_tool_name]) if @options.permission_prompt_tool_name
      cmd.concat(['--permission-mode', @options.permission_mode]) if @options.permission_mode
      cmd << '--continue' if @options.continue_conversation
      cmd.concat(['--resume', @options.resume]) if @options.resume

      # Settings handling with sandbox merge
      # Sandbox settings are merged into the main settings JSON
      if @options.settings || @options.sandbox
        settings_hash = {}
        settings_is_path = false

        # Parse existing settings if provided
        if @options.settings
          if @options.settings.is_a?(String)
            begin
              settings_hash = JSON.parse(@options.settings)
            rescue JSON::ParserError
              # If not valid JSON, treat as file path and pass as-is
              settings_is_path = true
              cmd.concat(['--settings', @options.settings])
              if @options.sandbox
                warn "Warning: Cannot merge sandbox settings when settings is a file path. " \
                     "Sandbox settings will be ignored. Use a Hash or JSON string for settings " \
                     "to enable sandbox merging."
              end
            end
          elsif @options.settings.is_a?(Hash)
            settings_hash = @options.settings.dup
          end
        end

        # Merge sandbox settings if provided (only when settings is not a file path)
        if !settings_is_path && @options.sandbox
          sandbox_hash = if @options.sandbox.is_a?(SandboxSettings)
                           @options.sandbox.to_h
                         else
                           @options.sandbox
                         end
          settings_hash[:sandbox] = sandbox_hash unless sandbox_hash.empty?
        end

        # Output merged settings (only when settings is not a file path)
        if !settings_is_path && !settings_hash.empty?
          cmd.concat(['--settings', JSON.generate(settings_hash)])
        end
      end

      # Budget limit option
      cmd.concat(['--max-budget-usd', @options.max_budget_usd.to_s]) if @options.max_budget_usd
      # Note: max_thinking_tokens is stored in options but not yet supported by Claude CLI

      # Betas option for enabling experimental features
      if @options.betas && !@options.betas.empty?
        cmd.concat(['--betas', @options.betas.join(',')])
      end

      # Tools option for base tools selection
      if @options.tools
        if @options.tools.is_a?(Array)
          cmd.concat(['--tools', @options.tools.join(',')])
        elsif @options.tools.is_a?(ToolsPreset)
          cmd.concat(['--tools', JSON.generate(@options.tools.to_h)])
        elsif @options.tools.is_a?(Hash)
          cmd.concat(['--tools', JSON.generate(@options.tools)])
        end
      end

      # Append allowed tools option
      if @options.append_allowed_tools && !@options.append_allowed_tools.empty?
        cmd.concat(['--append-allowed-tools', @options.append_allowed_tools.join(',')])
      end

      # File checkpointing for rewind support
      cmd << '--enable-file-checkpointing' if @options.enable_file_checkpointing

      # JSON schema for structured output
      # Accepts either:
      # 1. Direct schema: { type: 'object', properties: {...} }
      # 2. Wrapped format: { type: 'json_schema', schema: {...} }
      if @options.output_format
        schema = if @options.output_format.is_a?(Hash) && @options.output_format[:type] == 'json_schema'
                   @options.output_format[:schema]
                 elsif @options.output_format.is_a?(Hash) && @options.output_format['type'] == 'json_schema'
                   @options.output_format['schema']
                 else
                   @options.output_format
                 end
        schema_json = schema.is_a?(String) ? schema : JSON.generate(schema)
        cmd.concat(['--json-schema', schema_json])
      end

      # Add directories
      @options.add_dirs.each do |dir|
        cmd.concat(['--add-dir', dir.to_s])
      end

      # MCP servers
      if @options.mcp_servers && !@options.mcp_servers.empty?
        if @options.mcp_servers.is_a?(Hash)
          servers_for_cli = {}
          @options.mcp_servers.each do |name, config|
            if config.is_a?(Hash) && config[:type] == 'sdk'
              # For SDK servers, exclude instance field
              sdk_config = config.reject { |k, _| k == :instance }
              servers_for_cli[name] = sdk_config
            else
              servers_for_cli[name] = config
            end
          end
          cmd.concat(['--mcp-config', JSON.generate({ mcpServers: servers_for_cli })]) unless servers_for_cli.empty?
        else
          cmd.concat(['--mcp-config', @options.mcp_servers.to_s])
        end
      end

      cmd << '--include-partial-messages' if @options.include_partial_messages
      cmd << '--fork-session' if @options.fork_session

      # Agents
      if @options.agents
        agents_dict = @options.agents.transform_values do |agent_def|
          {
            description: agent_def.description,
            prompt: agent_def.prompt,
            tools: agent_def.tools,
            model: agent_def.model
          }.compact
        end
        cmd.concat(['--agents', JSON.generate(agents_dict)])
      end

      # Plugins
      if @options.plugins && !@options.plugins.empty?
        plugins_config = @options.plugins.map do |plugin|
          plugin.is_a?(SdkPluginConfig) ? plugin.to_h : plugin
        end
        cmd.concat(['--plugins', JSON.generate(plugins_config)])
      end

      # Setting sources
      sources_value = @options.setting_sources ? @options.setting_sources.join(',') : ''
      cmd.concat(['--setting-sources', sources_value])

      # Extra args
      @options.extra_args.each do |flag, value|
        if value.nil?
          cmd << "--#{flag}"
        else
          cmd.concat(["--#{flag}", value.to_s])
        end
      end

      # Prompt handling
      if @is_streaming
        cmd.concat(['--input-format', 'stream-json'])
      else
        cmd.concat(['--print', '--', @prompt.to_s])
      end

      cmd
    end

    def connect
      return if @process

      check_claude_version

      cmd = build_command

      # Build environment
      process_env = ENV.to_h.merge(@options.env).merge(
        'CLAUDE_CODE_ENTRYPOINT' => 'sdk-rb',
        'CLAUDE_AGENT_SDK_VERSION' => VERSION
      )
      process_env['PWD'] = @cwd.to_s if @cwd

      # Determine stderr handling
      should_pipe_stderr = @options.stderr || @options.debug_stderr || @options.extra_args.key?('debug-to-stderr')

      begin
        # Start process using Open3
        opts = { chdir: @cwd&.to_s }.compact

        @stdin, @stdout, @stderr, @process = Open3.popen3(process_env, *cmd, opts)

        # Handle stderr if piped
        if should_pipe_stderr && @stderr
          @stderr_task = Thread.new do
            handle_stderr
          rescue StandardError
            # Ignore errors during stderr reading
          end
        end

        # Close stdin for non-streaming mode
        @stdin.close unless @is_streaming
        @stdin = nil unless @is_streaming

        @ready = true
      rescue Errno::ENOENT => e
        # Check if error is from cwd or CLI
        if @cwd && !File.directory?(@cwd.to_s)
          error = CLIConnectionError.new("Working directory does not exist: #{@cwd}")
          @exit_error = error
          raise error
        end
        error = CLINotFoundError.new("Claude Code not found at: #{@cli_path}")
        @exit_error = error
        raise error
      rescue StandardError => e
        error = CLIConnectionError.new("Failed to start Claude Code: #{e}")
        @exit_error = error
        raise error
      end
    end

    def handle_stderr
      return unless @stderr

      @stderr.each_line do |line|
        line_str = line.chomp
        next if line_str.empty?

        # Call stderr callback if provided
        @options.stderr&.call(line_str)

        # Write to debug_stderr file/IO if provided
        if @options.debug_stderr
          if @options.debug_stderr.respond_to?(:puts)
            @options.debug_stderr.puts(line_str)
          elsif @options.debug_stderr.is_a?(String)
            File.open(@options.debug_stderr, 'a') { |f| f.puts(line_str) }
          end
        end
      end
    rescue StandardError
      # Ignore errors during stderr reading
    end

    def close
      @ready = false
      return unless @process

      # Kill stderr thread
      if @stderr_task&.alive?
        @stderr_task.kill
        @stderr_task.join(1) rescue nil
      end

      # Close streams
      begin
        @stdin&.close
      rescue StandardError
        # Ignore
      end
      begin
        @stdout&.close
      rescue StandardError
        # Ignore
      end
      begin
        @stderr&.close
      rescue StandardError
        # Ignore
      end

      # Terminate process
      begin
        Process.kill('TERM', @process.pid) if @process.alive?
        @process.value
      rescue StandardError
        # Ignore
      end

      @process = nil
      @stdout = nil
      @stdin = nil
      @stderr = nil
      @stderr_task = nil
      @exit_error = nil
    end

    def write(data)
      raise CLIConnectionError, 'ProcessTransport is not ready for writing' unless @ready && @stdin
      raise CLIConnectionError, "Cannot write to terminated process" if @process && !@process.alive?

      raise CLIConnectionError, "Cannot write to process that exited with error: #{@exit_error}" if @exit_error

      begin
        @stdin.write(data)
        @stdin.flush
      rescue StandardError => e
        @ready = false
        @exit_error = CLIConnectionError.new("Failed to write to process stdin: #{e}")
        raise @exit_error
      end
    end

    def end_input
      return unless @stdin

      begin
        @stdin.close
      rescue StandardError
        # Ignore
      end
      @stdin = nil
    end

    def read_messages(&block)
      return enum_for(:read_messages) unless block_given?

      raise CLIConnectionError, 'Not connected' unless @process && @stdout

      json_buffer = ''

      begin
        @stdout.each_line do |line|
          line_str = line.strip
          next if line_str.empty?

          json_lines = line_str.split("\n")

          json_lines.each do |json_line|
            json_line = json_line.strip
            next if json_line.empty?

            json_buffer += json_line

            if json_buffer.bytesize > @max_buffer_size
              buffer_length = json_buffer.bytesize
              json_buffer = ''
              raise CLIJSONDecodeError.new(
                "JSON message exceeded maximum buffer size",
                StandardError.new("Buffer size #{buffer_length} exceeds limit #{@max_buffer_size}")
              )
            end

            begin
              data = JSON.parse(json_buffer, symbolize_names: true)
              json_buffer = ''
              yield data
            rescue JSON::ParserError
              # Continue accumulating
              next
            end
          end
        end
      rescue IOError
        # Stream closed
      rescue StopIteration
        # Client disconnected
      end

      # Check process completion
      status = @process.value
      returncode = status.exitstatus

      if returncode && returncode != 0
        @exit_error = ProcessError.new(
          "Command failed with exit code #{returncode}",
          exit_code: returncode,
          stderr: 'Check stderr output for details'
        )
        raise @exit_error
      end
    end

    def check_claude_version
      begin
        stdout, stderr, = Open3.capture3(@cli_path.to_s, '-v')
        output = (stdout.to_s + stderr.to_s).strip
        if match = output.match(/([0-9]+\.[0-9]+\.[0-9]+)/)
          version = match[1]
          version_parts = version.split('.').map(&:to_i)
          min_parts = MINIMUM_CLAUDE_CODE_VERSION.split('.').map(&:to_i)

          if version_parts < min_parts
            warning = "Warning: Claude Code version #{version} is unsupported in the Agent SDK. " \
                      "Minimum required version is #{MINIMUM_CLAUDE_CODE_VERSION}. " \
                      "Some features may not work correctly."
            warn warning
          end
        end
      rescue StandardError
        # Ignore version check errors
      end
    end

    def ready?
      @ready
    end
  end
end
