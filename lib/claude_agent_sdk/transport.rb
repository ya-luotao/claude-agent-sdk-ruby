# frozen_string_literal: true

module ClaudeAgentSDK
  # Abstract transport for Claude communication
  #
  # WARNING: This internal API is exposed for custom transport implementations
  # (e.g., remote Claude Code connections). The Claude Code team may change or
  # remove this abstract class in any future release. Custom implementations
  # must be updated to match interface changes.
  class Transport
    # Connect the transport and prepare for communication
    def connect
      raise NotImplementedError, 'Subclasses must implement #connect'
    end

    # Write raw data to the transport
    # @param data [String] Raw string data to write (typically JSON + newline)
    def write(data)
      raise NotImplementedError, 'Subclasses must implement #write'
    end

    # Read and parse messages from the transport
    # @return [Enumerator] Async enumerator of parsed JSON messages
    def read_messages
      raise NotImplementedError, 'Subclasses must implement #read_messages'
    end

    # Close the transport connection and clean up resources
    def close
      raise NotImplementedError, 'Subclasses must implement #close'
    end

    # Check if transport is ready for communication
    # @return [Boolean] True if transport is ready to send/receive messages
    def ready?
      raise NotImplementedError, 'Subclasses must implement #ready?'
    end

    # End the input stream (close stdin for process transports)
    def end_input
      raise NotImplementedError, 'Subclasses must implement #end_input'
    end
  end
end
