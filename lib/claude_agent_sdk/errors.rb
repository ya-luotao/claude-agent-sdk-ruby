# frozen_string_literal: true

module ClaudeAgentSDK
  # Base exception for all Claude SDK errors
  class ClaudeSDKError < StandardError; end

  # Raised when unable to connect to Claude Code
  class CLIConnectionError < ClaudeSDKError; end

  # Raised when the control protocol does not respond in time
  class ControlRequestTimeoutError < CLIConnectionError; end

  # Raised when Claude Code is not found or not installed
  class CLINotFoundError < CLIConnectionError
    def initialize(message = 'Claude Code not found', cli_path: nil)
      message = "#{message}: #{cli_path}" if cli_path
      super(message)
    end
  end

  # Raised when CLIInstaller cannot install the Claude Code CLI binary
  # (unsupported platform, invalid/unresolvable version, HTTP failure,
  # missing manifest entry, checksum mismatch).
  class CLIInstallError < ClaudeSDKError; end

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

  # Raised when the CLI exits after reporting a terminal error result.
  #
  # The CLI ends a failed run by emitting a +result+ message with
  # +is_error: true+ (yielded to you as a ResultMessage) and *then* exiting
  # non-zero, on purpose, for shell-script consumers. This exception replaces
  # the bare "exit code 1" ProcessError for that case and carries the
  # result's payload, so callers can branch on *why* the run failed without
  # string matching:
  #
  #   begin
  #     ClaudeAgentSDK.query(prompt: '...') { |message| ... }
  #   rescue ClaudeAgentSDK::ResultError => e
  #     if e.terminal_reason == 'api_error'   # e.g. overloaded / timeout
  #       retry_later
  #     elsif e.subtype == 'error_max_turns'
  #       ...
  #     end
  #   end
  #
  # It subclasses ProcessError, so existing +rescue ProcessError+ handlers
  # keep working.
  #
  # Every structured field is type-narrowed: a payload whose +subtype+ is not
  # a String (or whose +api_error_status+ is not an Integer, ...) reads back
  # as nil rather than leaking the raw value, so callers can branch on these
  # without re-validating. #data always holds the payload as the CLI sent it.
  class ResultError < ProcessError
    # The result subtype ("error_max_turns", "error_during_execution", ... —
    # or "success" when the agent loop itself completed but the last turn was
    # an API error).
    attr_reader :subtype

    # Error strings reported by the CLI (may be empty). Normalized the same
    # way the exception text is built, so the two never disagree.
    attr_reader :errors

    # The result text, if any. For API failures this holds the
    # "API Error: ..." prose.
    attr_reader :result

    # HTTP status of the failing API call, if any.
    attr_reader :api_error_status

    # Why the run ended (e.g. "api_error", "max_turns"), if reported.
    attr_reader :terminal_reason

    # Session the result belongs to, if reported.
    attr_reader :session_id

    # The raw +result+ message payload as emitted by the CLI.
    attr_reader :data

    # The ProcessError this replaced (the bare "exit code 1" exit).
    #
    # Ruby only populates #cause for an exception raised inside a rescue
    # block; the read loop hands this one to the message queue instead of
    # raising it there, so #cause is nil and the original exit error would be
    # lost without an explicit accessor. Mirrors Python's __cause__ chaining.
    attr_reader :original_error

    # Normalize the +errors+ field of a +result+ frame to clean strings.
    #
    # The CLI emits an Array of Strings; tolerate a bare String (older/buggy
    # emitters), treat anything else as empty, and drop non-String or blank
    # entries so the structured #errors and the exception text always agree.
    def self.normalize_errors(raw)
      raw = [raw] if raw.is_a?(String)
      return [] unless raw.is_a?(Array)

      raw.filter_map { |e| e.strip if e.is_a?(String) && !e.strip.empty? }
    end

    # Read a payload field, tolerating both key forms.
    #
    # Wire messages reach the SDK with symbolized keys, but a payload
    # reconstructed by a caller (or replayed from JSON.parse without
    # symbolize_names) uses Strings. Every field read goes through here so
    # the structured attributes and the exception text can never disagree
    # about which key form they saw.
    def self.field(data, key)
      return nil unless data.is_a?(Hash)

      data.key?(key) ? data[key] : data[key.to_s]
    end

    def initialize(message, data: nil, exit_code: nil, stderr: nil, original_error: nil)
      data = {} unless data.is_a?(Hash)
      @data = data
      @original_error = original_error

      subtype = self.class.field(data, :subtype)
      @subtype = subtype.is_a?(String) ? subtype : nil
      @errors = self.class.normalize_errors(self.class.field(data, :errors))
      result = self.class.field(data, :result)
      @result = result.is_a?(String) ? result : nil
      status = self.class.field(data, :api_error_status)
      @api_error_status = status.is_a?(Integer) ? status : nil
      reason = self.class.field(data, :terminal_reason)
      @terminal_reason = reason.is_a?(String) ? reason : nil
      session_id = self.class.field(data, :session_id)
      @session_id = session_id.is_a?(String) ? session_id : nil

      super(message, exit_code: exit_code, stderr: stderr)
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
