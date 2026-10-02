# frozen_string_literal: true

require 'spec_helper'

# A hook, a can_use_tool callback or an SDK MCP tool / resource / prompt
# handler can fail with an exception that is neither a StandardError nor a
# process exit: NotImplementedError and LoadError (both ScriptError),
# SystemStackError, SecurityError. No `rescue StandardError` on the way out
# matched those, so the control request was never answered and its handler
# task ended with an exception Async treats as fatal — which stopped the
# reactor and every other task (and session) on it. They are answered like
# any other callback failure now, and the session carries on.
#
# Deliberately not contained, so not in the matrix: NoMemoryError, a bare
# Exception subclass, and what spec/unit/callback_process_exit_spec.rb covers
# (process exits are answered and then re-raised; cancellation propagates).
RSpec.describe 'user callbacks failing outside StandardError' do
  harness = CallbackExitHarness

  # The CLI side, scripted: hands the read loop one control request at a
  # time and lets the handler task it spawned run to its end before the
  # next, so the follow-up request reaches a read loop that has already
  # lived through the failure. Records every frame the SDK writes.
  let(:transport_class) do
    Class.new(ClaudeAgentSDK::Transport) do
      attr_reader :frames

      def initialize(requests)
        super()
        @requests = requests
        @frames = []
      end

      def write(data)
        @frames << JSON.parse(data)
      end

      def read_messages
        @requests.each do |request|
          yield request
          # Handler tasks are children of the task running the read loop.
          Async::Task.current.children&.each(&:wait)
        end
      end
    end
  end

  # A request no user callback takes part in.
  let(:follow_up_request) do
    { type: 'control_request', request_id: 'req_next', request: CallbackExitHarness.mcp_request('tools/list', {}) }
  end

  # One failing control request through Query#read_messages, as in a session,
  # then the follow-up; next to them an unrelated task on the same reactor,
  # parked until the session is done with both.
  def run_session(path, mode, kind, wrapper: nil)
    transport = transport_class.new([CallbackExitHarness.control_request(path), follow_up_request])
    query = CallbackExitHarness.build_query(path, mode, kind, transport, wrapper: wrapper)
    outcome = { frames: transport.frames, escaped: nil, bystander_finished: false }
    begin
      Sync do |task|
        gate = Thread::Queue.new
        bystander = task.async do
          gate.pop
          outcome[:bystander_finished] = true
        end
        task.async { query.send(:read_messages) }.wait
        gate << :session_done
        bystander.wait
      end
    rescue ScriptError, SystemStackError, SecurityError => e
      outcome[:escaped] = e # what stopped the reactor
    end
    outcome
  end

  def control_response(request_id, fields)
    { 'type' => 'control_response',
      'response' => { 'request_id' => request_id, 'requestId' => request_id }.merge(fields) }
  end

  # The response an ordinary exception from the callback produces on each
  # path (the shapes spec/unit/callback_process_exit_spec.rb pins too): an
  # error control response for hooks and can_use_tool; for SDK MCP requests,
  # inside a successful control response, an isError result (tools/call) or
  # a JSON-RPC internal error (resources/read, prompts/get).
  def failure_response(path, message)
    mcp_response =
      case path
      when :call_tool then { 'result' => { 'content' => [{ 'type' => 'text', 'text' => message }], 'isError' => true } }
      when :read_resource, :get_prompt then { 'error' => { 'code' => -32_603, 'message' => message } }
      else return control_response('req_fail', 'subtype' => 'error', 'error' => message)
      end
    control_response('req_fail', 'subtype' => 'success',
                                 'response' => { 'mcp_response' => { 'jsonrpc' => '2.0', 'id' => 7 }.merge(mcp_response) })
  end

  def responses_to(outcome, request_id)
    outcome[:frames].select { |frame| frame.dig('response', 'request_id') == request_id }
  end

  # The tool names in each answer to the follow-up request: one answer, and
  # a successful one, when the read loop outlived the failure.
  def tools_listed_afterwards(outcome)
    responses_to(outcome, 'req_next').map do |frame|
      frame.dig('response', 'response', 'mcp_response', 'result', 'tools')&.map { |tool| tool['name'] }
    end
  end

  def expect_answered_and_running(outcome, path, message)
    escaped = outcome[:escaped]
    aggregate_failures do
      expect(escaped).to be_nil, "the reactor was stopped by #{escaped.class}: #{escaped&.message}"
      expect(responses_to(outcome, 'req_fail')).to eq([failure_response(path, message)])
      expect(tools_listed_afterwards(outcome)).to eq([['boom']]), 'the session did not answer the next request'
      expect(outcome[:frames].length).to eq(2)
      expect(outcome[:bystander_finished]).to be(true), 'an unrelated task on the same reactor did not finish'
    end
  end

  harness::PATHS.each do |path|
    harness::MODES.each do |mode|
      context "#{path} with #{mode} callback scheduling" do
        harness::FAILURE_KINDS.each do |kind, (error_class, message)|
          it "answers a #{error_class} like any other callback failure and keeps the session running" do
            expect_answered_and_running(run_session(path, mode, kind), path, message)
          end
        end

        # The callback_wrapper runs around the callback, outside its body.
        it 'does the same when the callback_wrapper raises instead of the callback' do
          wrapper = ->(_invocation) { CallbackExitHarness.trigger(:not_implemented) }

          outcome = run_session(path, mode, :none, wrapper: wrapper)

          expect_answered_and_running(outcome, path, CallbackExitHarness::FAILURE_KINDS.fetch(:not_implemented).last)
        end

        it 'answers an ordinary StandardError the same way (the response the others must match)' do
          outcome = run_session(path, mode, :standard_error)

          expect_answered_and_running(outcome, path, CallbackExitHarness::ORDINARY_FAILURE)
        end
      end
    end
  end

  # Without a session there is no control request to answer; a tool
  # handler's failure is still the in-band result the model can read.
  describe 'SdkMcpServer tools called directly' do
    harness::MODES.each do |mode|
      harness::FAILURE_KINDS.each do |kind, (error_class, message)|
        it "reports a #{error_class} from a #{mode} handler as an isError result of #call_tool" do
          server = CallbackExitHarness.mcp_server(kind)
          server.callback_scheduling = mode

          result = Sync { server.call_tool('boom', {}) }

          expect(result).to eq(content: [{ type: 'text', text: message }], isError: true)
        end

        it "reports a #{error_class} from a #{mode} handler as an isError result of #handle_message" do
          server = CallbackExitHarness.mcp_server(kind)
          server.callback_scheduling = mode
          request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'boom', arguments: {} } }

          response = Sync { server.handle_message(request) }

          expect(response).to include(id: 1)
          expect(response[:result]).to include(content: [{ type: 'text', text: message }], isError: true)
        end
      end
    end
  end

  describe 'FiberBoundary::CALLBACK_FAILURES' do
    it 'covers what a failing callback raises' do
      contained = [RuntimeError, NotImplementedError, LoadError, SyntaxError, SystemStackError, SecurityError]

      expect(contained).to all(satisfy { |raised| ClaudeAgentSDK::FiberBoundary::CALLBACK_FAILURES.any? { |listed| raised <= listed } })
    end

    # `rescue Exception` in its place would swallow cancellation and process
    # exits; an answer built after NoMemoryError would likely fail again.
    it 'leaves out cancellation, process exits and NoMemoryError' do
      passed_on = [Async::Stop, ClaudeAgentSDK::FiberBoundary::InlineCancellation, SystemExit, Interrupt,
                   SignalException, NoMemoryError, Exception]

      expect(passed_on).to all(satisfy { |raised| ClaudeAgentSDK::FiberBoundary::CALLBACK_FAILURES.none? { |listed| raised <= listed } })
    end
  end
end
