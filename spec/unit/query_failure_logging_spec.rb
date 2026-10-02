# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'tempfile'

# query() runs its body in a task and waits for it. A failure of that task is
# raised to the caller by the wait, so it is a handled failure: Async must not
# also log it as "Task may have ended with unhandled exception." (a warn line
# carrying the message and a backtrace, on stderr, even when the application
# rescued the error). Outside a reactor the task has always finished before
# anyone waits for it, which is exactly the case Async logs.
RSpec.describe ClaudeAgentSDK, 'failures of query() / ask()' do
  # Queue-backed stand-in for the CLI. +connect_error+ makes #connect raise;
  # +on_user_message+ scripts what the CLI does with the prompt.
  let(:transport_class) do
    Class.new do
      def initialize(connect_error: nil, on_user_message: nil)
        @connect_error = connect_error
        @on_user_message = on_user_message
        @stdout = Thread::Queue.new
      end

      def connect
        raise @connect_error if @connect_error
      end

      def ready?
        true
      end

      def end_input
        @stdout << :eof # the CLI exits once stdin is closed
      end

      def close
        @stdout << :eof
      end

      def write(line)
        frame = JSON.parse(line, symbolize_names: true)
        if frame[:type] == 'control_request' && frame.dig(:request, :subtype) == 'initialize'
          send_frame(type: 'control_response',
                     response: { subtype: 'success', request_id: frame[:request_id],
                                 response: { commands: [], agents: [], output_style: 'default', models: [],
                                             pid: 4242, session_state: 'idle', capabilities: [] },
                                 pending_permission_requests: [], pending_user_dialog_requests: [] })
        elsif frame[:type] == 'user'
          @on_user_message&.call(self)
        end
      end

      def send_frame(frame)
        @stdout << frame
      end

      # What SubprocessCLITransport#read_messages raises at EOF when the CLI
      # exited non-zero.
      def crash(exit_code:)
        @stdout << ClaudeAgentSDK::ProcessError.new("Command failed with exit code #{exit_code}",
                                                    exit_code: exit_code, stderr: 'boom')
      end

      def read_messages
        loop do
          item = @stdout.pop
          break if item == :eof
          raise item if item.is_a?(Exception)

          yield item
        end
      end
    end
  end

  let(:unhandled_task_warning) { 'Task may have ended with unhandled exception' }
  let(:connect_error) { ClaudeAgentSDK::CLIConnectionError.new('Failed to start Claude Code: no such file') }
  let(:session_id) { 'c0ffee00-0000-4000-8000-000000000003' }

  let(:answers_the_prompt) do
    lambda do |cli|
      cli.send_frame(type: 'assistant', parent_tool_use_id: nil, session_id: session_id,
                     message: { id: 'msg_01', type: 'message', role: 'assistant',
                                model: 'claude-haiku-4-5-20251001', content: [{ type: 'text', text: 'Four.' }],
                                stop_reason: 'end_turn', usage: { input_tokens: 10, output_tokens: 3 } })
      cli.send_frame(sample_result_message.merge(session_id: session_id, result: 'Four.',
                                                 stop_reason: 'end_turn', terminal_reason: 'completed'))
    end
  end

  let(:crashes_on_the_prompt) { ->(cli) { cli.crash(exit_code: 1) } }

  # Runs the block with file descriptor 2 pointed at a file and returns what
  # was written to it. spec_helper has bound the console logger (through
  # which Async warns) to the real $stderr object, so swapping $stderr for a
  # StringIO would capture nothing; redirecting its descriptor captures every
  # writer, on every console version.
  def stderr_during
    log = Tempfile.new('query-failure-log')
    original = $stderr.dup
    $stderr.reopen(log)
    begin
      yield
    ensure
      $stderr.flush
      $stderr.reopen(original)
      original.close
    end
    File.read(log.path)
  ensure
    log&.close!
  end

  # The block must raise +error_class+ to its caller, as an application that
  # rescues it would see, without Async reporting the same failure itself.
  def expect_handled_failure(error_class, message)
    raised = nil
    log = stderr_during do
      yield
    rescue StandardError => e
      raised = e
    end

    aggregate_failures do
      expect(raised).to be_a(error_class)
      expect(raised&.message).to match(message)
      expect(log).not_to include(unhandled_task_warning)
    end
  end

  context 'when called from plain synchronous code' do
    it 'raises a connect failure to the caller and logs nothing as unhandled' do
      transport = transport_class.new(connect_error: connect_error)

      expect_handled_failure(ClaudeAgentSDK::CLIConnectionError, /Failed to start Claude Code/) do
        described_class.query(prompt: 'What is 2 + 2?', transport: transport) { |_message| nil }
      end
    end

    it 'raises a CLI crash to the caller and logs nothing as unhandled' do
      transport = transport_class.new(on_user_message: crashes_on_the_prompt)

      expect_handled_failure(ClaudeAgentSDK::ProcessError, /exit code 1/) do
        described_class.query(prompt: 'What is 2 + 2?', transport: transport) { |_message| nil }
      end
    end

    it "raises the error of the caller's own block and logs nothing as unhandled" do
      transport = transport_class.new(on_user_message: answers_the_prompt)

      expect_handled_failure(ArgumentError, /my block failed/) do
        described_class.query(prompt: 'What is 2 + 2?', transport: transport) { raise ArgumentError, 'my block failed' }
      end
    end

    it 'raises from ask() and logs nothing as unhandled' do
      transport = transport_class.new(on_user_message: crashes_on_the_prompt)

      expect_handled_failure(ClaudeAgentSDK::ProcessError, /exit code 1/) do
        described_class.ask('What is 2 + 2?', transport: transport)
      end
    end
  end

  context 'when called inside an existing reactor' do
    it 'raises a connect failure to the caller and logs nothing as unhandled' do
      transport = transport_class.new(connect_error: connect_error)

      expect_handled_failure(ClaudeAgentSDK::CLIConnectionError, /Failed to start Claude Code/) do
        Sync { described_class.query(prompt: 'What is 2 + 2?', transport: transport) { |_message| nil } }
      end
    end
  end

  describe 'a successful call' do
    def break_at_the_result(transport)
      described_class.query(prompt: 'What is 2 + 2?', transport: transport) do |message|
        break :stopped_at_the_result if message.is_a?(ClaudeAgentSDK::ResultMessage)
      end
    end

    it 'still returns the final ResultMessage from ask()' do
      result = described_class.ask('What is 2 + 2?', transport: transport_class.new(on_user_message: answers_the_prompt))

      expect(result).to be_a(ClaudeAgentSDK::ResultMessage)
      expect(result.result).to eq('Four.')
    end

    it "still returns the block's break value from query(), outside and inside a reactor" do
      outside = break_at_the_result(transport_class.new(on_user_message: answers_the_prompt))
      inside = Sync { break_at_the_result(transport_class.new(on_user_message: answers_the_prompt)) }

      expect([outside, inside]).to eq(%i[stopped_at_the_result stopped_at_the_result])
    end
  end
end
