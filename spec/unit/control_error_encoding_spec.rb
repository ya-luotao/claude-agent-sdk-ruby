# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

# The process-exit cells of this file end their process, so each one runs in
# a child (spec/support/callback_exit_harness.rb): all of them in parallel,
# once, the first time an example asks for a result.
module EncodedExitChildren
  # [path, scheduling, kind]: an error control response (hook) and both
  # MCP-shaped answers, for every exit in CallbackExitHarness::ENCODED_EXITS.
  CELLS = %i[hook read_resource call_tool]
          .product(CallbackExitHarness::MODES, CallbackExitHarness::ENCODED_EXITS.keys).freeze

  def self.result(cell)
    results.fetch(cell)
  end

  def self.results
    @results ||= CELLS.zip(CELLS.map { |cell| Thread.new { run(cell) } }.map(&:value)).to_h
  end

  # Read as bytes: the answers carry non-ASCII text, and how a text-mode read
  # would tag it depends on the locale.
  def self.run(cell)
    lib_dir = File.expand_path('../../lib', __dir__)
    harness_file = File.expand_path('../support/callback_exit_harness.rb', __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', lib_dir, '-r', 'claude_agent_sdk', '-r', harness_file,
                                      '-e', 'CallbackExitHarness.main(ARGV)', *cell.map(&:to_s), binmode: true)
    [out.force_encoding(Encoding::UTF_8), err, status]
  end
end

