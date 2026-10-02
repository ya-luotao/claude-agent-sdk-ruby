# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'json'

# ClaudeAgentOptions#hooks is keyed by event name, written as a String or as
# a Symbol. When one event appeared under both key types (two parts of an
# app each adding their own guard, say) the second list silently replaced the
# first, so one of the hooks was never registered and never ran.
#
# End to end through the real control protocol: a fake Transport answers the
# initialize request the way the CLI does, delivers the frames an example
# hands it, and reports every frame the SDK writes.
RSpec.describe 'hooks registered under a String and a Symbol key for one event' do
  let(:transport_class) do
    Class.new(ClaudeAgentSDK::Transport) do
      def initialize(_options, inbound:, written:)
        super()
        @inbound = inbound
        @written = written
      end

      def connect = @ready = true
      def ready? = @ready
      def end_input; end
      def close = @inbound.push(:eof)

      def write(data)
        frame = JSON.parse(data, symbolize_names: true)
        if frame.dig(:request, :subtype) == 'initialize'
          response = { subtype: 'success', request_id: frame[:request_id], response: {} }
          @inbound.push({ type: 'control_response', response: response })
        end
        @written.push(frame)
      end

      def read_messages
        loop do
          message = @inbound.pop
          break if message == :eof

          yield message
        end
      end
    end
  end

  let(:inbound) { Thread::Queue.new }
  let(:written) { Thread::Queue.new }
  let(:called) { [] }

  # A matcher whose one hook records that it ran.
  def matcher(name, tool, **)
    hook = lambda do |_input, _tool_use_id, _context|
      called << name
      {}
    end
    ClaudeAgentSDK::HookMatcher.new(matcher: tool, hooks: [hook], **)
  end

  # Connects a session with these hooks and runs the block inside it.
  def session(hooks)
    Sync do
      client = ClaudeAgentSDK::Client.new(
        options: ClaudeAgentSDK::ClaudeAgentOptions.new(hooks: hooks),
        transport_class: transport_class, transport_args: { inbound: inbound, written: written }
      )
      client.connect
      yield
    ensure
      client&.disconnect
    end
  end

  # The next frame the SDK wrote (nil if none arrives: a bounded wait, so a
  # regression fails the example instead of hanging the suite).
  def next_written
    written.pop(timeout: 5)
  end

  # The hooks object of the initialize request.
  def registered_hooks
    next_written.dig(:request, :hooks)
  end

  # The hook_callback request CLI 2.1.286 writes for a PreToolUse hook
  # (recorded; only the home directory is shortened), for one callback id.
  def hook_callback(callback_id)
    request = JSON.parse(<<~FRAME, symbolize_names: true)
      {"type":"control_request","request_id":"a0ae4d7c-684f-4cd2-a36a-e5e7f1e7e928","request":{"subtype":"hook_callback","callback_id":"hook_0","input":{"session_id":"097e32d1-723a-42b4-a59b-f816b0d9ac84","transcript_path":"/home/dev/.claude/projects/-work-app/097e32d1-723a-42b4-a59b-f816b0d9ac84.jsonl","cwd":"/work/app","scratchpad_dir":"/private/tmp/claude-501/-work-app/097e32d1-723a-42b4-a59b-f816b0d9ac84/scratchpad","prompt_id":"efe95091-ba7c-4f07-8d76-e376ef8f0c92","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Remove the build directory"},"tool_use_id":"toolu_01PsVteovwuBVRcCCBHw4EC7"},"tool_use_id":"toolu_01PsVteovwuBVRcCCBHw4EC7"}}
    FRAME
    request[:request_id] = "request-for-#{callback_id}"
    request[:request][:callback_id] = callback_id
    request
  end

  it 'registers the matchers of both keys, in the order they were written' do
    hooks = { 'PreToolUse' => [matcher('bash_guard', 'Bash')], PreToolUse: [matcher('write_guard', 'Write|Edit')] }

    session(hooks) do
      expect(registered_hooks).to eq(
        PreToolUse: [
          { matcher: 'Bash', hookCallbackIds: ['hook_0'] },
          { matcher: 'Write|Edit', hookCallbackIds: ['hook_1'] }
        ]
      )
    end
  end

  it 'runs the hooks of both keys' do
    hooks = { PreToolUse: [matcher('write_guard', 'Write|Edit')], 'PreToolUse' => [matcher('bash_guard', 'Bash')] }

    replies = session(hooks) do
      next_written # the initialize request
      %w[hook_0 hook_1].map do |callback_id|
        inbound.push(hook_callback(callback_id))
        next_written
      end
    end

    expect(called).to eq(%w[write_guard bash_guard])
    expect(replies.map { |reply| reply[:response].slice(:subtype, :request_id) }).to eq(
      [{ subtype: 'success', request_id: 'request-for-hook_0' },
       { subtype: 'success', request_id: 'request-for-hook_1' }]
    )
  end

  it 'keeps each matcher its own timeout and leaves other events alone' do
    hooks = {
      'PreToolUse' => [matcher('bash_guard', 'Bash', timeout: 30)],
      'PostToolUse' => [matcher('audit', nil)],
      PreToolUse: [matcher('write_guard', 'Write|Edit')]
    }

    session(hooks) do
      expect(registered_hooks).to eq(
        PreToolUse: [
          { matcher: 'Bash', hookCallbackIds: ['hook_0'], timeout: 30 },
          { matcher: 'Write|Edit', hookCallbackIds: ['hook_1'] }
        ],
        PostToolUse: [{ matcher: nil, hookCallbackIds: ['hook_2'] }]
      )
    end
  end

  { 'an empty list' => [], 'nil' => nil }.each do |label, nothing|
    it "still ignores #{label} under the other key" do
      session('PreToolUse' => [matcher('bash_guard', 'Bash')], PreToolUse: nothing) do
        expect(registered_hooks).to eq(PreToolUse: [{ matcher: 'Bash', hookCallbackIds: ['hook_0'] }])
      end
    end
  end
end
