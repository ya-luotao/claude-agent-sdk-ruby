# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

# Issue #119 (follow-up to #77 / PR #114): SystemExit, Interrupt and other
# SignalExceptions raised by hooks, can_use_tool, and SDK MCP resource /
# prompt handlers escaped every dispatch boundary — no control response was
# written, the reactor stopped, and in :thread scheduling `exit` was
# re-raised by Ruby on the MAIN thread and ended the process. They are now
# ordinary callback failures: exactly one error response for the request,
# and the session keeps serving later requests. Cancellation still
# propagates. Fixtures live in spec/support/callback_exit_harness.rb.
RSpec.describe 'process-exit exceptions raised by user callbacks' do
  harness = CallbackExitHarness

  # The control response a failed callback produces on each path: hooks and
  # can_use_tool fail the control request itself (what any StandardError
  # from the callback produces); resources/read and prompts/get answer with
  # a JSON-RPC internal error inside a successful control response.
  def expect_failed_response(path, response, message)
    body = response.fetch('response')
    expect(body['request_id']).to eq('req_fail')
    if %i[read_resource get_prompt].include?(path)
      expect(body['subtype']).to eq('success')
      expect(body.dig('response', 'mcp_response', 'error')).to eq('code' => -32_603, 'message' => message)
    else
      expect(body).to include('subtype' => 'error', 'error' => message)
    end
  end

  def expect_ok_response(path, response)
    body = response.fetch('response')
    expect(body).to include('subtype' => 'success', 'request_id' => 'req_ok')
    expect(body.dig('response', 'mcp_response', 'error')).to be_nil if %i[read_resource get_prompt].include?(path)
  end

  def expect_contained(path, writes, kind)
    expect(writes.length).to eq(2), "expected one response per request, got #{writes.inspect}"
    expect_failed_response(path, writes[0], CallbackExitHarness::MESSAGES.fetch(kind))
    expect_ok_response(path, writes[1])
  end

  # `exit` runs in a child process: under a regression Ruby re-raises the
  # worker's SystemExit on the main thread (:thread) or it escapes the
  # reactor (:inline), which would end the rspec process — with a green
  # status for the examples run so far. The child calls `exit 3`, so a leak
  # shows up as a nonzero status and a missing survival marker.
  def run_child(path, mode)
    lib_dir = File.expand_path('../../lib', __dir__)
    harness_file = File.expand_path('../support/callback_exit_harness.rb', __dir__)
    Open3.capture3(RbConfig.ruby, '-I', lib_dir, '-r', 'claude_agent_sdk', '-r', harness_file,
                   '-e', 'CallbackExitHarness.main(ARGV)', path.to_s, mode.to_s, 'exit')
  end

  harness::PATHS.each do |path|
    harness::MODES.each do |mode|
      context "#{path} with #{mode} callback scheduling" do
        it 'reports exit as a failed callback and the process keeps running' do
          out, err, status = run_child(path, mode)
          lines = out.lines.map(&:chomp)

          expect(status.exitstatus).to eq(0), "child exited #{status.exitstatus}: #{err}"
          expect(lines.last).to eq(CallbackExitHarness::SURVIVED)
          expect_contained(path, JSON.parse(lines.first), :exit)
        end

        %i[interrupt signal].each do |kind|
          it "reports #{kind == :signal ? 'SignalException' : 'Interrupt'} as a failed callback" do
            # RSpec does not rescue Interrupt / SignalException in an
            # example — a leak would abort the whole run — so turn one into
            # an ordinary expectation failure here.
            leaked = nil
            writes = begin
              harness.run(path, mode, kind)
            rescue Exception => e # rubocop:disable Lint/RescueException
              leaked = e
            end

            expect(leaked).to be_nil, "#{leaked.inspect} escaped dispatch"
            expect_contained(path, writes, kind)
          end
        end
      end
    end
  end

  it 'keeps the original exception as the cause of the reported error' do
    # SystemExit.new rather than a real `exit`, and rescue Exception: a
    # regression must fail this example, not end the rspec process.
    error = begin
      ClaudeAgentSDK::FiberBoundary.contain_process_exit { raise SystemExit.new(4, 'bye') }
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end

    expect(error).to be_a(RuntimeError)
    expect(error.message).to eq('SystemExit: bye')
    expect(error.cause).to be_a(SystemExit)
    expect(error.cause.status).to eq(4)
  end

  it 'shows a callback_wrapper the reported RuntimeError, not the original exception' do
    seen = Queue.new
    wrapper = lambda do |invocation|
      invocation.call
    rescue Exception => e # rubocop:disable Lint/RescueException
      seen << e.class
      raise
    end
    transport = CallbackExitHarness::RecordingTransport.new
    query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                      callback_scheduling: :inline, callback_wrapper: wrapper)
    query.instance_variable_set(:@hook_callbacks, { 'hook_fail' => ->(*) { raise Interrupt } })

    leaked = begin
      Sync { query.send(:handle_control_request, CallbackExitHarness.control_request(:hook, 'req_fail', fail: true)) }
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end

    expect(leaked).to be_nil, "#{leaked.inspect} escaped dispatch"
    expect(seen.pop).to eq(RuntimeError)
    expect(transport.writes.length).to eq(1)
    expect(transport.writes.first.dig('response', 'error')).to eq('Interrupt: Interrupt')
  end

  # Cancellation is not a process exit: it must still reach the dispatcher,
  # which answers with the 'Cancelled' error (or the timeout error) exactly
  # as before #119.
  context 'with cancellation raised inside an inline callback' do
    def recording_query(**options)
      transport = CallbackExitHarness::RecordingTransport.new
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                        callback_scheduling: :inline, **options)
      [query, transport]
    end

    %i[hook can_use_tool].each do |path|
      [Async::Stop, ClaudeAgentSDK::FiberBoundary::InlineCancellation].each do |cancellation|
        it "lets #{cancellation} from #{path} propagate out of the handler" do
          callback = ->(*) { raise cancellation }
          query, = recording_query(can_use_tool: callback)
          query.instance_variable_set(:@hook_callbacks, { 'hook_fail' => callback })
          handler = path == :hook ? :handle_hook_callback : :handle_permission_request
          request = CallbackExitHarness.control_request(path, 'req_fail', fail: true)[:request]

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
        query, transport = recording_query(can_use_tool: callback)
        query.instance_variable_set(:@hook_callbacks, { 'hook_fail' => callback })
        request = CallbackExitHarness.control_request(path, 'req_fail', fail: true)

        Sync do |task|
          handler_task = task.async { query.send(:handle_control_request, request) }
          entered.pop
          handler_task.stop
          handler_task.wait
        end

        expect(transport.writes.length).to eq(1)
        expect(transport.writes.first.fetch('response')).to include('subtype' => 'error', 'error' => 'Cancelled')
      end
    end

    it 'still times out an inline hook that exceeds its HookMatcher timeout' do
      query, transport = recording_query
      query.instance_variable_set(:@hook_callbacks, { 'hook_fail' => ->(*) { sleep } })
      query.instance_variable_set(:@hook_callback_timeouts, { 'hook_fail' => 0.05 })

      Sync do
        query.send(:handle_control_request, CallbackExitHarness.control_request(:hook, 'req_fail', fail: true))
      end

      expect(transport.writes.length).to eq(1)
      expect(transport.writes.first.fetch('response')).to include('subtype' => 'error', 'error' => 'execution expired')
    end
  end
end
