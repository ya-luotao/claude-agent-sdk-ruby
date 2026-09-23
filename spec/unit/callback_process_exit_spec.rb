# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

# Runs every harness cell (spec/support/callback_exit_harness.rb) in its own
# child process, in parallel, once per rspec run. Anything that exits or
# signals must stay out of the rspec process: an escaped exit ends rspec
# with a green status for the examples run so far.
module CallbackExitChildren
  harness = CallbackExitHarness
  CELLS = [
    *harness::PATHS.product(harness::MODES, %i[exit interrupt signal]),
    *harness::DIRECT_PATHS.product(harness::MODES, %i[exit interrupt]),
    *harness::PATHS.product([:inline], %i[sigint sigterm]),
    %i[hook_timeout_abandoned thread exit]
  ].freeze

  def self.result(cell)
    results.fetch(cell)
  end

  def self.results
    @results ||= begin
      queue = Queue.new
      CELLS.each { |cell| queue << cell }
      queue.close
      found = {}
      lock = Mutex.new
      Array.new(8) do
        Thread.new do
          while (cell = queue.pop)
            outcome = run(cell)
            lock.synchronize { found[cell] = outcome }
          end
        end
      end.each(&:join)
      found
    end
  end

  def self.run(cell)
    lib_dir = File.expand_path('../../lib', __dir__)
    harness_file = File.expand_path('../support/callback_exit_harness.rb', __dir__)
    Open3.capture3(RbConfig.ruby, '-I', lib_dir, '-r', 'claude_agent_sdk', '-r', harness_file,
                   '-e', 'CallbackExitHarness.main(ARGV)', *cell.map(&:to_s))
  end
end

