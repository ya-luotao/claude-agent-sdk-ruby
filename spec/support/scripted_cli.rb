# frozen_string_literal: true

require 'json'
require 'securerandom'

# The CLI's end of the control protocol, in process. A spec opens a real
# Client on it, sends the control requests the CLI would send (hook_callback,
# can_use_tool, mcp_message) and gets back the frame the SDK wrote in reply:
#
#   ScriptedCLI.session(options) do |cli|
#     reply = cli.request(subtype: 'can_use_tool', tool_name: 'Bash', input: { command: 'ls' })
#     reply # => { 'subtype' => 'success', 'request_id' => '…', 'response' => { 'behavior' => 'allow', … } }
#   end
#
# Nothing on the SDK side is stubbed or called privately: Client#connect
# builds the Query from the options a user writes, `initialize` is answered
# the way the CLI answers it, and each request goes through Query's read
# loop, its handler task and the hop to the user's callback. Frames cross in
# both directions as they cross SubprocessCLITransport: serialized to JSON
# and parsed back (Symbol keys towards the SDK, String keys on this side).
#
# This is the control channel only. For a child process that also speaks the
# message stream, see FakeClaude (spec/support/fake_claude.rb).
class ScriptedCLI
  # How long #request waits for the SDK's answer. Only a regression that
  # leaves a request unanswered ever waits this long.
  REPLY_BOUND_SECONDS = 10

  # What CLI 2.1.286 answers `initialize` with when it has no credentials,
  # cut down to one entry per list.
  INITIALIZE_RESPONSE = {
    commands: [{ name: 'design', description: 'Grant or revoke Claude agent access to your Design projects',
                 argumentHint: 'consent | revoke', builtin: true }],
    agents: [{ name: 'claude', description: "Catch-all for any task that doesn't fit a more specific agent." }],
    output_style: 'default',
    available_output_styles: %w[default Proactive Concise Explanatory Learning],
    models: [{ value: 'default', resolvedModel: 'claude-opus-5-5', displayName: 'Default (recommended)',
               description: 'Use the default model', supportsEffort: true,
               supportedEffortLevels: %w[low medium high xhigh max], supportsAdaptiveThinking: true,
               supportsFastMode: true, supportsAutoMode: true }],
    account: { tokenSource: 'none', apiProvider: 'firstParty' },
    pid: 4242,
    current_permission_mode: 'auto',
    session_state: 'idle'
  }.freeze

  # Opens a Client on a new ScriptedCLI, yields the ScriptedCLI (and the
  # Client), disconnects. Returns the block's value.
  def self.session(options = ClaudeAgentSDK::ClaudeAgentOptions.new)
    cli = new
    ClaudeAgentSDK::Client.open(options: options, transport_class: Transport, transport_args: { cli: cli }) do |client|
      yield cli, client
    end
  end

  # Every frame the SDK wrote, in order, as the CLI parses them (String keys).
  attr_reader :received

  def initialize
    @to_sdk = Thread::Queue.new
    @replies = Thread::Queue.new
    @received = []
  end

  # Sends one control request and returns the body of the SDK's
  # control_response: 'subtype', 'request_id' and 'response' (or 'error').
  def request(request, request_id: SecureRandom.uuid)
    deliver(type: 'control_request', request_id: request_id, request: request)
    reply = @replies.pop(timeout: REPLY_BOUND_SECONDS)
    raise "the SDK did not answer the #{request[:subtype]} request within #{REPLY_BOUND_SECONDS}s" unless reply

    reply.fetch('response')
  end

  # The `initialize` control request the SDK sent on connect.
  def initialize_request
    @received.find { |frame| frame.dig('request', 'subtype') == 'initialize' }
  end

  # The callback ids the SDK registered for +event+ in `initialize`, which
  # is how the CLI learns what to put in a hook_callback request.
  def hook_callback_ids(event)
    Array(initialize_request.dig('request', 'hooks', event)).flat_map { |matcher| matcher.fetch('hookCallbackIds') }
  end

  # The three methods below are the transport's side.

  def next_frame
    @to_sdk.pop
  end

  def hang_up
    @to_sdk.push(:eof)
  end

  def take(data)
    data.each_line do |line|
      frame = JSON.parse(line)
      @received << frame
      case frame['type']
      when 'control_response' then @replies.push(frame)
      when 'control_request' then answer(frame)
      end
    end
  end

  private

  def deliver(frame)
    @to_sdk.push(JSON.parse(JSON.generate(frame), symbolize_names: true))
  end

  def answer(frame)
    payload = frame.dig('request', 'subtype') == 'initialize' ? INITIALIZE_RESPONSE : {}
    deliver(type: 'control_response',
            response: { subtype: 'success', request_id: frame.fetch('request_id'), response: payload })
  end

  # What Client instantiates: `transport_class.new(options, **transport_args)`.
  class Transport < ClaudeAgentSDK::Transport
    def initialize(_options, cli:)
      super()
      @cli = cli
      @ready = false
    end

    def connect
      @ready = true
    end

    def ready?
      @ready
    end

    def write(data)
      @cli.take(data)
    end

    def read_messages
      loop do
        frame = @cli.next_frame
        break if frame == :eof

        yield frame
      end
    end

    def end_input; end

    def close
      @ready = false
      @cli.hang_up
    end
  end
end
