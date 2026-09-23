# frozen_string_literal: true

require 'spec_helper'

# Issue #81: a user callback (tool handler / hook / can_use_tool) that calls
# Client#disconnect. In :thread mode the callback runs on a FiberBoundary
# worker thread, so Query#close marshals to the reactor-side close watcher
# and the callback sees a normal return. In :inline mode the callback runs on
# a control-request handler task that is a CHILD of the read task the close
# stops: `@task.stop` cascades back into the caller as Async::Stop, and
# before the fix that unwound Query#close_now mid-teardown — the transport
# was never closed by Query (only Client#disconnect's compensating ensure
# saved the CLI process) and @close_requests stayed open. The close now
# defers the cascading stop until the teardown section has run, so the
# ordering "disconnect finished => transport closed, waiters released,
# close requests closed" holds on every calling context.
RSpec.describe 'Query#close from inside a user callback (issue #81)' do
  # Scripted stand-in for the CLI transport: read_messages parks on a
  # Thread::Queue like a live CLI with no traffic (scheduler-aware pop),
  # frames are injected by the test, the `initialize` handshake is answered
  # so a real Client#connect completes, and writes after close raise
  # CLIConnectionError like SubprocessCLITransport does.
  let(:transport_class) do
    Class.new do
      attr_reader :closed, :writes

      def initialize(_options = nil, **_transport_args)
        @queue = Thread::Queue.new
        @closed = false
        @writes = []
      end

      def connect; end
      def end_input; end
      def ready? = !@closed

      def inject(frame)
        @queue << frame
      end

      def read_messages(&block)
        while (msg = @queue.pop)
          block.call(msg)
        end
      end

      def write(str)
        raise ClaudeAgentSDK::CLIConnectionError, 'transport closed' if @closed

        frame = JSON.parse(str, symbolize_names: true)
        @writes << frame
        return unless frame[:type] == 'control_request' && frame.dig(:request, :subtype) == 'initialize'

        @queue << { type: 'control_response',
                    response: { subtype: 'success', request_id: frame[:request_id], requestId: frame[:request_id],
                                response: { commands: [] } } }
      end

      def close
        @closed = true
        @queue.close
      end
    end
  end

  def permission_request(request_id)
    { type: 'control_request', request_id: request_id,
      request: { subtype: 'can_use_tool', tool_name: 'Bash', input: { command: 'true' } } }
  end

  # In :thread mode the callback keeps running on its worker thread after
  # the close stopped the handler fiber that was joining it — the reactor
  # can exit before the callback's own bookkeeping ran. Gate on it instead
  # of sleeping. (Immediate in :inline mode.)
  def await_callback(done)
    expect(done.pop(timeout: 5)).to be(true), 'the callback did not finish'
  end

  # Snapshot of the teardown state as seen by the callback the moment its
  # close call returned or raised.
  def snapshot(query, transport, raised)
    { raised: raised, transport_closed: transport.closed,
      close_requests_closed: query.instance_variable_get(:@close_requests).closed? }
  end

  shared_examples 'a close that completes its teardown' do |mode|
    it "with callback_scheduling: #{mode} closes the transport, releases waiters and closes close requests" do
      transport = transport_class.new
      query = nil
      observed = nil
      done = Thread::Queue.new
      can_use_tool = lambda do |_tool, _input, _context|
        begin
          query.close
          observed = snapshot(query, transport, nil)
        rescue Exception => e # rubocop:disable Lint/RescueException -- Async::Stop is not a StandardError
          observed = snapshot(query, transport, e)
        ensure
          done << true
        end
        ClaudeAgentSDK::PermissionResultAllow.new
      end
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                        can_use_tool: can_use_tool, callback_scheduling: mode)

      waiter_error = nil
      Async do |task|
        query.start
        # Parks in await_control_response: nothing answers the interrupt.
        task.async do
          query.interrupt
        rescue StandardError => e
          waiter_error = e
        end
        transport.inject(permission_request('req_close_probe'))
      end.wait # exits only when the read task, the handler and the watcher are all done
      await_callback(done)

      expect(observed).not_to be_nil, 'the callback never ran'
      expect(observed[:transport_closed]).to be(true)
      expect(observed[:close_requests_closed]).to be(true)
      # The pending-waiter sweep runs before the read task is stopped, so it
      # was already released before the fix; pinned here as part of the
      # documented close ordering.
      expect(waiter_error).to be_a(ClaudeAgentSDK::CLIConnectionError)
      expect(transport.closed).to be(true)
    end
  end

  describe 'Query#close' do
    include_examples 'a close that completes its teardown', :thread
    include_examples 'a close that completes its teardown', :inline

    it 'in :thread mode returns normally to the worker-thread callback' do
      transport = transport_class.new
      query = nil
      observed = nil
      done = Thread::Queue.new
      can_use_tool = lambda do |_tool, _input, _context|
        begin
          query.close
          observed = snapshot(query, transport, nil)
        rescue Exception => e # rubocop:disable Lint/RescueException
          observed = snapshot(query, transport, e)
        ensure
          done << true
        end
        ClaudeAgentSDK::PermissionResultAllow.new
      end
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                        can_use_tool: can_use_tool, callback_scheduling: :thread)

      Async do
        query.start
        transport.inject(permission_request('req_close_probe'))
      end.wait
      await_callback(done)

      expect(observed[:raised]).to be_nil
    end

    # The inline callback's task is a child of the stopped read task, so the
    # framework must still unwind it — but only AFTER the teardown ran. The
    # cascading stop is deferred through the teardown section and delivered
    # as Async::Stop on the way out of #close (Python parity: a hook that
    # awaits disconnect() gets CancelledError there).
    it 'in :inline mode unwinds the callback with Async::Stop only after the teardown completed' do
      transport = transport_class.new
      query = nil
      observed = nil
      done = Thread::Queue.new
      can_use_tool = lambda do |_tool, _input, _context|
        begin
          query.close
          observed = snapshot(query, transport, nil)
        rescue Exception => e # rubocop:disable Lint/RescueException
          observed = snapshot(query, transport, e)
        ensure
          done << true
        end
        ClaudeAgentSDK::PermissionResultAllow.new
      end
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                        can_use_tool: can_use_tool, callback_scheduling: :inline)

      Async do
        query.start
        transport.inject(permission_request('req_close_probe'))
      end.wait
      await_callback(done)

      expect(observed[:raised]).to be_a(Async::Stop)
      expect(observed[:transport_closed]).to be(true)
      expect(observed[:close_requests_closed]).to be(true)
      expect(query.instance_variable_get(:@inflight_control_request_tasks)).to be_empty
    end

    it 'in :inline mode completes the teardown when a hook (under its cooperative timeout) closes the query' do
      transport = transport_class.new
      query = nil
      observed = nil
      done = Thread::Queue.new
      hook_fn = lambda do |_input, _tool_use_id, _context|
        query.close
        observed = snapshot(query, transport, nil)
        {}
      rescue Exception => e # rubocop:disable Lint/RescueException
        observed = snapshot(query, transport, e)
        raise
      ensure
        done << true
      end
      hooks = { 'PreToolUse' => [{ matcher: 'Bash', hooks: [hook_fn], timeout: 30 }] }
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                        hooks: hooks, callback_scheduling: :inline)

      Async do
        query.start
        query.initialize_protocol
        callback_id = query.instance_variable_get(:@hook_callbacks).keys.first
        transport.inject(type: 'control_request', request_id: 'req_hook_close',
                         request: { subtype: 'hook_callback', callback_id: callback_id,
                                    input: { hook_event_name: 'PreToolUse' }, tool_use_id: 'toolu_1' })
      end.wait

      await_callback(done)
      expect(observed[:raised]).to be_a(Async::Stop)
      expect(observed[:transport_closed]).to be(true)
      expect(observed[:close_requests_closed]).to be(true)
    end
  end

  describe 'Query#close teardown ordering' do
    # @close_requests.close has no suspension point and sits in an ensure
    # around the transport close, so a transport whose #close raises (or a
    # deadline delivered while it is suspended mid-reap) can never strand a
    # parked close watcher. The transport error itself still propagates.
    it 'releases the close watcher even when the transport close raises' do
      transport = transport_class.new
      allow(transport).to receive(:close).and_raise(IOError, 'boom')
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true)

      Async do
        query.start
        expect { query.close }.to raise_error(IOError, 'boom')
      end.wait # exits only if the transient watcher was released

      expect(query.instance_variable_get(:@close_requests).closed?).to be(true)
    end
  end

  describe 'Client#disconnect' do
    def connect_and_inject(client, created)
      Async do
        client.connect
        transport = created.first
        transport.inject(permission_request('req_close_probe'))
      end.wait
    end

    it 'in :inline mode completes the query teardown before the callback unwinds and leaves nothing running' do
      created = []
      klass = transport_class
      recording_class = Class.new(klass) do
        define_method(:initialize) do |*args, **kwargs|
          super(*args, **kwargs)
          created << self
        end
      end

      client = nil
      observed = nil
      done = Thread::Queue.new
      can_use_tool = lambda do |_tool, _input, _context|
        query = client.instance_variable_get(:@query_handler)
        begin
          client.disconnect
          observed = snapshot(query, created.first, nil)
        rescue Exception => e # rubocop:disable Lint/RescueException
          observed = snapshot(query, created.first, e)
        ensure
          done << true
        end
        ClaudeAgentSDK::PermissionResultAllow.new
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :inline, can_use_tool: can_use_tool)
      client = ClaudeAgentSDK::Client.new(options: options, transport_class: recording_class)

      connect_and_inject(client, created)
      await_callback(done)

      expect(observed).not_to be_nil, 'the permission callback never ran'
      expect(observed[:raised]).to be_a(Async::Stop)
      expect(observed[:transport_closed]).to be(true)
      expect(observed[:close_requests_closed]).to be(true)
      expect(client.instance_variable_get(:@connected)).to be(false)
      expect(client.instance_variable_get(:@transport)).to be_nil
    end

    # Same bug from the other side of the tree: a streaming-input enumerator
    # is iterated ON the reactor inside a Query#spawn_task child (tracked in
    # @child_tasks, a sibling of the read task). A disconnect from inside it
    # makes `@child_tasks.each(&:stop)` stop the CURRENT task — a direct
    # raise, no cascade needed — and used to unwind close_now before the
    # read task was stopped and the transport closed. The gate makes the
    # enumerator suspend once first, like an interactive stream waiting for
    # a response: only then is its task registered in @child_tasks.
    it 'from a streaming-input enumerator completes the teardown before the stream unwinds' do
      created = []
      klass = transport_class
      recording_class = Class.new(klass) do
        define_method(:initialize) do |*args, **kwargs|
          super(*args, **kwargs)
          created << self
        end
      end

      client = nil
      observed = nil
      done = Thread::Queue.new
      gate = Thread::Queue.new
      stream = Enumerator.new do |y|
        y << { type: 'user', message: { role: 'user', content: 'hi' }, session_id: 'default' }
        gate.pop # scheduler-aware: parks the stream task, connect returns and registers it
        query = client.instance_variable_get(:@query_handler)
        begin
          client.disconnect
          observed = snapshot(query, created.first, nil)
        rescue Exception => e # rubocop:disable Lint/RescueException
          observed = snapshot(query, created.first, e)
        ensure
          done << true
        end
        y << { type: 'user', message: { role: 'user', content: 'never sent' }, session_id: 'default' }
      end
      client = ClaudeAgentSDK::Client.new(options: ClaudeAgentSDK::ClaudeAgentOptions.new,
                                          transport_class: recording_class)

      Async do
        client.connect(stream)
        expect(client.instance_variable_get(:@query_handler).instance_variable_get(:@child_tasks).size).to eq(1)
        gate << true
      end.wait # exits only when the read task, the stream task and the watcher are all done
      await_callback(done)

      expect(observed).not_to be_nil, 'the stream never reached disconnect'
      expect(observed[:raised]).to be_a(Async::Stop)
      expect(observed[:transport_closed]).to be(true)
      expect(observed[:close_requests_closed]).to be(true)
      expect(client.instance_variable_get(:@connected)).to be(false)
      sent = created.first.writes.select { |w| w[:type] == 'user' }.map { |w| w.dig(:message, :content) }
      expect(sent).to eq(['hi'])
    end

    it 'in :thread mode returns normally to the callback with the teardown complete' do
      created = []
      klass = transport_class
      recording_class = Class.new(klass) do
        define_method(:initialize) do |*args, **kwargs|
          super(*args, **kwargs)
          created << self
        end
      end

      client = nil
      observed = nil
      done = Thread::Queue.new
      can_use_tool = lambda do |_tool, _input, _context|
        query = client.instance_variable_get(:@query_handler)
        begin
          client.disconnect
          observed = snapshot(query, created.first, nil)
        rescue Exception => e # rubocop:disable Lint/RescueException
          observed = snapshot(query, created.first, e)
        ensure
          done << true
        end
        ClaudeAgentSDK::PermissionResultAllow.new
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(callback_scheduling: :thread, can_use_tool: can_use_tool)
      client = ClaudeAgentSDK::Client.new(options: options, transport_class: recording_class)

      connect_and_inject(client, created)
      await_callback(done)

      expect(observed).not_to be_nil, 'the permission callback never ran'
      expect(observed[:raised]).to be_nil
      expect(observed[:transport_closed]).to be(true)
      expect(observed[:close_requests_closed]).to be(true)
      expect(client.instance_variable_get(:@connected)).to be(false)
    end
  end
end
