# frozen_string_literal: true

require 'json'

# Issue #119 harness, run in a CHILD process (spec/unit/callback_process_exit_spec.rb):
# a user callback raises a process-termination exception (exit / Interrupt /
# SignalException), or the process receives a real SIGINT / SIGTERM while
# an inline callback runs. The SDK must answer the pending control request
# and then let the exception terminate the process as plain Ruby would.
# Every control response is printed (and flushed) the moment it is written,
# so the parent can check it went out BEFORE the process died. Plain Ruby
# with no RSpec dependency; it is loaded by spec_helper too, which only
# defines the module.
module CallbackExitHarness # rubocop:disable Metrics/ModuleLength -- one self-contained child-process fixture
  # Every control-request path whose user callback answers the CLI.
  # :hook_timeout takes the HookMatcher#timeout variants (Async with_timeout
  # around the thread hop in :thread mode, with_cooperative_timeout in
  # :inline); :call_tool is a routed tools/call through the mcp gem.
  PATHS = %i[hook hook_timeout can_use_tool read_resource get_prompt call_tool].freeze
  # SdkMcpServer's public entry points used without a Query: nothing to
  # answer, so the exception simply propagates.
  DIRECT_PATHS = %i[direct_call_tool direct_handle_message].freeze
  MODES = %i[thread inline].freeze

  # How each kind is raised, what the CLI is told, and how plain Ruby
  # terminates on it (an exit status, or the signal it re-raises itself).
  KINDS = {
    exit: { message: 'SystemExit: exit', exitstatus: 3 },
    interrupt: { message: 'Interrupt', termsig: 'INT' },
    signal: { message: 'SignalException: SIGTERM', termsig: 'TERM' },
    # Real OS signals, sent while an inline callback is busy:
    sigint: { message: 'Interrupt', termsig: 'INT' },
    sigterm: { message: 'SignalException: SIGTERM', termsig: 'TERM' }
  }.freeze

  RESPONSE = 'RESPONSE '
  SURVIVED = 'CALLBACK_EXIT_HARNESS_SURVIVED'

  class StdoutTransport < ClaudeAgentSDK::Transport
    def initialize(messages)
      super()
      @messages = messages
    end

    def write(data)
      $stdout.write("#{RESPONSE}#{data.chomp}\n")
      $stdout.flush
    end

    def read_messages(&block)
      @messages.each(&block)
    end
  end

  module_function

  # Called at the top of every failing callback.
  def trigger(kind)
    case kind
    when :exit then exit 3
    when :interrupt then raise Interrupt
    when :signal then raise SignalException, 'TERM'
    when :sigint, :sigterm then busy_until_signalled(kind == :sigint ? 'INT' : 'TERM')
    else raise ArgumentError, "unknown kind #{kind.inspect}"
    end
  end

  # CPU-bound (scheduler-opaque) work on the callback's own thread — for an
  # :inline callback the reactor's, i.e. the main thread — while another
  # thread sends the process a real signal, which MRI delivers to the main
  # thread. Returns normally if the signal never arrives.
  def busy_until_signalled(signal)
    Thread.new do
      sleep 0.1
      Process.kill(signal, Process.pid)
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    nil while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  end

  def build_query(path, mode, kind, transport)
    can_use_tool = lambda do |_tool_name, _input, _context|
      trigger(kind)
      ClaudeAgentSDK::PermissionResultAllow.new
    end
    hook = lambda do |*|
      if path == :hook_timeout_abandoned
        sleep 0.3 # outlives its 0.05s timeout; the request is answered first
        exit 3
      end
      trigger(kind)
      {}
    end
    ClaudeAgentSDK::Query.new(
      transport: transport, is_streaming_mode: true, can_use_tool: can_use_tool,
      sdk_mcp_servers: { 'srv' => mcp_server(kind) }, callback_scheduling: mode
    ).tap do |query|
      query.instance_variable_set(:@hook_callbacks, { 'hook' => hook })
      timeout = { hook_timeout: 5, hook_timeout_abandoned: 0.05 }[path]
      query.instance_variable_set(:@hook_callback_timeouts, { 'hook' => timeout }) if timeout
    end
  end

  def mcp_server(kind)
    tool = ClaudeAgentSDK.create_tool('boom', 'Boom', {}) do |_args|
      trigger(kind)
      { content: [{ type: 'text', text: 'fine' }] }
    end
    resource = ClaudeAgentSDK.create_resource(uri: 'res://boom', name: 'boom') do
      trigger(kind)
      { contents: [{ uri: 'res://boom', text: 'fine' }] }
    end
    prompt = ClaudeAgentSDK.create_prompt(name: 'boom') do |_args|
      trigger(kind)
      { messages: [{ role: 'user', content: { type: 'text', text: 'fine' } }] }
    end
    ClaudeAgentSDK.create_sdk_mcp_server(name: 'srv', tools: [tool], resources: [resource],
                                         prompts: [prompt])[:instance]
  end

  def control_request(path)
    request =
      case path
      when :hook, :hook_timeout, :hook_timeout_abandoned
        { subtype: 'hook_callback', callback_id: 'hook', tool_use_id: 'tool_1',
          input: { hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: {} } }
      when :can_use_tool
        { subtype: 'can_use_tool', tool_name: 'Bash', input: {} }
      when :read_resource then mcp_request('resources/read', uri: 'res://boom')
      when :get_prompt then mcp_request('prompts/get', name: 'boom')
      when :call_tool then mcp_request('tools/call', name: 'boom', arguments: {})
      end
    { type: 'control_request', request_id: 'req_fail', request: request }
  end

  def mcp_request(method, params)
    { subtype: 'mcp_message', server_name: 'srv',
      message: { jsonrpc: '2.0', id: 7, method: method, params: params } }
  end

  # Child-process entry point: `ruby -e 'CallbackExitHarness.main(ARGV)' PATH MODE KIND`.
  # Reaching SURVIVED means the exception was swallowed.
  def main(argv)
    path, mode, kind = argv.map(&:to_sym)
    if DIRECT_PATHS.include?(path)
      run_direct(path, mode, kind)
    else
      transport = StdoutTransport.new([control_request(path)])
      query = build_query(path, mode, kind, transport)
      # Through read_messages, as in a session: the request is handled in
      # its own child task.
      Sync do |task|
        query.send(:read_messages)
        task.children&.each(&:wait)
      end
      sleep 1 if path == :hook_timeout_abandoned # let the abandoned worker finish
    end
    $stdout.puts SURVIVED
    $stdout.flush
  end

  def run_direct(path, mode, kind)
    server = mcp_server(kind)
    server.callback_scheduling = mode
    Sync do
      if path == :direct_call_tool
        server.call_tool('boom', {})
      else
        server.handle_message({ jsonrpc: '2.0', id: 1, method: 'tools/call',
                                params: { name: 'boom', arguments: {} } })
      end
    end
  end
end
