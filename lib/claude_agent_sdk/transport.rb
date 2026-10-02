# frozen_string_literal: true

module ClaudeAgentSDK
  # Abstract base class for transports: the channel between the SDK and a
  # Claude Code CLI process.
  #
  # Public API, covered by this gem's SemVer promise like the rest of the
  # documented surface. {SubprocessCLITransport}, the default, spawns the CLI
  # locally. To run the CLI somewhere else (a container, an SSH host, a
  # sandbox VM), subclass this class, or write any object with the same
  # methods, and pass it to {Client#initialize} as `transport_class:` or to
  # {ClaudeAgentSDK.query} / {ClaudeAgentSDK.ask} as `transport:`. See
  # docs/client.md, "Custom Transport".
  #
  # The SDK calls five methods: {#connect}, {#write}, {#read_messages},
  # {#end_input} and {#close}. It never calls {#ready?}, so that one is
  # optional. Every method here raises NotImplementedError until a subclass
  # overrides it.
  class Transport
    # Establish the connection (spawn or reach the CLI) and prepare for IO.
    def connect
      raise NotImplementedError, 'Subclasses must implement #connect'
    end

    # Write raw data to the CLI's stdin.
    # @param data [String] Raw string data to write (typically JSON + newline)
    def write(data)
      raise NotImplementedError, 'Subclasses must implement #write'
    end

    # Read the CLI's stdout and yield each line as a parsed message, blocking
    # until the stream ends. Parse each line with
    # `JSON.parse(line, symbolize_names: true)`: the SDK reads Symbol keys.
    # The SDK always passes a block.
    # @yield [Hash{Symbol => Object}] Each parsed message
    def read_messages
      raise NotImplementedError, 'Subclasses must implement #read_messages'
    end

    # Terminate the CLI and clean up resources. Must be idempotent: the SDK
    # can call it more than once, and calls it after a failed {#connect} too.
    def close
      raise NotImplementedError, 'Subclasses must implement #close'
    end

    # Check if transport is ready for communication. Optional: the SDK never
    # calls it.
    # @return [Boolean] True if transport is ready to send/receive messages
    def ready?
      raise NotImplementedError, 'Subclasses must implement #ready?'
    end

    # End the input stream (close stdin for process transports). The SDK
    # calls it when a one-shot query's run is over and when a streamed prompt
    # is exhausted.
    def end_input
      raise NotImplementedError, 'Subclasses must implement #end_input'
    end
  end
end
