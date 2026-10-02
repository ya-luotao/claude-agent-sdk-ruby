# frozen_string_literal: true

require 'json'
require 'securerandom'

module ClaudeAgentSDKRailsSpec
  # A scripted stand-in for the CLI process, for ClaudeAgentSDK.query(transport:)
  # and Client (transport_class: / transport_args:). No subprocess, no model
  # call and no clock: it answers the initialize request, and every user
  # message the SDK writes plays the next turn of the script — frames in
  # order, stopping at each control request until the SDK has answered it,
  # so the script alone decides the order user callbacks run in.
  #
  # Like the process it replaces, it ends the stream once the script is
  # played and the SDK has closed stdin (#end_input), or on #close.
  class ScriptedCLITransport < ClaudeAgentSDK::Transport
    END_OF_STREAM = :end_of_stream

    # The hook callback ids the SDK registered in its initialize request, in
    # order, and its control responses by request id.
    attr_reader :hook_callback_ids, :control_responses

    # @param turns [Array<Array>] one script per user message. A step is a
    #   frame (Hash), a control request (Frames.control_request: the script
    #   waits for the SDK's answer before going on), or a callable that is
    #   given this transport and returns either.
    def initialize(_options = nil, turns:)
      super()
      @turns = turns.map(&:dup)
      @steps = []
      @stdout = Thread::Queue.new
      @lock = Mutex.new
      @hook_callback_ids = []
      @control_responses = {}
      @awaited_request_id = nil
      @input_ended = false
      @closed = false
    end

    def connect; end

    def ready?
      !@closed
    end

    def write(data)
      message = JSON.parse(data, symbolize_names: true)
      case message[:type]
      when 'control_request' then answer_control_request(message)
      when 'control_response' then record_control_response(message[:response])
      when 'user' then play_next_turn
      end
    end

    def read_messages
      loop do
        frame = @stdout.pop
        break if frame == END_OF_STREAM

        yield frame
      end
    end

    def end_input
      @lock.synchronize { @input_ended = true }
      end_stream_if_finished
    end

    def close
      @closed = true
      @stdout << END_OF_STREAM
    end

    private

    def answer_control_request(message)
      request = message[:request]
      if request[:subtype] == 'initialize'
        (request[:hooks] || {}).each_value do |matchers|
          matchers.each { |matcher| @hook_callback_ids.concat(matcher[:hookCallbackIds]) }
        end
      end
      @stdout << Frames.control_success(message[:request_id], request[:subtype])
    end

    def record_control_response(response)
      request_id = response[:request_id]
      resume = @lock.synchronize do
        @control_responses[request_id] = response
        next false unless @awaited_request_id == request_id

        @awaited_request_id = nil
        true
      end
      play if resume
    end

    def play_next_turn
      @lock.synchronize { @steps = @turns.shift || raise('the SDK sent more user messages than the script has turns') }
      play
    end

    # Emit steps until the script pauses on a control request or runs out.
    def play
      loop do
        step = @lock.synchronize { @steps.shift }
        return end_stream_if_finished if step.nil?

        step = step.call(self) if step.respond_to?(:call)
        @stdout << step
        next unless step[:type] == 'control_request'

        @lock.synchronize { @awaited_request_id = step[:request_id] }
        return
      end
    end

    def end_stream_if_finished
      finished = @lock.synchronize { @input_ended && @steps.empty? && @turns.empty? && @awaited_request_id.nil? }
      @stdout << END_OF_STREAM if finished
    end
  end

  # Frames as CLI 2.1.286 writes them to an SDK-spawned session, trimmed from
  # a recorded session to the fields the SDK reads (Symbol keys, as
  # SubprocessCLITransport#read_messages yields them). The mcp_message and
  # can_use_tool requests follow the SDK's own unit fixtures; the rest follow
  # the recording, including one content block per `assistant` frame and
  # the `session_state_changed` pair around every turn.
  module Frames
    SESSION_ID = 'fd9f2708-3a4e-460c-8bd7-561c3feb755e'
    MODEL = 'claude-haiku-4-5-20251001'
    TOOL_USE_ID = 'toolu_01CHuGKVaNkChVspFMWK3zcj'
    USAGE = { input_tokens: 8, cache_creation_input_tokens: 214, cache_read_input_tokens: 24_871,
              output_tokens: 2, service_tier: 'standard' }.freeze

    module_function

    # The CLI's answer to an SDK control request.
    def control_success(request_id, subtype)
      response = subtype == 'initialize' ? { commands: [], agents: [], output_style: 'default', models: [], pid: 11_687 } : {}
      { type: 'control_response', response: { subtype: 'success', request_id: request_id, response: response } }
    end

    # A control request from the CLI; the script waits for the SDK's answer.
    def control_request(request)
      { type: 'control_request', request_id: SecureRandom.uuid, request: request }
    end

    def session_state(state)
      { type: 'system', subtype: 'session_state_changed', state: state, sdk_host_only: true,
        uuid: SecureRandom.uuid, session_id: SESSION_ID }
    end

    def init
      { type: 'system', subtype: 'init', cwd: '/srv/app', session_id: SESSION_ID,
        tools: %w[Bash Read mcp__app__lookup], mcp_servers: [{ name: 'app', status: 'connected' }], model: MODEL,
        permissionMode: 'default', slash_commands: [], apiKeySource: 'none', claude_code_version: '2.1.286',
        output_style: 'default', agents: [], skills: [], plugins: [], uuid: SecureRandom.uuid }
    end

    def assistant(block, message_id:)
      { type: 'assistant',
        message: { model: MODEL, id: message_id, type: 'message', role: 'assistant', content: [block],
                   stop_reason: nil, stop_sequence: nil, usage: USAGE },
        parent_tool_use_id: nil, session_id: SESSION_ID, uuid: SecureRandom.uuid }
    end

    def assistant_text(text, message_id: 'msg_011Cfc2rFTtZTztTpTJF3xPG')
      assistant({ type: 'text', text: text }, message_id: message_id)
    end

    def assistant_tool_use(name:, input:, message_id: 'msg_011Cfc2qvqiaFFYGxduAzxDr')
      assistant({ type: 'tool_use', id: TOOL_USE_ID, name: name, input: input }, message_id: message_id)
    end

    def tool_result(content)
      { type: 'user',
        message: { role: 'user', content: [{ tool_use_id: TOOL_USE_ID, type: 'tool_result', content: content }] },
        parent_tool_use_id: nil, session_id: SESSION_ID, uuid: SecureRandom.uuid }
    end

    def result(text = 'DONE')
      { type: 'result', subtype: 'success', is_error: false, duration_ms: 6591, duration_api_ms: 5094,
        num_turns: 2, result: text, stop_reason: 'end_turn', session_id: SESSION_ID, total_cost_usd: 0.0161638,
        usage: USAGE, permission_denials: [], terminal_reason: 'completed', uuid: SecureRandom.uuid }
    end

    def hook_callback(callback_id, tool_name:, tool_input:)
      control_request(
        subtype: 'hook_callback', callback_id: callback_id, tool_use_id: TOOL_USE_ID,
        input: { session_id: SESSION_ID, transcript_path: "/srv/.claude/projects/-srv-app/#{SESSION_ID}.jsonl",
                 cwd: '/srv/app', permission_mode: 'default', hook_event_name: 'PreToolUse',
                 tool_name: tool_name, tool_input: tool_input, tool_use_id: TOOL_USE_ID }
      )
    end

    def can_use_tool(tool_name:, input:)
      control_request(subtype: 'can_use_tool', tool_name: tool_name, input: input, permission_suggestions: [],
                      tool_use_id: TOOL_USE_ID)
    end

    def mcp_tools_call(server:, tool:, arguments:)
      control_request(subtype: 'mcp_message', server_name: server,
                      message: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                                 params: { name: tool, arguments: arguments } })
    end

    # A turn that answers in text only.
    def text_turn(text = 'DONE')
      [session_state('running'), init, assistant_text(text), result(text), session_state('idle')]
    end

    # A turn in which the model calls the SDK MCP tool `lookup` on server
    # `app`. +ask+ lists the control requests the CLI sends on the way, in
    # its order: the PreToolUse :hook, the :permission prompt, the :tool call.
    def tool_turn(text = 'DONE', ask: %i[hook permission tool])
      tool_name = 'mcp__app__lookup'
      input = { id: 7 }
      requests = {
        hook: ->(cli) { hook_callback(cli.hook_callback_ids.first, tool_name: tool_name, tool_input: input) },
        permission: can_use_tool(tool_name: tool_name, input: input),
        tool: mcp_tools_call(server: 'app', tool: 'lookup', arguments: input)
      }
      [
        session_state('running'), init,
        assistant_tool_use(name: tool_name, input: input),
        *requests.values_at(*ask),
        tool_result('ok'),
        assistant_text(text), result(text), session_state('idle')
      ]
    end
  end
end
