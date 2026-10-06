# frozen_string_literal: true

require 'json'

# Fixtures for the specs that drive ClaudeAgentSDK.query and
# ClaudeAgentSDK::Client through their public API only: an in-memory stand-in
# for the CLI process, an observer that records what it was told, and a way to
# deliver a caller's deadline at a chosen moment.
module EntryPointHarness
  ASSISTANT_FRAME = {
    type: 'assistant',
    message: { role: 'assistant', model: 'claude-sonnet-4', content: [{ type: 'text', text: 'done' }] }
  }.freeze

  RESULT_FRAME = {
    type: 'result', subtype: 'success', is_error: false, duration_ms: 1, duration_api_ms: 1,
    num_turns: 1, session_id: 's', total_cost_usd: 0
  }.freeze

  # In-memory stand-in for the CLI process, used as a transport.
  #
  # It answers `initialize` the way the CLI answers control requests (payload
  # trimmed) or rejects it, replies to every user message with +replies+, and
  # ends its output when stdin is closed (#end_input) or the transport is
  # closed — as the CLI does in stream-json mode. Everything written to it is
  # kept, parsed, in #writes.
  #
  #   replies:           frames sent after each user message; an Exception in
  #                      the list is raised from the read loop instead
  #   hang_up_after:     end the output after that many user messages
  #   reject_initialize: answer the handshake with an error
  #   connect_error:     raised by #connect
  #   close_errors:      raised by #close, one per call, in order
  #   on_connect:        called with the transport at the start of #connect
  #   on_write:          called with each parsed frame and the transport before
  #                      the frame is accepted; what it raises fails the write
  class FakeCLI
    attr_reader :options, :writes, :lines, :close_calls

    # A transport class the SDK constructs itself and treats as a CLI
    # subprocess (so a store-backed resume is materialized for it). No
    # subprocess is spawned: .new hands back a FakeCLI, also pushed on +created+.
    def self.subprocess_class(created = [], **switches)
      factory(ClaudeAgentSDK::SubprocessCLITransport, created, switches)
    end

    # A transport class the SDK constructs itself and knows nothing about.
    def self.foreign_class(created = [], **switches)
      factory(Object, created, switches)
    end

    def self.factory(superclass, created, switches)
      fake = self
      Class.new(superclass) do
        define_singleton_method(:new) do |options, **kwargs|
          fake.new(options, **switches, **kwargs).tap { |cli| created << cli }
        end
      end
    end
    private_class_method :factory

    def initialize(options = nil, replies: [ASSISTANT_FRAME, RESULT_FRAME], hang_up_after: nil,
                   reject_initialize: false, connect_error: nil, close_errors: [], on_connect: nil, on_write: nil)
      @options = options
      @replies = replies
      @hang_up_after = hang_up_after
      @reject_initialize = reject_initialize
      @connect_error = connect_error
      @close_errors = close_errors.dup
      @on_connect = on_connect
      @on_write = on_write
      @stdout = Thread::Queue.new
      @writes = []
      @lines = []
      @close_calls = 0
      @closed = false
      @input_ended = false
      @read_loop_ended = false
    end

    def connect
      @on_connect&.call(self)
      raise @connect_error if @connect_error
    end

    def ready?
      !@closed
    end

    def write(line)
      raise ClaudeAgentSDK::CLIConnectionError, 'transport closed' if @closed

      frame = JSON.parse(line, symbolize_names: true)
      @on_write&.call(frame, self)
      @lines << line
      @writes << frame
      case frame[:type]
      when 'control_request' then answer_initialize(frame) if frame.dig(:request, :subtype) == 'initialize'
      when 'user' then reply_to_user_message
      end
    end

    def read_messages
      while (frame = @stdout.pop) != :eof
        raise frame if frame.is_a?(Exception)

        yield frame
      end
    ensure
      @read_loop_ended = true
    end

    def end_input
      @input_ended = true
      hang_up
    end

    # A close that raises still ends the output; it does not count as closed.
    def close
      @close_calls += 1
      hang_up
      error = @close_errors.shift
      raise error if error

      @closed = true
    end

    # Put a frame on the output, as if the CLI had sent it.
    def inject(frame)
      @stdout << frame
    end

    def closed?
      @closed
    end

    def input_ended?
      @input_ended
    end

    def read_loop_ended?
      @read_loop_ended
    end

    def user_writes
      @writes.select { |frame| frame[:type] == 'user' }
    end

    # The CLAUDE_CONFIG_DIR the transport was constructed with.
    def config_dir
      @options&.env&.fetch('CLAUDE_CONFIG_DIR', nil)
    end

    def inspect
      "#<FakeCLI closed=#{@closed} input_ended=#{@input_ended} read_loop_ended=#{@read_loop_ended}>"
    end

    private

    def answer_initialize(frame)
      inject(type: 'control_response', response: initialize_response(frame[:request_id]))
    end

    def initialize_response(request_id)
      if @reject_initialize
        { subtype: 'error', request_id: request_id, error: 'Invalid initialize request' }
      else
        { subtype: 'success', request_id: request_id,
          response: { commands: [], agents: [], output_style: 'default', models: [], pid: 4242,
                      session_state: 'idle', capabilities: [] } }
      end
    end

    def reply_to_user_message
      @replies.each { |frame| inject(frame.is_a?(Exception) ? frame : JSON.parse(JSON.generate(frame), symbolize_names: true)) }
      hang_up if @hang_up_after && user_writes.length >= @hang_up_after
    end

    def hang_up
      @stdout << :eof
    end
  end

  # An observer that records every notification as [name, payload], in order.
  # +reactions+ maps a notification name to a callable run after recording
  # (given the payload), on whatever the SDK runs the observer on.
  class RecordingObserver
    include ClaudeAgentSDK::Observer

    def initialize(**reactions)
      @reactions = reactions
      @events = []
      @lock = Mutex.new
    end

    def on_user_prompt(prompt)
      record(:on_user_prompt, prompt)
    end

    def on_message(message)
      record(:on_message, message)
    end

    def on_error(error)
      record(:on_error, error)
    end

    def on_close
      record(:on_close, nil)
    end

    def events
      @lock.synchronize { @events.dup }
    end

    def names
      events.map(&:first)
    end

    def payloads(name)
      events.select { |event, _| event == name }.map(&:last)
    end

    private

    def record(name, payload)
      @lock.synchronize { @events << [name, payload] }
      @reactions[name]&.call(payload)
    end
  end

  # Deliver a caller's deadline to +task+ now. An expired task.with_timeout is
  # the scheduler raising the timeout's exception into the fiber that armed
  # it; this raises it the same way, at a moment the example chose (once an
  # observer has signalled that it is running) instead of after a duration
  # that slow setup could use up.
  def self.expire_deadline_on(task, exception_class = Async::TimeoutError)
    Fiber.scheduler.raise(task.fiber, exception_class, 'execution expired')
  end
end
