# frozen_string_literal: true

RSpec.describe ClaudeAgentSDK::Observer do
  let(:observer_class) do
    Class.new do
      include ClaudeAgentSDK::Observer

      attr_reader :messages, :errors, :closed, :events

      def initialize
        @messages = []
        @errors = []
        @closed = false
        @events = []
      end

      def on_message(message)
        @messages << message
        @events << :message
      end

      def on_error(error)
        @errors << error
        @events << :error
      end

      def on_close
        @closed = true
        @events << :close
      end
    end
  end

  describe 'module interface' do
    it 'provides no-op defaults for all methods' do
      obj = Class.new { include ClaudeAgentSDK::Observer }.new
      expect { obj.on_user_prompt('test prompt') }.not_to raise_error
      expect { obj.on_message('test') }.not_to raise_error
      expect { obj.on_error(StandardError.new) }.not_to raise_error
      expect { obj.on_close }.not_to raise_error
    end
  end

  describe 'observer in ClaudeAgentOptions' do
    it 'defaults observers to empty array' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new
      expect(options.observers).to eq([])
    end

    it 'accepts observers in constructor' do
      obs = observer_class.new
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [obs])
      expect(options.observers).to eq([obs])
    end

    it 'accepts callable observers (lambda factory)' do
      factory = -> { observer_class.new }
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [factory])
      expect(options.observers).to eq([factory])
    end
  end

  describe '.extract_user_prompt_text' do
    it 'extracts string content from a user message hash' do
      msg = { type: 'user', message: { role: 'user', content: 'hello' } }
      expect(ClaudeAgentSDK.extract_user_prompt_text(msg)).to eq('hello')
    end

    it 'extracts and joins non-empty text blocks' do
      msg = { type: 'user', message: { content: [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }] } }
      expect(ClaudeAgentSDK.extract_user_prompt_text(msg)).to eq("a\nb")
    end

    it 'parses JSON-string stream items (with trailing newline)' do
      json = "#{JSON.generate(type: 'user', message: { content: 'from json' })}\n"
      expect(ClaudeAgentSDK.extract_user_prompt_text(json)).to eq('from json')
    end

    it 'returns nil for non-user messages, invalid JSON, and arbitrary objects' do
      expect(ClaudeAgentSDK.extract_user_prompt_text({ type: 'control_request' })).to be_nil
      expect(ClaudeAgentSDK.extract_user_prompt_text('not json')).to be_nil
      expect(ClaudeAgentSDK.extract_user_prompt_text(42)).to be_nil
    end

    it 'never returns an empty string (would poison the OTel first-prompt latch)' do
      empty_shapes = [
        { type: 'user', message: { content: '' } },
        { type: 'user', message: { content: [{ type: 'text', text: '' }] } },
        { type: 'user', message: { content: [{ type: 'text' }] } },
        { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't1' }] } }
      ]
      empty_shapes.each do |msg|
        expect(ClaudeAgentSDK.extract_user_prompt_text(msg)).to be_nil
      end
    end

    it 'skips empty blocks but keeps real ones' do
      msg = { type: 'user', message: { content: [{ type: 'text', text: '' }, { type: 'text', text: 'real' }] } }
      expect(ClaudeAgentSDK.extract_user_prompt_text(msg)).to eq('real')
    end
  end

  describe '.resolve_observers' do
    it 'passes plain observer instances through' do
      obs = observer_class.new
      resolved = ClaudeAgentSDK.resolve_observers([obs])
      expect(resolved).to eq([obs])
    end

    it 'calls lambdas to create fresh instances' do
      factory = -> { observer_class.new }
      resolved = ClaudeAgentSDK.resolve_observers([factory])
      expect(resolved.length).to eq(1)
      expect(resolved.first).to be_a(observer_class)
    end

    it 'creates a new instance each time for lambdas' do
      factory = -> { observer_class.new }
      resolved1 = ClaudeAgentSDK.resolve_observers([factory])
      resolved2 = ClaudeAgentSDK.resolve_observers([factory])
      expect(resolved1.first).not_to equal(resolved2.first)
    end

    it 'handles nil gracefully' do
      expect(ClaudeAgentSDK.resolve_observers(nil)).to eq([])
    end
  end

  describe 'observer wiring in query()' do
    let(:observer) { observer_class.new }

    # Use instance_double + stubbed Query (matching query_api_spec.rb pattern)
    let(:transport) do
      instance_double(
        ClaudeAgentSDK::SubprocessCLITransport,
        connect: true, close: nil, end_input: nil
      ).tap do |t|
        allow(t).to receive(:write)
      end
    end

    let(:queued_messages) do
      [
        sample_assistant_message,
        sample_result_message
      ]
    end

    let(:query_handler) do
      msgs = queued_messages
      instance_double(
        ClaudeAgentSDK::Query,
        start: true,
        initialize_protocol: nil,
        wait_for_result_and_end_input: nil,
        close: nil
      ).tap do |qh|
        allow(qh).to receive(:receive_messages) do |&block|
          msgs.each { |m| block.call(m) }
        end
        allow(qh).to receive(:spawn_task) { |&blk| blk.call }
      end
    end

    before do
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)
    end

    it 'calls on_message for each parsed message' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer])

      Async do
        ClaudeAgentSDK.query(prompt: 'test', options: options) { |_msg| nil }
      end.wait

      expect(observer.messages.length).to eq(2)
      expect(observer.messages[0]).to be_a(ClaudeAgentSDK::AssistantMessage)
      expect(observer.messages[1]).to be_a(ClaudeAgentSDK::ResultMessage)
    end

    it 'calls on_close when query completes' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer])

      Async do
        ClaudeAgentSDK.query(prompt: 'test', options: options) { |_msg| nil }
      end.wait

      expect(observer.closed).to be true
    end

    it 'calls multiple observers' do
      observer2 = observer_class.new
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer, observer2])

      Async do
        ClaudeAgentSDK.query(prompt: 'test', options: options) { |_msg| nil }
      end.wait

      expect(observer.messages.length).to eq(2)
      expect(observer2.messages.length).to eq(2)
    end

    it 'resolves callable observers into fresh instances per query' do
      call_count = 0
      factory = lambda {
        call_count += 1
        observer_class.new
      }
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [factory])

      Async do
        ClaudeAgentSDK.query(prompt: 'test', options: options) { |_msg| nil }
      end.wait

      expect(call_count).to eq(1)
    end

    it 'fires on_user_prompt for each user message in a streaming-input prompt' do
      allow(query_handler).to receive(:stream_input) { |stream| stream.each { |_m| nil } }
      prompts = []
      prompt_observer = Class.new do
        include ClaudeAgentSDK::Observer

        def initialize(sink)
          @sink = sink
        end

        def on_user_prompt(prompt)
          @sink << prompt
        end
      end.new(prompts)

      stream = [
        { type: 'user', message: { role: 'user', content: 'first question' }, session_id: '' },
        { type: 'user', message: { role: 'user', content: [{ type: 'text', text: 'second' }] }, session_id: '' },
        { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1' }] },
          session_id: '' }
      ].each
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [prompt_observer])

      Async do
        ClaudeAgentSDK.query(prompt: stream, options: options) { |_msg| nil }
      end.wait

      expect(prompts).to eq(['first question', 'second'])
    end

    it 'calls on_error before on_close and re-raises when the message stream dies' do
      msg = sample_assistant_message
      allow(query_handler).to receive(:receive_messages) do |&block|
        block.call(msg)
        raise ClaudeAgentSDK::ProcessError.new('Command failed', exit_code: 1)
      end
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer])

      expect do
        Async { ClaudeAgentSDK.query(prompt: 'test', options: options) { |_m| nil } }.wait
      end.to raise_error(ClaudeAgentSDK::ProcessError)

      expect(observer.errors.length).to eq(1)
      expect(observer.errors.first).to be_a(ClaudeAgentSDK::ProcessError)
      expect(observer.events).to eq(%i[message error close])
    end

    it 'calls on_error when the user block raises' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer])

      expect do
        Async do
          ClaudeAgentSDK.query(prompt: 'test', options: options) { |_m| raise 'user boom' }
        end.wait
      end.to raise_error(RuntimeError, 'user boom')

      expect(observer.errors.length).to eq(1)
      expect(observer.errors.first.message).to eq('user boom')
    end

    it 'does not call on_error on clean completion' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [observer])

      Async do
        ClaudeAgentSDK.query(prompt: 'test', options: options) { |_msg| nil }
      end.wait

      expect(observer.errors).to be_empty
    end

    it 'a raising on_error observer does not mask the original error' do
      bad_observer = Class.new do
        include ClaudeAgentSDK::Observer

        def on_error(_error)
          raise 'observer on_error crash'
        end
      end.new
      allow(query_handler).to receive(:receive_messages)
        .and_raise(ClaudeAgentSDK::ProcessError.new('Command failed', exit_code: 1))
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [bad_observer])

      expect do
        Async { ClaudeAgentSDK.query(prompt: 'test', options: options) { |_m| nil } }.wait
      end.to raise_error(ClaudeAgentSDK::ProcessError, /Command failed/)
    end

    it 'does not propagate observer errors to user block' do
      error_observer = Class.new do
        include ClaudeAgentSDK::Observer

        def on_message(_message)
          raise 'observer crash'
        end
      end.new

      user_messages = []
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [error_observer])

      Async do
        ClaudeAgentSDK.query(prompt: 'test', options: options) do |msg|
          user_messages << msg
        end
      end.wait

      expect(user_messages.length).to eq(2)
    end

    it 'does not propagate on_close errors' do
      error_observer = Class.new do
        include ClaudeAgentSDK::Observer

        def on_close
          raise 'close crash'
        end
      end.new

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(observers: [error_observer])

      expect do
        Async do
          ClaudeAgentSDK.query(prompt: 'test', options: options) { |_msg| nil }
        end.wait
      end.not_to raise_error
    end
  end
end