# A callback's exception message need not be valid UTF-8: `byteslice` cuts a
# multibyte character, an error text embeds the raw bytes of a subprocess or
# an HTTP body, a driver reports in its own encoding. Building the error
# response from such a message raised JSON::GeneratorError — inside the
# rescue clause that was answering the request, where nothing catches it.
# The request was never answered, and on the process-exit path the
# GeneratorError also replaced the SystemExit that has to end the process.
# A process exit with valid text in an encoding that is not ASCII-compatible
# (UTF-16) failed one step earlier, with Encoding::CompatibilityError, when
# the exception's class name was put in front of the message.
RSpec.describe 'control error responses for messages that are not valid UTF-8' do
  # Records every frame the SDK writes.
  let(:transport_class) do
    Class.new(ClaudeAgentSDK::Transport) do
      attr_reader :frames

      def initialize
        super
        @frames = []
      end

      def write(data)
        @frames << JSON.parse(data)
      end
    end
  end

  # The frames written for one hook / can_use_tool request whose callback
  # raises +error+.
  def frames_for(path, mode, error)
    callback = ->(*) { raise error }
    transport = transport_class.new
    query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true,
                                      can_use_tool: callback, callback_scheduling: mode)
    query.instance_variable_set(:@hook_callbacks, { 'hook' => callback })
    Sync { query.send(:handle_control_request, CallbackExitHarness.control_request(path)) }
    transport.frames
  end

  def control_response(fields)
    { 'type' => 'control_response',
      'response' => { 'request_id' => 'req_fail', 'requestId' => 'req_fail' }.merge(fields) }
  end

  def error_response(text)
    control_response('subtype' => 'error', 'error' => text)
  end

  # label => [the message as raised, the text the CLI is told]
  unencodable = {
    'cut inside a multibyte character' => ['tool output: 日本語'.byteslice(0, 15), "tool output: \uFFFD"],
    'BINARY-tagged with bytes that are not UTF-8' => ["upstream replied: caf\xE9".b, "upstream replied: caf\uFFFD"],
    'US-ASCII-tagged with a high byte' => [(+"caf\xE9").force_encoding(Encoding::US_ASCII), "caf\uFFFD"],
    'invalid in its own non-UTF-8 encoding' => [(+"bad \x82").force_encoding(Encoding::Shift_JIS), "bad \uFFFD"],
    'in an encoding Ruby has no converter for' => [(+'no converter').force_encoding(Encoding::UTF_7), 'no converter']
  }
  # Text the SDK delivered before as well: it must arrive undamaged, i.e.
  # transcoded from its declared encoding rather than scrubbed as if UTF-8.
  encodable = {
    'BINARY-tagged holding valid UTF-8' => ['upstream replied: café'.b, 'upstream replied: café'],
    'valid ISO-8859-1' => [(+"caf\xE9").force_encoding(Encoding::ISO_8859_1), 'café'],
    'valid Shift_JIS' => ['テスト'.encode(Encoding::Shift_JIS), 'テスト']
  }

  %i[hook can_use_tool].each do |path|
    CallbackExitHarness::MODES.each do |mode|
      context "#{path} with #{mode} callback scheduling" do
        unencodable.each do |label, (raised, told)|
          it "answers once, replacing the bad bytes, when the message is #{label}" do
            expect(frames_for(path, mode, RuntimeError.new(raised))).to eq([error_response(told)])
          end
        end

        encodable.each do |label, (raised, told)|
          it "sends the text itself when the message is #{label}" do
            expect(frames_for(path, mode, RuntimeError.new(raised))).to eq([error_response(told)])
          end
        end
      end
    end
  end

  # The second line of defense: whatever makes JSON.generate reject the
  # response, the request is still answered.
  context 'when the response cannot be generated all the same' do
    # The first JSON.generate fails as it does for an unencodable String;
    # later calls run for real.
    def fail_first_generate
      attempts = 0
      allow(JSON).to receive(:generate).and_wrap_original do |original, *args, **options|
        attempts += 1
        raise JSON::GeneratorError, 'source sequence is illegal/malformed utf-8' if attempts == 1

        original.call(*args, **options)
      end
    end

    it 'answers a hook with a fixed ASCII text' do
      fail_first_generate

      frames = frames_for(:hook, :inline, RuntimeError.new('ordinary failure'))

      expect(frames).to eq([error_response('Control request failed; its error message could not be encoded as JSON')])
      expect(frames.first.dig('response', 'error')).to be_ascii_only
    end

    it 'answers an SDK MCP request with an error response when its in-band answer cannot be generated' do
      fail_first_generate
      transport = transport_class.new
      query = CallbackExitHarness.build_query(:read_resource, :inline, :not_implemented, transport)

      Sync { query.send(:handle_control_request, CallbackExitHarness.control_request(:read_resource)) }

      expect(transport.frames).to eq([error_response(CallbackExitHarness::FAILURE_KINDS.fetch(:not_implemented).last)])
    end
  end

  # Issue #119's promise, kept whatever the exit's message holds: the CLI is
  # answered, then the ORIGINAL exception ends the process. The answer is
  # the one an ordinary failure gets on each path — an error control response
  # (hook), a JSON-RPC internal error (resources/read) or an isError result
  # (tools/call) inside a successful control response.
  describe 'a process exit raised with such a message' do
    def responses(out)
      prefix = CallbackExitHarness::RESPONSE
      out.lines.map(&:chomp).select { |line| line.start_with?(prefix) }.map { |line| JSON.parse(line.delete_prefix(prefix)) }
    end

    def failure_response(path, message)
      mcp_response =
        case path
        when :call_tool then { 'result' => { 'content' => [{ 'type' => 'text', 'text' => message }], 'isError' => true } }
        when :read_resource then { 'error' => { 'code' => -32_603, 'message' => message } }
        else return error_response(message)
        end
      control_response('subtype' => 'success',
                       'response' => { 'mcp_response' => { 'jsonrpc' => '2.0', 'id' => 7 }.merge(mcp_response) })
    end

    messages = {
      exit_invalid_utf8: 'cut inside a multibyte character (the stray byte is replaced)',
      exit_utf16: 'valid UTF-16LE text (transcoded, so it stays readable)'
    }

    EncodedExitChildren::CELLS.each do |path, mode, kind|
      it "answers #{path} once (#{mode} scheduling), then exits with the original SystemExit: #{messages.fetch(kind)}" do
        out, err, status = EncodedExitChildren.result([path, mode, kind])
        exit_kind = CallbackExitHarness::ENCODED_EXITS.fetch(kind)

        expect(out).not_to include(CallbackExitHarness::SURVIVED)
        expect(status.exitstatus).to eq(exit_kind[:exitstatus]), "child: #{status.inspect}\n#{err}"
        expect(responses(out)).to eq([failure_response(path, exit_kind[:message])])
      end
    end

    # In-process from here on, so :inline and Interrupt only, the dispatch
    # inside `rescue Exception` (as in callback_process_exit_spec.rb): RSpec
    # does not rescue Interrupt, so a leak has to become an expectation.
    it 're-raises the very exception the callback raised, its message untouched' do
      original = Interrupt.new('arrêt demandé'.encode(Encoding::UTF_16LE))
      transport = transport_class.new
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true, callback_scheduling: :inline)
      query.instance_variable_set(:@hook_callbacks, { 'hook' => ->(*) { raise original } })

      raised = begin
        Sync { query.send(:handle_control_request, CallbackExitHarness.control_request(:hook)) }
        nil
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end

      # Compared without letting RSpec print the UTF-16 text on a failure.
      expect(raised.equal?(original)).to be(true), "expected the callback's own Interrupt back, got #{raised.class}"
      message = original.message
      expect([message.encoding, message.encode(Encoding::UTF_8)]).to eq([Encoding::UTF_16LE, 'arrêt demandé'])
      expect(transport.frames).to eq([error_response('Interrupt: arrêt demandé')])
    end
  end

  # Query puts the class name in front of the message itself, because the
  # message has to be normalized first. The format is the one
  # FiberBoundary.process_exit_message gives the carrier a callback_wrapper
  # sees; this keeps the two from drifting apart.
  describe 'the text a process exit is reported with' do
    def frames_for_exit(error)
      transport = transport_class.new
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true)
      query.send(:respond_to_process_exit, 'req_fail', CallbackExitHarness.control_request(:hook)[:request], error)
      transport.frames
    end

    [
      SystemExit.new(3, 'exit'), SystemExit.new(3, 'bye'), SystemExit.new(3, 'arrêt à 5 %'),
      Interrupt.new, Interrupt.new(''), SignalException.new('TERM')
    ].each do |error|
      it "is FiberBoundary.process_exit_message's for #{error.class} with the message #{error.message.inspect}" do
        expect(frames_for_exit(error)).to eq([error_response(ClaudeAgentSDK::FiberBoundary.process_exit_message(error))])
      end
    end

    it 'has the same form when the message had to be transcoded' do
      error = SystemExit.new(3, 'café'.encode(Encoding::UTF_16LE))

      expect(frames_for_exit(error)).to eq([error_response('SystemExit: café')])
    end
  end
end
