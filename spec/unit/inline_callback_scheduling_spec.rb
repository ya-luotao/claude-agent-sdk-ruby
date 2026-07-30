# frozen_string_literal: true

require 'spec_helper'

# Opt-in `callback_scheduling: :inline` (issue #47): hosts that are already
# fiber-isolated (solid_queue fiber workers with
# IsolatedExecutionState.isolation_level = :fiber) can run user callbacks in
# place on the reactor fiber instead of hopping to a plain thread. The default
# :thread mode keeps the existing semantics — fiber_boundary_spec.rb covers
# those; this file covers the inline opt-in.
RSpec.describe 'Inline callback scheduling' do
  def stub_query_handler_yielding(*messages)
    handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(handler).to receive(:receive_messages) do |&block|
      messages.each { |m| block.call(m) }
    end
    allow(handler).to receive(:spawn_task) { |&blk| blk.call }
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(handler)
    handler
  end

  def stub_transport
    transport = instance_double(
      ClaudeAgentSDK::SubprocessCLITransport,
      connect: true, close: nil, end_input: nil
    )
    allow(transport).to receive(:write)
    allow(transport).to receive(:read_messages)
    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    transport
  end

  def assistant_hash
    { type: 'assistant', message: { role: 'assistant', model: 'claude', content: [{ type: 'text', text: 'hi' }] } }
  end

  def result_hash
    { type: 'result', subtype: 'success', duration_ms: 1, duration_api_ms: 1, is_error: false, num_turns: 1,
      session_id: 's', total_cost_usd: 0 }
  end

  describe 'FiberBoundary.invoke' do
    it 'runs the block in place on the reactor fiber with scheduling: :inline' do
      outer_fiber = nil
      inner_fiber = nil
      inner_scheduler = nil
      Async do
        outer_fiber = Fiber.current
        ClaudeAgentSDK::FiberBoundary.invoke(scheduling: :inline) do
          inner_fiber = Fiber.current
          inner_scheduler = Fiber.scheduler
        end
      end.wait

      expect(inner_fiber).to be(outer_fiber)
      expect(inner_scheduler).not_to be_nil
    end

    it 'still hops to a plain thread when a timeout is given, even with scheduling: :inline' do
      inner_scheduler = :unset
      inner_thread = nil
      Async do
        ClaudeAgentSDK::FiberBoundary.invoke(timeout: 5, scheduling: :inline) do
          inner_scheduler = Fiber.scheduler
          inner_thread = Thread.current
        end
      end.wait

      expect(inner_scheduler).to be_nil
      expect(inner_thread).not_to be(Thread.current)
    end

    it 'defaults to hopping when scheduling is not given' do
      inner_scheduler = :unset
      Async { ClaudeAgentSDK::FiberBoundary.invoke { inner_scheduler = Fiber.scheduler } }.wait
      expect(inner_scheduler).to be_nil
    end
  end

  describe 'ClaudeAgentOptions#callback_scheduling' do
    it 'defaults to :thread' do
      expect(ClaudeAgentSDK::ClaudeAgentOptions.new.callback_scheduling).to eq(:thread)
    end

    it 'accepts :inline and coerces the string form' do
      expect(ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :inline).callback_scheduling).to eq(:inline)
      expect(ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: 'inline').callback_scheduling).to eq(:inline)
    end

    it 'rejects unknown modes loudly' do
      expect { ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :fiber) }
        .to raise_error(ArgumentError, /callback_scheduling must be one of/)
      expect { ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: 42) }
        .to raise_error(ArgumentError, /callback_scheduling must be one of/)
    end

    it 'survives dup_with' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :inline)
      expect(options.dup_with(model: 'opus').callback_scheduling).to eq(:inline)
    end

    it 'is configurable via global default_options' do
      ClaudeAgentSDK.configure { |c| c.default_options = { callback_scheduling: :inline } }
      expect(ClaudeAgentSDK::ClaudeAgentOptions.new.callback_scheduling).to eq(:inline)
    ensure
      ClaudeAgentSDK.reset_configuration
    end
  end

  describe 'ClaudeAgentSDK.query with callback_scheduling: :inline' do
    it 'invokes the user block on the reactor fiber with a live scheduler' do
      stub_transport
      stub_query_handler_yielding(assistant_hash)

      captured_scheduler = :unset
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :inline)
      ClaudeAgentSDK.query(prompt: 'hi', options: options) do |_message|
        captured_scheduler = Fiber.scheduler
      end

      expect(captured_scheduler).not_to be_nil
    end

    it 'supports break in the user block and returns the break value' do
      stub_transport
      stub_query_handler_yielding(assistant_hash, result_hash, assistant_hash)

      received = []
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :inline)
      ret = ClaudeAgentSDK.query(prompt: 'hi', options: options) do |msg|
        received << msg.class
        break :stopped if msg.is_a?(ClaudeAgentSDK::ResultMessage)
      end

      expect(received).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(ret).to eq(:stopped)
    end

    it 'invokes observers inline on the reactor fiber' do
      stub_transport
      stub_query_handler_yielding(assistant_hash)

      observer_class = Class.new do
        attr_reader :schedulers

        def initialize
          @schedulers = {}
        end

        def on_user_prompt(_prompt)
          @schedulers[:on_user_prompt] = Fiber.scheduler
        end

        def on_message(_message)
          @schedulers[:on_message] = Fiber.scheduler
        end
      end
      observer = observer_class.new
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :inline, observers: [observer])

      ClaudeAgentSDK.query(prompt: 'hi', options: options) { |_m| nil }

      expect(observer.schedulers[:on_user_prompt]).not_to be_nil
      expect(observer.schedulers[:on_message]).not_to be_nil
    end
  end

  describe 'Client with callback_scheduling: :inline' do
    it 'invokes the user block on the reactor fiber and still breaks on ResultMessage' do
      stub_transport
      stub_query_handler_yielding(assistant_hash, result_hash)

      captured_scheduler = :unset
      received = []
      Async do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :inline)
        client = ClaudeAgentSDK::Client.new(options: options)
        client.connect
        begin
          client.receive_response do |msg|
            captured_scheduler = Fiber.scheduler
            received << msg.class
          end
        ensure
          client.disconnect
        end
      end.wait

      expect(captured_scheduler).not_to be_nil
      expect(received).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
    end
  end

  describe 'Query callback dispatch' do
    let(:transport) do
      instance_double(ClaudeAgentSDK::SubprocessCLITransport, write: nil, connect: nil, close: nil)
    end

    it 'runs the permission callback inline with a live scheduler' do
      captured = :unset
      can_use_tool = lambda do |_tool, _input, _context|
        captured = Fiber.scheduler
        ClaudeAgentSDK::PermissionResultAllow.new
      end

      query = ClaudeAgentSDK::Query.new(
        transport: transport,
        is_streaming_mode: true,
        can_use_tool: can_use_tool,
        callback_scheduling: :inline
      )

      Async do
        query.send(:handle_permission_request, { tool_name: 'Bash', input: {} })
      end.wait

      expect(captured).not_to be_nil
    end

    it 'runs hook callbacks inline with a live scheduler' do
      captured = :unset
      hook_fn = lambda do |_input, _tool_use_id, _context|
        captured = Fiber.scheduler
        {}
      end
      hooks = { 'PreToolUse' => [{ matcher: 'Bash', hooks: [hook_fn] }] }

      query = ClaudeAgentSDK::Query.new(
        transport: transport,
        is_streaming_mode: true,
        hooks: hooks,
        callback_scheduling: :inline
      )
      allow(query).to receive(:send_control_request).and_return({})
      query.initialize_protocol

      callback_id = query.instance_variable_get(:@hook_callbacks).keys.first
      request_data = { callback_id: callback_id, input: { hook_event_name: 'PreToolUse' }, tool_use_id: 'toolu_1' }

      Async { query.send(:handle_hook_callback, request_data) }.wait

      expect(captured).not_to be_nil
    end

    # In :thread mode a hook timeout is a hard bound: with_timeout abandons
    # the worker thread, which keeps running. In :inline mode the same
    # timeout becomes genuine cooperative cancellation — the hook is
    # interrupted at its next suspension point and its ensure blocks run
    # (Python parity: anyio cancels the coroutine).
    it 'cooperatively cancels a timed-out inline hook at a suspension point' do
      ensure_ran = false
      finished = false
      hook_fn = lambda do |_input, _tool_use_id, _context|
        sleep 5 # scheduler-aware inline: parks the fiber, cancellable
        finished = true
        {}
      ensure
        ensure_ran = true
      end
      hooks = { 'PreToolUse' => [{ matcher: 'Bash', hooks: [hook_fn], timeout: 0.2 }] }

      query = ClaudeAgentSDK::Query.new(
        transport: transport,
        is_streaming_mode: true,
        hooks: hooks,
        callback_scheduling: :inline
      )
      allow(query).to receive(:send_control_request).and_return({})
      query.initialize_protocol

      callback_id = query.instance_variable_get(:@hook_callbacks).keys.first
      request_data = { callback_id: callback_id, input: { hook_event_name: 'PreToolUse' }, tool_use_id: 'toolu_1' }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        Async { query.send(:handle_hook_callback, request_data) }.wait
      end.to raise_error(Async::TimeoutError)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 2
      expect(ensure_ran).to be(true)
      expect(finished).to be(false)
    end

    it 'injects the scheduling mode into SDK MCP servers' do
      tool = ClaudeAgentSDK.create_tool('probe', 'Probe', {}) do |_args|
        { content: [{ type: 'text', text: 'ok' }] }
      end
      server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server', tools: [tool])
      expect(server.callback_scheduling).to eq(:thread)

      ClaudeAgentSDK::Query.new(
        transport: transport,
        is_streaming_mode: true,
        sdk_mcp_servers: { 'probe_server' => server },
        callback_scheduling: :inline
      )

      expect(server.callback_scheduling).to eq(:inline)
    end
  end

  describe 'SDK MCP handlers with an inline server' do
    it 'runs tool handlers on the reactor fiber via call_tool' do
      captured = :unset
      tool = ClaudeAgentSDK.create_tool('probe', 'Probe', {}) do |_args|
        captured = Fiber.scheduler
        { content: [{ type: 'text', text: 'ok' }] }
      end
      server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server', tools: [tool])
      server.callback_scheduling = :inline

      Async { server.call_tool('probe', {}) }.wait

      expect(captured).not_to be_nil
    end

    it 'runs tool handlers on the reactor fiber via the tools/call dispatch path' do
      captured = :unset
      tool = ClaudeAgentSDK.create_tool('probe', 'Probe', {}) do |_args|
        captured = Fiber.scheduler
        { content: [{ type: 'text', text: 'ok' }] }
      end
      server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server', tools: [tool])
      server.callback_scheduling = :inline

      Async do
        server.handle_message(
          jsonrpc: '2.0', id: 1, method: 'tools/call',
          params: { name: 'probe', arguments: {} }
        )
      end.wait

      expect(captured).not_to be_nil
    end

    it 'runs resource readers and prompt generators on the reactor fiber' do
      captured = { resource: :unset, prompt: :unset }
      resource = ClaudeAgentSDK.create_resource(
        uri: 'probe://r', name: 'r', description: 'd', mime_type: 'text/plain'
      ) do
        captured[:resource] = Fiber.scheduler
        { contents: [{ uri: 'probe://r', text: 'ok' }] }
      end
      prompt = ClaudeAgentSDK.create_prompt(name: 'p', description: 'd') do |_args|
        captured[:prompt] = Fiber.scheduler
        { messages: [] }
      end
      server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server', resources: [resource], prompts: [prompt])
      server.callback_scheduling = :inline

      Async do
        server.read_resource('probe://r')
        server.get_prompt('p')
      end.wait

      expect(captured[:resource]).not_to be_nil
      expect(captured[:prompt]).not_to be_nil
    end
  end

  describe 'ClaudeAgentSDK.offload' do
    it 'hops to a plain thread inside a reactor' do
      inner_scheduler = :unset
      inner_thread = nil
      Async do
        ClaudeAgentSDK.offload do
          inner_scheduler = Fiber.scheduler
          inner_thread = Thread.current
        end
      end.wait

      expect(inner_scheduler).to be_nil
      expect(inner_thread).not_to be(Thread.current)
    end

    it 'runs in place without a scheduler and returns the block value' do
      expect(ClaudeAgentSDK.offload { Thread.current }).to be(Thread.current)
    end

    it 'propagates exceptions' do
      expect { ClaudeAgentSDK.offload { raise ArgumentError, 'boom' } }.to raise_error(ArgumentError, 'boom')
    end
  end

  describe 'isolation-level guardrail' do
    before { ClaudeAgentSDK.instance_variable_set(:@inline_isolation_warned, nil) }
    after { ClaudeAgentSDK.instance_variable_set(:@inline_isolation_warned, nil) }

    it 'warns once when inline is enabled under thread isolation' do
      isolated_state = double('IsolatedExecutionState', isolation_level: :thread)
      stub_const('ActiveSupport::IsolatedExecutionState', isolated_state)

      expect do
        ClaudeAgentSDK.check_inline_isolation(:inline)
        ClaudeAgentSDK.check_inline_isolation(:inline)
      end.to output(/isolation_level is :thread/).to_stderr
    end

    it 'stays quiet under fiber isolation' do
      isolated_state = double('IsolatedExecutionState', isolation_level: :fiber)
      stub_const('ActiveSupport::IsolatedExecutionState', isolated_state)

      expect { ClaudeAgentSDK.check_inline_isolation(:inline) }.not_to output.to_stderr
    end

    it 'stays quiet in :thread mode and without ActiveSupport' do
      expect { ClaudeAgentSDK.check_inline_isolation(:thread) }.not_to output.to_stderr
      expect { ClaudeAgentSDK.check_inline_isolation(:inline) }.not_to output.to_stderr
    end
  end
end
