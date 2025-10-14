# frozen_string_literal: true

module ClaudeAgentSDK
  # Base exception for all Claude SDK errors
  class ClaudeSDKError < StandardError; end

  # Raised when unable to connect to Claude Code
  class CLIConnectionError < ClaudeSDKError; end

  # Raised when Claude Code is not found or not installed
  class CLINotFoundError < CLIConnectionError
    def initialize(message = 'Claude Code not found', cli_path: nil)
      message = "#{message}: #{cli_path}" if cli_path
      super(message)
    end
  end

  # Raised when the CLI process fails
  class ProcessError < ClaudeSDKError
    attr_reader :exit_code, :stderr

    def initialize(message, exit_code: nil, stderr: nil)
      @exit_code = exit_code
      @stderr = stderr

      message = "#{message} (exit code: #{exit_code})" if exit_code
      message = "#{message}\nError output: #{stderr}" if stderr

      super(message)
    end
  end

  # Raised when unable to decode JSON from CLI output
  class CLIJSONDecodeError < ClaudeSDKError
    attr_reader :line, :original_error

    def initialize(line, original_error)
      @line = line
      @original_error = original_error
      super("Failed to decode JSON: #{line[0...100]}...")
    end
  end

  # Raised when unable to parse a message from CLI output
  class MessageParseError < ClaudeSDKError
    attr_reader :data

    def initialize(message, data: nil)
      @data = data
      super(message)
    end
  end
end