# Issue #119 (follow-up to #77 / PR #114). Policy: respond, then re-raise.
# SystemExit, Interrupt and other SignalExceptions raised while a user
# callback runs (hooks, can_use_tool, SDK MCP tool / resource / prompt
# handlers) are never swallowed. The CLI first gets the response an ordinary
# callback failure produces, then the exception terminates the process
# exactly as plain Ruby would. Before: no response and a stopped reactor,
# or (#114, and this PR's first revision) a response and a process that
# kept running, even through a real Ctrl-C landing in an :inline callback.
RSpec.describe 'process-termination exceptions raised by user callbacks' do
  harness = CallbackExitHarness

  def responses(out)
    prefix = CallbackExitHarness::RESPONSE
    out.lines.map(&:chomp).select { |line| line.start_with?(prefix) }.map { |line| JSON.parse(line.delete_prefix(prefix)) }
  end

  def expect_terminated_like_ruby(status, err, kind)
    expected = CallbackExitHarness::KINDS.fetch(kind)
    if expected[:exitstatus]
      expect(status.exitstatus).to eq(expected[:exitstatus]), "child: #{status.inspect}\n#{err}"
    else
      expect(status.termsig).to eq(Signal.list.fetch(expected[:termsig])), "child: #{status.inspect}\n#{err}"
    end
  end

  # The response an ordinary exception from the callback produces on each
  # path, carrying the exception class: an error control response for hooks
  # and can_use_tool; for SDK MCP requests, inside a successful control
  # response, an isError result (tools/call) or a JSON-RPC internal error.
  def expect_failure_response(path, response, message)
    body = response.fetch('response')
    expect(body['request_id']).to eq('req_fail')
    case path
    when :call_tool
      expect(body['subtype']).to eq('success')
      expect(body.dig('response', 'mcp_response')).to eq(
        'jsonrpc' => '2.0', 'id' => 7,
        'result' => { 'content' => [{ 'type' => 'text', 'text' => message }], 'isError' => true }
      )
    when :read_resource, :get_prompt
      expect(body['subtype']).to eq('success')
      expect(body.dig('response', 'mcp_response')).to eq(
        'jsonrpc' => '2.0', 'id' => 7, 'error' => { 'code' => -32_603, 'message' => message }
      )
    else
      expect(body).to include('subtype' => 'error', 'error' => message)
    end
  end

  def failure_response?(path, response)
    body = response.fetch('response')
    mcp = body.dig('response', 'mcp_response') || {}
    case path
    when :call_tool then mcp.dig('result', 'isError') == true
    when :read_resource, :get_prompt then mcp.key?('error')
    else body['subtype'] == 'error'
    end
  end

  harness::PATHS.each do |path|
    harness::MODES.each do |mode|
      context "#{path} with #{mode} callback scheduling" do
        %i[exit interrupt signal].each do |kind|
          it "answers the request, then terminates on #{kind} like plain Ruby" do
            out, err, status = CallbackExitChildren.result([path, mode, kind])

            expect(out).not_to include(CallbackExitHarness::SURVIVED)
            expect_terminated_like_ruby(status, err, kind)
            written = responses(out)
            expect(written.length).to eq(1), "expected exactly one response, got #{written.inspect}"
            expect_failure_response(path, written.first, CallbackExitHarness::KINDS.fetch(kind)[:message])
          end
        end
      end
    end

    # The #119 blocker: an :inline callback runs on the reactor fiber, i.e.
    # the main thread, where MRI delivers OS signals. A real Ctrl-C / SIGTERM
    # landing in CPU-bound callback code must still end the process.
    #
    # WHEN the signal interrupts is the async gem's business, not ours: newer
    # releases (2.46) defer SIGTERM until the running task yields, so the
    # callback completes and its normal answer goes out first; older ones
    # (2.36) interrupt the callback mid-flight, which then gets the error
    # answer. The invariant either way: exactly one answer, then the process
    # ends by that signal — never swallowed, never left running.
    %i[sigint sigterm].each do |kind|
      it "lets a real #{kind.upcase} delivered during an inline #{path} callback terminate the process" do
        out, err, status = CallbackExitChildren.result([path, :inline, kind])

        expect(out).not_to include(CallbackExitHarness::SURVIVED)
        expect_terminated_like_ruby(status, err, kind)
        written = responses(out)
        expect(written.length).to eq(1), "expected exactly one response, got #{written.inspect}"
        if failure_response?(path, written.first)
          expect_failure_response(path, written.first, CallbackExitHarness::KINDS.fetch(kind)[:message])
        else
          expect(written.first.dig('response', 'subtype')).to eq('success')
          expect(written.first.dig('response', 'request_id')).to eq('req_fail')
        end
      end
    end
  end

  # SdkMcpServer#call_tool / #handle_message without a Query: nothing to
  # answer, so the exception just propagates (under #114 it became an
  # isError result and the process kept running).
  harness::DIRECT_PATHS.each do |path|
    harness::MODES.each do |mode|
      %i[exit interrupt].each do |kind|
        it "propagates #{kind} from #{path} with #{mode} callback scheduling" do
          out, err, status = CallbackExitChildren.result([path, mode, kind])

          expect(out).not_to include(CallbackExitHarness::SURVIVED)
          expect_terminated_like_ruby(status, err, kind)
          expect(responses(out)).to be_empty
        end
      end
    end
  end

  # A :thread hook that outlives its HookMatcher timeout has already been
  # answered ("execution expired") when it calls exit; the exit must still
  # end the process rather than vanish with the abandoned worker thread.
  it 'lets exit from a timed-out, abandoned :thread hook end the process' do
    out, err, status = CallbackExitChildren.result(%i[hook_timeout_abandoned thread exit])

    expect(out).not_to include(CallbackExitHarness::SURVIVED)
    expect(status.exitstatus).to eq(3), "child: #{status.inspect}\n#{err}"
    written = responses(out)
    expect(written.length).to eq(1)
    expect(written.first.fetch('response')).to include('subtype' => 'error', 'error' => 'execution expired')
  end

  it 'names the exception class in the reported text' do
    message = ClaudeAgentSDK::FiberBoundary.method(:process_exit_message)

    expect(message.call(SystemExit.new(3, 'exit'))).to eq('SystemExit: exit')
    expect(message.call(SystemExit.new(3, 'bye'))).to eq('SystemExit: bye')
    expect(message.call(Interrupt.new)).to eq('Interrupt')
    expect(message.call(Interrupt.new(''))).to eq('Interrupt') # a real Ctrl-C
    expect(message.call(SignalException.new('TERM'))).to eq('SignalException: SIGTERM')
  end

  # In-process from here on: :inline and Interrupt only (no worker thread,
  # so nothing can be re-raised on the main thread behind rspec's back), and
  # every dispatch wrapped in `rescue Exception` — RSpec does not rescue
  # Interrupt, so a leak must become an expectation, not abort the run.
  context 'with a callback_wrapper (inline, in-process)' do
    def dispatch_hook(wrapper)
      transport = CallbackExitHarness::StdoutTransport.new([])
      writes = []
      allow(transport).to receive(:write) { |data| writes << JSON.parse(data) }
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                        callback_scheduling: :inline, callback_wrapper: wrapper)
      query.instance_variable_set(:@hook_callbacks, { 'hook' => ->(*) { raise Interrupt } })
      raised = begin
        Sync { query.send(:handle_control_request, CallbackExitHarness.control_request(:hook)) }
        nil
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end
      [raised, writes]
    end

    it 'shows the wrapper a StandardError carrier whose cause is the original' do
      seen = []
      wrapper = lambda do |invocation|
        invocation.call
      rescue Exception => e # rubocop:disable Lint/RescueException
        seen << e
        raise
      end

      raised, writes = dispatch_hook(wrapper)

      expect(seen.length).to eq(1)
      expect(seen.first).to be_a(StandardError)
      expect(seen.first.cause).to be_a(Interrupt)
      expect(raised).to be_a(Interrupt)
      expect(raised).to be(seen.first.cause)
      expect(writes.map { |w| w['response']['error'] }).to eq(['Interrupt'])
    end

    it 'still re-raises when the wrapper swallows the carrier' do
      swallowing = lambda do |invocation|
        invocation.call
      rescue StandardError
        nil
      end

      raised, writes = dispatch_hook(swallowing)

      expect(raised).to be_a(Interrupt)
      expect(writes.map { |w| w['response']['error'] }).to eq(['Interrupt'])
    end
  end

  # Cancellation is not a process exit: it must still reach the dispatcher,
  # which answers with 'Cancelled' (or the timeout error) exactly as before.
  context 'with cancellation raised inside an inline callback' do
    def recording_query(**options)
      writes = []
      transport = CallbackExitHarness::StdoutTransport.new([])
      allow(transport).to receive(:write) { |data| writes << JSON.parse(data) }
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                        callback_scheduling: :inline, **options)
      [query, writes]
    end

    %i[hook can_use_tool].each do |path|
      [Async::Stop, ClaudeAgentSDK::FiberBoundary::InlineCancellation].each do |cancellation|
        it "lets #{cancellation} from #{path} propagate out of the handler" do
          callback = ->(*) { raise cancellation }
          query, = recording_query(can_use_tool: callback)
          query.instance_variable_set(:@hook_callbacks, { 'hook' => callback })
          handler = path == :hook ? :handle_hook_callback : :handle_permission_request
          request = CallbackExitHarness.control_request(path)[:request]

          # Rescued inside the task: an Async::Stop escaping Sync's own task
          # would just stop it silently, proving nothing.
          outcome = Sync do
            query.send(handler, request, request_id: 'req_fail')
          rescue cancellation => e
            e
          end

          expect(outcome).to be_a(cancellation)
        end
      end

      it "answers a stopped inline #{path} with the Cancelled error" do
        entered = Thread::Queue.new
        callback = lambda do |*|
          entered << true
          sleep # parks the reactor fiber until task.stop cancels it
        end
        query, writes = recording_query(can_use_tool: callback)
        query.instance_variable_set(:@hook_callbacks, { 'hook' => callback })
        request = CallbackExitHarness.control_request(path)

        Sync do |task|
          handler_task = task.async { query.send(:handle_control_request, request) }
          entered.pop
          handler_task.stop
          handler_task.wait
        end

        expect(writes.length).to eq(1)
        expect(writes.first.fetch('response')).to include('subtype' => 'error', 'error' => 'Cancelled')
      end
    end

    it 'still times out an inline hook that exceeds its HookMatcher timeout' do
      query, writes = recording_query
      query.instance_variable_set(:@hook_callbacks, { 'hook' => ->(*) { sleep } })
      query.instance_variable_set(:@hook_callback_timeouts, { 'hook' => 0.05 })

      Sync { query.send(:handle_control_request, CallbackExitHarness.control_request(:hook)) }

      expect(writes.length).to eq(1)
      expect(writes.first.fetch('response')).to include('subtype' => 'error', 'error' => 'execution expired')
    end
  end
end
