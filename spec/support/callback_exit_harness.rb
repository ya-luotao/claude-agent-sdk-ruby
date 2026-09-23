# frozen_string_literal: true

require 'json'

# Issue #119 harness: drives one control request whose user callback raises
# a process-exit exception (exit / Interrupt / SignalException), then one
# ordinary request on the same Query inside the same reactor, and returns
# every control response written. Plain Ruby with no RSpec dependency, so
# the `exit` cases can run it in a child process
# (spec/unit/callback_process_exit_spec.rb): in :thread scheduling Ruby
# re-raises a worker thread's SystemExit on the MAIN thread, which would
# end the rspec process itself if the conversion regressed.
module CallbackExitHarness
  # Every user-callback dispatch site covered by #119. :hook_timeout takes
  # the HookMatcher#timeout variants — Async with_timeout around the thread
  # hop in :thread mode, the cooperative with_cooperative_timeout in :inline.
  PATHS = %i[hook hook_timeout can_use_tool read_resource get_prompt].freeze
  MODES = %i[thread inline].freeze

  # The error text each exception kind is reported with.
  MESSAGES = {
    exit: 'SystemExit: exit',
    interrupt: 'Interrupt: Interrupt',
    signal: 'SignalException: SIGTERM'
  }.freeze

  class RecordingTransport < ClaudeAgentSDK::Transport
    attr_reader :writes

    def initialize
      super
      @writes = []
    end

    def write(data)
      @writes << JSON.parse(data)
    end
  end

  module_function

  def raise_exit(kind)
    case kind
    when :exit then exit 3 # nonzero: a leak must not look like a clean run
    when :interrupt then raise Interrupt
    when :signal then raise SignalException, 'TERM'
    else raise ArgumentError, "unknown kind #{kind.inspect}"
    end
  end

  # Returns the parsed control responses: the failing request's first, then
  # the follow-up ordinary request's (proof the reactor survived).
  def run(path, mode, kind)
    transport = RecordingTransport.new
    query = build_query(path, mode, kind, transport)
    Sync do
      query.send(:handle_control_request, control_request(path, 'req_fail', fail: true))
      query.send(:handle_control_request, control_request(path, 'req_ok', fail: false))
    end
    transport.writes
  end

  def build_query(path, mode, kind, transport)
    can_use_tool = lambda do |tool_name, _input, _context|
      raise_exit(kind) if tool_name == 'Boom'
      ClaudeAgentSDK::PermissionResultAllow.new
    end
    ClaudeAgentSDK::Query.new(
      transport: transport, is_streaming_mode: true, can_use_tool: can_use_tool,
      sdk_mcp_servers: { 'srv' => mcp_server(kind) }, callback_scheduling: mode
    ).tap do |query|
      hooks = { 'hook_fail' => ->(*) { raise_exit(kind) }, 'hook_ok' => ->(*) { {} } }
      query.instance_variable_set(:@hook_callbacks, hooks)
      query.instance_variable_set(:@hook_callback_timeouts, { 'hook_fail' => 5, 'hook_ok' => 5 }) if path == :hook_timeout
    end
  end

  def mcp_server(kind)
    resources = %w[fail ok].map do |outcome|
      ClaudeAgentSDK.create_resource(uri: "res://#{outcome}", name: outcome) do
        raise_exit(kind) if outcome == 'fail'
        { contents: [{ uri: 'res://ok', text: 'fine' }] }
      end
    end
    prompts = %w[fail ok].map do |outcome|
      ClaudeAgentSDK.create_prompt(name: outcome) do |_args|
        raise_exit(kind) if outcome == 'fail'
        { messages: [{ role: 'user', content: { type: 'text', text: 'fine' } }] }
      end
    end
    ClaudeAgentSDK.create_sdk_mcp_server(name: 'srv', resources: resources, prompts: prompts)[:instance]
  end

  def control_request(path, request_id, fail:)
    outcome = fail ? 'fail' : 'ok'
    request =
      case path
      when :hook, :hook_timeout
        { subtype: 'hook_callback', callback_id: "hook_#{outcome}", tool_use_id: 'tool_1',
          input: { hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: {} } }
      when :can_use_tool
        { subtype: 'can_use_tool', tool_name: fail ? 'Boom' : 'Read', input: {} }
      when :read_resource
        mcp_request('resources/read', uri: "res://#{outcome}")
      when :get_prompt
        mcp_request('prompts/get', name: outcome)
      end
    { type: 'control_request', request_id: request_id, request: request }
  end

  def mcp_request(method, params)
    { subtype: 'mcp_message', server_name: 'srv',
      message: { jsonrpc: '2.0', id: 1, method: method, params: params } }
  end

  # Child-process entry point: run one cell, print the responses as JSON,
  # then a marker. Reaching the marker (and exiting 0) proves the exception
  # neither escaped dispatch nor was re-raised on the main thread.
  SURVIVED = 'CALLBACK_EXIT_HARNESS_SURVIVED'

  def main(argv)
    path, mode, kind = argv.map(&:to_sym)
    $stdout.puts JSON.generate(run(path, mode, kind))
    $stdout.puts SURVIVED
    $stdout.flush
  end
end
