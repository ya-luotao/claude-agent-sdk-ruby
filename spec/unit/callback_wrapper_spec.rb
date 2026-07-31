# frozen_string_literal: true

require 'spec_helper'

# `ClaudeAgentOptions#callback_wrapper` (issue #47 phase 2): optional
# middleware composed around EVERY user-callback dispatch that crosses
# FiberBoundary — message blocks, observers, hooks, permission callbacks,
# SDK MCP handlers. The wrapper is composed BEFORE the thread hop, so it
# runs on the callback's own execution context: the worker thread in the
# default :thread mode (the point — Rails.application.executor.wrap must
# run on the thread that touches ActiveRecord), the reactor fiber in
# :inline mode. inline_callback_scheduling_spec.rb covers the scheduling
# modes themselves; this file covers the wrapper.
RSpec.describe 'Callback wrapper' do
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

  # The identity wrapper in the documented user shape (rubocop would prefer
  # lambda(&:call), but the explicit form is what the docs show).
  def passthrough_wrapper
    ->(invocation) { invocation.call } # rubocop:disable Style/SymbolProc
  end

  # A wrapper that records enter/exit around each invocation, so tests can
  # assert exactly-once wrapping and event ordering.
  def recording_wrapper(events)
    lambda do |invocation|
      events << :enter
      begin
        invocation.call
      ensure
        events << :exit
      end
    end
  end

  describe 'FiberBoundary.invoke with wrapper' do
    it 'runs the wrapper on the same worker thread as the callback in :thread mode' do
      wrapper_thread = nil
      callback_thread = nil
      wrapper = lambda do |invocation|
        wrapper_thread = Thread.current
        invocation.call
      end

      main_thread = Thread.current
      Async do
        ClaudeAgentSDK::FiberBoundary.invoke(wrapper: wrapper) { callback_thread = Thread.current }
      end.wait

      expect(wrapper_thread).to be(callback_thread)
      expect(wrapper_thread).not_to be(main_thread)
    end

    it 'runs the wrapper on the reactor fiber in :inline mode' do
      wrapper_scheduler = :unset
      wrapper_fiber = nil
      outer_fiber = nil
      wrapper = lambda do |invocation|
        wrapper_scheduler = Fiber.scheduler
        wrapper_fiber = Fiber.current
        invocation.call
      end

      Async do
        outer_fiber = Fiber.current
        ClaudeAgentSDK::FiberBoundary.invoke(scheduling: :inline, wrapper: wrapper) { :ok }
      end.wait

      expect(wrapper_scheduler).not_to be_nil
      expect(wrapper_fiber).to be(outer_fiber)
    end

    it 'passes the callback return value through the wrapper' do
      wrapper = passthrough_wrapper
      expect(ClaudeAgentSDK::FiberBoundary.invoke(wrapper: wrapper) { 42 }).to eq(42)
      Async do
        expect(ClaudeAgentSDK::FiberBoundary.invoke(wrapper: wrapper) { :threaded }).to eq(:threaded)
      end.wait
    end

    it 'propagates callback exceptions through the wrapper unchanged' do
      ensure_ran = false
      wrapper = lambda do |invocation|
        invocation.call
      ensure
        ensure_ran = true
      end

      expect do
        Async { ClaudeAgentSDK::FiberBoundary.invoke(wrapper: wrapper) { raise ArgumentError, 'boom' } }.wait
      end.to raise_error(ArgumentError, 'boom')
      expect(ensure_ran).to be(true)
    end

    it 'treats exceptions raised by the wrapper itself like callback exceptions' do
      wrapper = ->(_invocation) { raise 'wrapper blew up' }

      expect do
        Async { ClaudeAgentSDK::FiberBoundary.invoke(wrapper: wrapper) { :never } }.wait
      end.to raise_error(RuntimeError, 'wrapper blew up')
    end

    it 'composes the wrapper inside the timeout bound, on the worker thread' do
      wrapper_thread = nil
      wrapper_scheduler = :unset
      wrapper = lambda do |invocation|
        wrapper_thread = Thread.current
        wrapper_scheduler = Fiber.scheduler
        invocation.call
      end

      result = ClaudeAgentSDK::FiberBoundary.invoke(timeout: 5, wrapper: wrapper) { :store }

      expect(result).to eq(:store)
      expect(wrapper_thread).not_to be(Thread.current)
      expect(wrapper_scheduler).to be_nil
    end

    it 'still enforces the hard bound through the wrapper; the abandoned worker runs its ensure' do
      release = Queue.new
      ensure_ran = Queue.new
      wrapper = lambda do |invocation|
        invocation.call
      ensure
        ensure_ran << true
      end

      expect do
        ClaudeAgentSDK::FiberBoundary.invoke(timeout: 0.05, wrapper: wrapper) { release.pop }
      end.to raise_error(ClaudeAgentSDK::FiberBoundary::JoinTimeout)

      release << :done
      expect(ensure_ran.pop).to be(true)
    end

    it 'composes the wrapper inside the cooperative inline timeout, on the reactor fiber' do
      wrapper_fiber = nil
      wrapper_scheduler = nil
      outer_fiber = nil
      wrapper = lambda do |invocation|
        wrapper_fiber = Fiber.current
        wrapper_scheduler = Fiber.scheduler
        invocation.call
      end

      result = Async do
        outer_fiber = Fiber.current
        ClaudeAgentSDK::FiberBoundary.invoke(timeout: 5, scheduling: :inline, wrapper: wrapper) { :store }
      end.wait

      expect(result).to eq(:store)
      expect(wrapper_scheduler).not_to be_nil
      expect(wrapper_fiber).to be(outer_fiber)
    end

    it 'delivers the inline cancellation through the wrapper un-swallowed, running its ensure' do
      ensure_ran = false
      swallow_attempted = false
      wrapper = lambda do |invocation|
        invocation.call
      rescue StandardError
        # The cancellation is not a StandardError, so a rescue/report wrapper
        # must never observe it — reaching here would mean an expired store
        # call could be converted into a success.
        swallow_attempted = true
        raise
      ensure
        ensure_ran = true
      end

      expect do
        Async do
          ClaudeAgentSDK::FiberBoundary.invoke(timeout: 0.05, scheduling: :inline, wrapper: wrapper) { sleep 5 }
        end.wait
      end.to raise_error(ClaudeAgentSDK::FiberBoundary::JoinTimeout)

      expect(ensure_ran).to be(true)
      expect(swallow_attempted).to be(false)
    end
  end

  describe 'ClaudeAgentOptions#callback_wrapper' do
    it 'defaults to nil' do
      expect(ClaudeAgentSDK::ClaudeAgentOptions.new.callback_wrapper).to be_nil
    end

    it 'accepts any callable and keeps its identity through dup_with' do
      wrapper = passthrough_wrapper
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_wrapper: wrapper)
      expect(options.callback_wrapper).to be(wrapper)
      expect(options.dup_with(model: 'opus').callback_wrapper).to be(wrapper)
    end

    it 'rejects non-callable values loudly' do
      expect { ClaudeAgentSDK::ClaudeAgentOptions.new(callback_wrapper: 42) }
        .to raise_error(ArgumentError, /callback_wrapper must be a callable/)
      expect { ClaudeAgentSDK::ClaudeAgentOptions.new(callback_wrapper: 'wrap') }
        .to raise_error(ArgumentError, /callback_wrapper must be a callable/)
    end

    it 'accepts nil explicitly' do
      expect(ClaudeAgentSDK::ClaudeAgentOptions.new(callback_wrapper: nil).callback_wrapper).to be_nil
    end

    it 'is configurable via global default_options' do
      wrapper = passthrough_wrapper
      ClaudeAgentSDK.configure { |c| c.default_options = { callback_wrapper: wrapper } }
      expect(ClaudeAgentSDK::ClaudeAgentOptions.new.callback_wrapper).to be(wrapper)
    ensure
      ClaudeAgentSDK.reset_configuration
    end
  end

  %i[thread inline].each do |mode|
    describe "ClaudeAgentSDK.query in #{mode} mode" do
      it 'wraps the message block exactly once per message' do
        stub_transport
        stub_query_handler_yielding(assistant_hash)

        events = []
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          callback_scheduling: mode, callback_wrapper: recording_wrapper(events)
        )
        ClaudeAgentSDK.query(prompt: 'hi', options: options) { |_message| events << :block }

        expect(events).to eq(%i[enter block exit])
      end

      it 'wraps each observer notification' do
        stub_transport
        stub_query_handler_yielding(assistant_hash)

        events = []
        observer_class = Class.new do
          include ClaudeAgentSDK::Observer

          def initialize(events)
            @events = events
          end

          def on_user_prompt(_prompt)
            @events << :on_user_prompt
          end

          def on_message(_message)
            @events << :on_message
          end

          def on_close
            @events << :on_close
          end
        end
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          callback_scheduling: mode, callback_wrapper: recording_wrapper(events),
          observers: [observer_class.new(events)]
        )

        ClaudeAgentSDK.query(prompt: 'hi', options: options) { |_m| nil }

        # on_user_prompt, on_message, the message block itself, on_close —
        # each individually wrapped.
        expect(events).to eq(%i[
                               enter on_user_prompt exit
                               enter on_message exit
                               enter exit
                               enter on_close exit
                             ])
      end

      it 'still supports break from the message block through an ensure-based wrapper' do
        stub_transport
        stub_query_handler_yielding(assistant_hash, result_hash, assistant_hash)

        enters = 0
        exits = 0
        wrapper = lambda do |invocation|
          enters += 1
          begin
            invocation.call
          ensure
            exits += 1
          end
        end

        received = []
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: mode, callback_wrapper: wrapper)
        ret = ClaudeAgentSDK.query(prompt: 'hi', options: options) do |msg|
          received << msg.class
          break :stopped if msg.is_a?(ClaudeAgentSDK::ResultMessage)
        end

        expect(ret).to eq(:stopped)
        expect(received).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
        # The wrapper's ensure ran for the breaking iteration too.
        expect(enters).to eq(2)
        expect(exits).to eq(2)
      end
    end

    describe "Query callback dispatch in #{mode} mode" do
      let(:transport) do
        instance_double(ClaudeAgentSDK::SubprocessCLITransport, write: nil, connect: nil, close: nil)
      end

      it 'wraps the permission callback exactly once' do
        events = []
        can_use_tool = lambda do |_tool, _input, _context|
          events << :permission
          ClaudeAgentSDK::PermissionResultAllow.new
        end

        query = ClaudeAgentSDK::Query.new(
          transport: transport,
          is_streaming_mode: true,
          can_use_tool: can_use_tool,
          callback_scheduling: mode,
          callback_wrapper: recording_wrapper(events)
        )

        response = nil
        Async do
          response = query.send(:handle_permission_request, { tool_name: 'Bash', input: {} })
        end.wait

        expect(events).to eq(%i[enter permission exit])
        expect(response[:behavior]).to eq('allow')
      end

      it 'wraps hook callbacks exactly once' do
        events = []
        hook_fn = lambda do |_input, _tool_use_id, _context|
          events << :hook
          {}
        end
        hooks = { 'PreToolUse' => [{ matcher: 'Bash', hooks: [hook_fn] }] }

        query = ClaudeAgentSDK::Query.new(
          transport: transport,
          is_streaming_mode: true,
          hooks: hooks,
          callback_scheduling: mode,
          callback_wrapper: recording_wrapper(events)
        )
        allow(query).to receive(:send_control_request).and_return({})
        query.initialize_protocol

        callback_id = query.instance_variable_get(:@hook_callbacks).keys.first
        request_data = { callback_id: callback_id, input: { hook_event_name: 'PreToolUse' }, tool_use_id: 'toolu_1' }

        Async { query.send(:handle_hook_callback, request_data) }.wait

        expect(events).to eq(%i[enter hook exit])
      end

      it 'wraps hook callbacks with a timeout configured' do
        events = []
        hook_fn = lambda do |_input, _tool_use_id, _context|
          events << :hook
          {}
        end
        hooks = { 'PreToolUse' => [{ matcher: 'Bash', hooks: [hook_fn], timeout: 5 }] }

        query = ClaudeAgentSDK::Query.new(
          transport: transport,
          is_streaming_mode: true,
          hooks: hooks,
          callback_scheduling: mode,
          callback_wrapper: recording_wrapper(events)
        )
        allow(query).to receive(:send_control_request).and_return({})
        query.initialize_protocol

        callback_id = query.instance_variable_get(:@hook_callbacks).keys.first
        request_data = { callback_id: callback_id, input: { hook_event_name: 'PreToolUse' }, tool_use_id: 'toolu_1' }

        Async { query.send(:handle_hook_callback, request_data) }.wait

        expect(events).to eq(%i[enter hook exit])
      end

      it 'wraps SDK MCP tool handlers on the dispatch path exactly once' do
        events = []
        tool = ClaudeAgentSDK.create_tool('probe', 'Probe', {}) do |_args|
          events << :tool
          { content: [{ type: 'text', text: 'ok' }] }
        end
        server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server', tools: [tool])

        query = ClaudeAgentSDK::Query.new(
          transport: transport, is_streaming_mode: true,
          sdk_mcp_servers: { 'probe_server' => server },
          callback_scheduling: mode,
          callback_wrapper: recording_wrapper(events)
        )

        Async do
          query.send(:handle_sdk_mcp_request, 'probe_server',
                     { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'probe', arguments: {} } })
        end.wait

        expect(events).to eq(%i[enter tool exit])
        expect(server.callback_wrapper).to be_nil
      end
    end
  end

  describe 'Query callback dispatch (mode-specific)' do
    let(:transport) do
      instance_double(ClaudeAgentSDK::SubprocessCLITransport, write: nil, connect: nil, close: nil)
    end

    it 'runs the wrapper on the same non-main worker thread as the callback in :thread mode' do
      wrapper_thread = nil
      callback_thread = nil
      wrapper = lambda do |invocation|
        wrapper_thread = Thread.current
        invocation.call
      end
      can_use_tool = lambda do |_tool, _input, _context|
        callback_thread = Thread.current
        ClaudeAgentSDK::PermissionResultAllow.new
      end

      query = ClaudeAgentSDK::Query.new(
        transport: transport, is_streaming_mode: true,
        can_use_tool: can_use_tool,
        callback_scheduling: :thread, callback_wrapper: wrapper
      )

      main_thread = Thread.current
      Async { query.send(:handle_permission_request, { tool_name: 'Bash', input: {} }) }.wait

      expect(wrapper_thread).to be(callback_thread)
      expect(wrapper_thread).not_to be(main_thread)
    end

    it 'runs the wrapper on the reactor fiber in :inline mode' do
      wrapper_scheduler = :unset
      wrapper = lambda do |invocation|
        wrapper_scheduler = Fiber.scheduler
        invocation.call
      end
      can_use_tool = ->(_tool, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }

      query = ClaudeAgentSDK::Query.new(
        transport: transport, is_streaming_mode: true,
        can_use_tool: can_use_tool,
        callback_scheduling: :inline, callback_wrapper: wrapper
      )

      Async { query.send(:handle_permission_request, { tool_name: 'Bash', input: {} }) }.wait

      expect(wrapper_scheduler).not_to be_nil
    end

    # The inline hook-timeout cancellation is injected as InlineCancellation
    # precisely because it is NOT a StandardError: neither the hook's own
    # `rescue StandardError` nor a wrapper's can swallow it, so the outward
    # Async::TimeoutError contract survives a swallow-everything wrapper.
    it 'lets InlineCancellation pass through a wrapper that rescues StandardError' do
      wrapper = lambda do |invocation|
        invocation.call
      rescue StandardError
        :swallowed
      end
      hook_fn = lambda do |_input, _tool_use_id, _context|
        sleep 5
        {}
      end
      hooks = { 'PreToolUse' => [{ matcher: 'Bash', hooks: [hook_fn], timeout: 0.2 }] }

      query = ClaudeAgentSDK::Query.new(
        transport: transport, is_streaming_mode: true,
        hooks: hooks,
        callback_scheduling: :inline, callback_wrapper: wrapper
      )
      allow(query).to receive(:send_control_request).and_return({})
      query.initialize_protocol

      callback_id = query.instance_variable_get(:@hook_callbacks).keys.first
      request_data = { callback_id: callback_id, input: { hook_event_name: 'PreToolUse' }, tool_use_id: 'toolu_1' }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        Async { query.send(:handle_hook_callback, request_data) }.wait
      end.to raise_error(Async::TimeoutError)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    it 'keeps sessions with different wrappers isolated on a shared server' do
      used = []
      tool = ClaudeAgentSDK.create_tool('probe', 'Probe', {}) do |_args|
        { content: [{ type: 'text', text: 'ok' }] }
      end
      server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server', tools: [tool])
      tools_call = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'probe', arguments: {} } }

      wrapper_a = lambda do |invocation|
        used << :a
        invocation.call
      end
      wrapper_b = lambda do |invocation|
        used << :b
        invocation.call
      end

      query_a = ClaudeAgentSDK::Query.new(
        transport: transport, is_streaming_mode: true,
        sdk_mcp_servers: { 'probe_server' => server },
        callback_scheduling: :inline, callback_wrapper: wrapper_a
      )
      query_b = ClaudeAgentSDK::Query.new(
        transport: transport, is_streaming_mode: true,
        sdk_mcp_servers: { 'probe_server' => server },
        callback_scheduling: :thread, callback_wrapper: wrapper_b
      )

      Async do
        query_a.send(:handle_sdk_mcp_request, 'probe_server', tools_call)
        query_b.send(:handle_sdk_mcp_request, 'probe_server', tools_call)
      end.wait

      expect(used).to eq(%i[a b])
      expect(server.callback_wrapper).to be_nil
    end

    # Same closed-scope semantics as callback_scheduling (PR #48): a child
    # task spawned inside a handler inherits the dispatch's fiber-storage
    # scope OBJECT; closing it at dispatch end invalidates the wrapper for
    # every inheritor, so a descendant outliving the dispatch falls back to
    # the target server's own default (nil here).
    it 'does not leak the session wrapper into descendant fibers that outlive the dispatch' do
      wrapped = []
      session_wrapper = lambda do |invocation|
        wrapped << :session
        invocation.call
      end

      direct_tool = ClaudeAgentSDK.create_tool('direct_probe', 'Probe', {}) do |_args|
        { content: [{ type: 'text', text: 'ok' }] }
      end
      direct_server = ClaudeAgentSDK::SdkMcpServer.new(name: 'direct', tools: [direct_tool])

      child = nil
      spawning_tool = ClaudeAgentSDK.create_tool('spawner', 'Spawns a background task', {}) do |_args|
        child = Async::Task.current.async do
          sleep 0.05 # outlive the dispatch
          direct_server.call_tool('direct_probe', {})
        end
        { content: [{ type: 'text', text: 'spawned' }] }
      end
      session_server = ClaudeAgentSDK::SdkMcpServer.new(name: 'spawn_server', tools: [spawning_tool])

      query = ClaudeAgentSDK::Query.new(
        transport: transport, is_streaming_mode: true,
        sdk_mcp_servers: { 'spawn_server' => session_server },
        callback_scheduling: :inline, callback_wrapper: session_wrapper
      )

      Async do
        query.send(:handle_sdk_mcp_request, 'spawn_server',
                   { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'spawner', arguments: {} } })
        child.wait
      end.wait

      # The dispatched handler itself was wrapped; the descendant's direct
      # call after the dispatch closed was not.
      expect(wrapped).to eq([:session])
    end
  end

  describe 'Client with a wrapper' do
    %i[thread inline].each do |mode|
      it "supports break through an ensure-based wrapper in receive_messages (#{mode} mode)" do
        stub_transport
        stub_query_handler_yielding(assistant_hash, result_hash, assistant_hash)

        enters = 0
        exits = 0
        wrapper = lambda do |invocation|
          enters += 1
          begin
            invocation.call
          ensure
            exits += 1
          end
        end

        received = []
        ret = nil
        Async do
          options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: mode, callback_wrapper: wrapper)
          client = ClaudeAgentSDK::Client.new(options: options)
          client.connect
          begin
            ret = client.receive_messages do |msg|
              received << msg.class
              break :early if msg.is_a?(ClaudeAgentSDK::ResultMessage)
            end
          ensure
            client.disconnect
          end
        end.wait

        expect(received).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
        expect(ret).to eq(:early)
        expect(enters).to eq(2)
        expect(exits).to eq(2)
      end
    end
  end

  describe 'SdkMcpServer#callback_wrapper (direct calls)' do
    it 'wraps direct call_tool / read_resource / get_prompt invocations' do
      events = []
      tool = ClaudeAgentSDK.create_tool('probe', 'Probe', {}) do |_args|
        events << :tool
        { content: [{ type: 'text', text: 'ok' }] }
      end
      resource = ClaudeAgentSDK.create_resource(
        uri: 'probe://r', name: 'r', description: 'd', mime_type: 'text/plain'
      ) do
        events << :resource
        { contents: [{ uri: 'probe://r', text: 'ok' }] }
      end
      prompt = ClaudeAgentSDK.create_prompt(name: 'p', description: 'd') do |_args|
        events << :prompt
        { messages: [] }
      end
      server = ClaudeAgentSDK::SdkMcpServer.new(
        name: 'probe_server', tools: [tool], resources: [resource], prompts: [prompt]
      )
      server.callback_wrapper = recording_wrapper(events)

      server.call_tool('probe', {})
      server.read_resource('probe://r')
      server.get_prompt('p')

      expect(events).to eq(%i[
                             enter tool exit
                             enter resource exit
                             enter prompt exit
                           ])
    end
  end

  # Regression (codex review on the phase-2 branch): resolving mode and
  # wrapper through two separate accessors decided scope liveness twice — a
  # scope closing between the reads (dispatch ensure racing a descendant
  # reader) yielded a torn pair: session :inline mode with the server's
  # direct-call wrapper. effective_callback_dispatch decides liveness once
  # and returns the pair atomically.
  describe 'SdkMcpServer#effective_callback_dispatch' do
    # A scope whose active? flips to false after the first liveness check —
    # deterministically forcing the mid-resolution closure the race needs.
    def flipping_scope(mode, wrapper)
      scope = ClaudeAgentSDK::FiberBoundary::CallbackDispatchScope.new(mode, wrapper)
      checks = 0
      scope.define_singleton_method(:active?) do
        checks += 1
        checks == 1
      end
      scope
    end

    it 'never returns a torn session/server mix when the scope closes mid-resolution' do
      session_wrapper = passthrough_wrapper
      server_wrapper = passthrough_wrapper
      server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server')
      server.callback_scheduling = :thread
      server.callback_wrapper = server_wrapper

      Fiber[ClaudeAgentSDK::FiberBoundary::DISPATCH_KEY] = flipping_scope(:inline, session_wrapper)
      begin
        scheduling, wrapper = server.effective_callback_dispatch
      ensure
        Fiber[ClaudeAgentSDK::FiberBoundary::DISPATCH_KEY] = nil
      end

      # One liveness decision: the scope was live when consulted, so BOTH
      # halves are the session's. Before the fix this returned
      # [:inline, server_wrapper].
      expect(scheduling).to eq(:inline)
      expect(wrapper).to be(session_wrapper)
    end

    it 'returns both server defaults for a closed scope' do
      server = ClaudeAgentSDK::SdkMcpServer.new(name: 'probe_server')
      server.callback_scheduling = :inline
      server_wrapper = passthrough_wrapper
      server.callback_wrapper = server_wrapper

      scope = ClaudeAgentSDK::FiberBoundary::CallbackDispatchScope.new(:thread, passthrough_wrapper)
      scope.close
      Fiber[ClaudeAgentSDK::FiberBoundary::DISPATCH_KEY] = scope
      begin
        scheduling, wrapper = server.effective_callback_dispatch
      ensure
        Fiber[ClaudeAgentSDK::FiberBoundary::DISPATCH_KEY] = nil
      end

      expect(scheduling).to eq(:inline)
      expect(wrapper).to be(server_wrapper)
    end
  end

  # Regression (codex review): a user's `break` is normal loop control. The
  # Break translation now lives INSIDE the invocation handed to the
  # wrapper, so a conforming rescue/report/re-raise wrapper observes a
  # clean return — never a LocalJumpError it could falsely report, and a
  # swallowing wrapper cannot lose the break.
  describe 'break visibility to wrappers (:thread mode)' do
    it 'does not expose break as an exception to a rescue/report/re-raise wrapper' do
      observed = []
      reporting_wrapper = lambda do |invocation|
        invocation.call
      rescue StandardError => e
        observed << e
        raise
      end

      stub_transport
      stub_query_handler_yielding(assistant_hash, result_hash, assistant_hash)

      received = []
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        callback_scheduling: :thread, callback_wrapper: reporting_wrapper
      )
      ret = ClaudeAgentSDK.query(prompt: 'hi', options: options) do |msg|
        received << msg.class
        break :stopped if msg.is_a?(ClaudeAgentSDK::ResultMessage)
      end

      expect(observed).to be_empty
      expect(received).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(ret).to eq(:stopped)
    end

    it 'preserves break through a wrapper that swallows StandardError' do
      swallowing_wrapper = lambda do |invocation|
        invocation.call
      rescue StandardError
        nil # a misbehaving wrapper; break must survive it anyway
      end

      stub_transport
      stub_query_handler_yielding(assistant_hash, result_hash, assistant_hash)

      received = []
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        callback_scheduling: :thread, callback_wrapper: swallowing_wrapper
      )
      ret = ClaudeAgentSDK.query(prompt: 'hi', options: options) do |msg|
        received << msg.class
        break :stopped if msg.is_a?(ClaudeAgentSDK::ResultMessage)
      end

      expect(received).to eq([ClaudeAgentSDK::AssistantMessage, ClaudeAgentSDK::ResultMessage])
      expect(ret).to eq(:stopped)
    end
  end

  # FiberBoundary only special-cases the exact Symbol :inline, so an
  # unvalidated accessor value (String "inline", a typo) would silently
  # degrade to the thread hop — the opposite of what an inline host asked
  # for. The server setters therefore enforce the same coercion + whitelist
  # rule as ClaudeAgentOptions.
  describe 'SdkMcpServer accessor validation' do
    let(:server) { ClaudeAgentSDK::SdkMcpServer.new(name: 'validated') }

    it 'coerces the String form of callback_scheduling to the Symbol' do
      server.callback_scheduling = 'inline'
      expect(server.callback_scheduling).to eq(:inline)
      server.callback_scheduling = 'thread'
      expect(server.callback_scheduling).to eq(:thread)
    end

    it 'rejects unknown scheduling modes loudly instead of degrading to :thread' do
      expect { server.callback_scheduling = :reactor }
        .to raise_error(ArgumentError, /callback_scheduling must be one of :thread, :inline/)
      expect { server.callback_scheduling = nil }
        .to raise_error(ArgumentError, /callback_scheduling must be one of/)
      expect(server.callback_scheduling).to eq(:thread) # default untouched
    end

    it 'rejects a non-callable callback_wrapper at set time' do
      expect { server.callback_wrapper = 42 }
        .to raise_error(ArgumentError, /callback_wrapper must be a callable/)
      server.callback_wrapper = nil # explicit nil stays allowed
      expect(server.callback_wrapper).to be_nil
    end
  end

  # The wrapper also composes around timeout-bounded SessionStore adapter
  # dispatch (mirror-batcher appends, resume-materialization loads), inside
  # the bound — so executor.wrap covers an AR-backed adapter too.
  describe 'store-adapter dispatch composition' do
    let(:projects) { '/tmp/cas-wrapper-base' }
    let(:file_path) { "#{projects}/pk/sid.jsonl" }
    let(:errors) { [] }
    let(:on_error) { ->(k, m) { errors << [k, m] } }

    it 'wraps batcher appends for a default (thread-hop) store on the worker thread' do
      events = []
      append_thread = nil
      wrapper = lambda do |invocation|
        events << [:enter, Thread.current]
        invocation.call
      ensure
        events << :exit
      end
      store = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        define_method(:append) do |k, entries|
          append_thread = Thread.current
          super(k, entries)
        end
      end.new

      Async do
        b = ClaudeAgentSDK::TranscriptMirrorBatcher.new(store: store, projects_dir: projects,
                                                        on_error: on_error, callback_wrapper: wrapper)
        b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => '1' }])
        b.flush
      end.wait

      expect(events.length).to eq(2)
      expect(events.first.first).to eq(:enter)
      expect(events.first.last).to be(append_thread)
      expect(append_thread).not_to be(Thread.current)
      expect(errors).to be_empty
    end

    it 'wraps batcher appends for an inline-declared store on the reactor fiber' do
      wrapper_fiber = nil
      append_fiber = nil
      flush_fiber = nil
      wrapper = lambda do |invocation|
        wrapper_fiber = Fiber.current
        invocation.call
      end
      store = Class.new(ClaudeAgentSDK::InMemorySessionStore) do
        def callback_scheduling = :inline

        define_method(:append) do |k, entries|
          append_fiber = Fiber.current
          super(k, entries)
        end
      end.new

      Async do
        b = ClaudeAgentSDK::TranscriptMirrorBatcher.new(store: store, projects_dir: projects,
                                                        on_error: on_error, callback_wrapper: wrapper)
        b.enqueue(file_path, [{ 'type' => 'user', 'uuid' => '1' }])
        flush_fiber = Fiber.current
        b.flush
      end.wait

      expect(wrapper_fiber).to be(flush_fiber)
      expect(append_fiber).to be(flush_fiber)
      expect(errors).to be_empty
    end

    it 'wraps resume-materialization store calls with the session wrapper' do
      wrapped_calls = []
      wrapper = lambda do |invocation|
        wrapped_calls << Thread.current
        invocation.call
      end
      sid = SecureRandom.uuid
      cwd = Dir.mktmpdir
      store = ClaudeAgentSDK::InMemorySessionStore.new
      project_key = ClaudeAgentSDK.project_key_for_directory(cwd)
      store.append({ 'project_key' => project_key, 'session_id' => sid },
                   [{ 'type' => 'user', 'uuid' => SecureRandom.uuid, 'message' => { 'content' => 'hi' } }])

      mat = nil
      begin
        mat = ClaudeAgentSDK::SessionResume.materialize_resume_session(
          ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: sid, cwd: cwd,
                                                 callback_wrapper: wrapper)
        )

        expect(mat).not_to be_nil
        # At least the #load ran; every call went through the wrapper on its
        # worker thread (default thread-hop store).
        expect(wrapped_calls).not_to be_empty
        expect(wrapped_calls).to all(satisfy { |t| !t.equal?(Thread.current) })
      ensure
        mat&.cleanup
        FileUtils.remove_entry(cwd) if File.directory?(cwd)
      end
    end
  end
end
