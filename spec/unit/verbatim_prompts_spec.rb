# frozen_string_literal: true

require 'spec_helper'
require 'async'

# ClaudeAgentOptions#verbatim_prompts (Python #1269): every user message the
# SDK writes carries `client_composed: true`, so the CLI delivers it as
# written — no @path expansion, no slash-command dispatch.
RSpec.describe 'verbatim_prompts' do
  def user_hash(content = 'hi @/etc/hosts')
    { type: 'user', message: { role: 'user', content: content }, parent_tool_use_id: nil, session_id: 'default' }
  end

  def parsed(line)
    JSON.parse(line, symbolize_names: true)
  end

  describe ClaudeAgentSDK::ClaudeAgentOptions do
    it 'defaults to false' do
      expect(described_class.new.verbatim_prompts).to be(false)
      expect(described_class.new.verbatim_prompts?).to be(false)
    end

    it 'coerces to a Boolean and accepts the camelCase spelling' do
      expect(described_class.new(verbatim_prompts: 1).verbatim_prompts).to be(true)
      expect(described_class.new('verbatimPrompts' => true).verbatim_prompts?).to be(true)
    end

    it 'is not sent to the CLI as a flag' do
      command = ClaudeAgentSDK::CommandBuilder.new('/usr/bin/claude', described_class.new(verbatim_prompts: true)).build

      expect(command.join(' ')).not_to match(/verbatim|client.composed/i)
    end
  end

  describe 'Query.stamp_user_message' do
    let(:query_class) { ClaudeAgentSDK::Query }

    it 'returns the message itself when the option is off' do
      message = user_hash

      expect(query_class.stamp_user_message(message, false)).to equal(message)
    end

    it 'returns a marked copy and never mutates the caller Hash' do
      message = user_hash
      stamped = query_class.stamp_user_message(message, true)

      expect(stamped).to include(client_composed: true)
      expect(message).not_to have_key(:client_composed)
    end

    it 'overwrites a caller-supplied value under either key spelling, emitting the key once' do
      message = user_hash.merge(client_composed: false, 'client_composed' => false)
      line = query_class.serialize_user_message(message, true)

      expect(line.scan('client_composed').length).to eq(1)
      expect(parsed(line)[:client_composed]).to be(true)
    end

    it 'parses, marks and re-serializes a JSONL String' do
      line = query_class.serialize_user_message("#{JSON.generate(user_hash)}\n", true)

      expect(parsed(line)).to include(client_composed: true, type: 'user')
    end

    it 'passes a JSONL String through untouched when the option is off' do
      jsonl = JSON.generate(user_hash)

      expect(query_class.serialize_user_message(jsonl, false)).to equal(jsonl)
    end

    it 'fails closed on a String that is not one JSON object' do
      expect { query_class.stamp_user_message('not json', true) }.to raise_error(ArgumentError, /one JSON object/)
      expect { query_class.stamp_user_message('[1, 2]', true) }.to raise_error(ArgumentError, /got Array/)
      two_lines = "#{JSON.generate(user_hash)}\n#{JSON.generate(user_hash)}"
      expect { query_class.stamp_user_message(two_lines, true) }.to raise_error(ArgumentError)
    end
  end

  describe 'Query#stream_input' do
    def stream_writes(enabled, items)
      writes = []
      transport = mock_transport
      allow(transport).to receive(:write) { |data| writes << data }
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true, verbatim_prompts: enabled)
      allow(query).to receive(:warn)
      Async { query.stream_input(items) }.wait
      [writes, query]
    end

    it 'marks every streamed message when the option is on' do
      writes, = stream_writes(true, [user_hash('one'), JSON.generate(user_hash('two'))])

      expect(writes.map { |w| parsed(w)[:client_composed] }).to eq([true, true])
    end

    it 'leaves streamed messages untouched by default' do
      writes, = stream_writes(false, [user_hash('one'), user_hash('two').merge(client_composed: true)])

      expect(writes.map { |w| parsed(w)[:client_composed] }).to eq([nil, true])
    end

    it 'does not mutate the caller message Hashes' do
      message = user_hash
      stream_writes(true, [message])

      expect(message).not_to have_key(:client_composed)
    end

    it 'never writes an unmarkable String unmarked' do
      writes, query = stream_writes(true, ['not json'])

      expect(writes).to be_empty
      expect(query).to have_received(:warn).with(/one JSON object/)
    end
  end

  describe 'ClaudeAgentSDK.query' do
    def run_query(enabled, prompt)
      writes = []
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
      allow(transport).to receive(:write) { |data| writes << data }
      query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: nil,
                                                             wait_for_result_and_end_input: nil, close: nil)
      allow(query_handler).to receive(:receive_messages)
      allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
      allow(query_handler).to receive(:stream_input)
      captured = nil
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        captured = kwargs
        query_handler
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(verbatim_prompts: enabled)
      Async { ClaudeAgentSDK.query(prompt: prompt, options: options) { |_m| nil } }.wait
      [writes, captured]
    end

    [true, false].each do |enabled|
      it "marks a String prompt only when the option is on (#{enabled})" do
        writes, = run_query(enabled, 'hi @/etc/hosts')

        expect(writes.length).to eq(1)
        expect(parsed(writes.first)[:client_composed]).to(enabled ? be(true) : be_nil)
      end

      it "hands the option to the Query that streams Enumerable prompts (#{enabled})" do
        _, captured = run_query(enabled, [user_hash].each)

        expect(captured[:verbatim_prompts]).to be(enabled)
      end
    end
  end

  describe ClaudeAgentSDK::Client do
    def connected_client(enabled, prompt = nil)
      writes = []
      transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true)
      allow(transport).to receive(:write) { |data| writes << data }
      query_handler = instance_double(ClaudeAgentSDK::Query, start: true, initialize_protocol: true)
      allow(query_handler).to receive(:spawn_task) { |&blk| blk.call }
      allow(query_handler).to receive(:stream_input)
      captured = nil
      allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
      allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
        captured = kwargs
        query_handler
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(verbatim_prompts: enabled)
      client = described_class.new(options: options)
      client.connect(prompt)
      [client, writes, captured, options]
    end

    [true, false].each do |enabled|
      expectation = enabled ? true : nil

      it "marks a connect-time String prompt when enabled (#{enabled})" do
        _, writes, = connected_client(enabled, 'hi')

        expect(parsed(writes.first)[:client_composed]).to eq(expectation)
      end

      it "hands the option to the Query for a connect-time Enumerable prompt (#{enabled})" do
        _, _, captured = connected_client(enabled, [user_hash].each)

        expect(captured[:verbatim_prompts]).to be(enabled)
      end

      it "marks Client#query String prompts when enabled (#{enabled})" do
        client, writes, = connected_client(enabled)
        client.query('hi')

        expect(parsed(writes.last)[:client_composed]).to eq(expectation)
      end

      it "marks Client#query streamed Hashes and JSONL Strings when enabled (#{enabled})" do
        client, writes, = connected_client(enabled)
        client.query([user_hash('one'), JSON.generate(user_hash('two'))])

        expect(writes.map { |w| parsed(w)[:client_composed] }).to eq([expectation, expectation])
      end
    end

    it 'captures the option at connect' do
      client, writes, _, options = connected_client(false)
      options.verbatim_prompts = true
      client.query('hi')

      expect(parsed(writes.last)).not_to have_key(:client_composed)
    end

    it 'raises for a streamed String it cannot mark, before writing it' do
      client, writes, = connected_client(true)

      expect { client.query(['not json']) }.to raise_error(ArgumentError, /one JSON object/)
      expect(writes).to be_empty
    end
  end

  describe 'older-CLI warning' do
    around do |example|
      previous = ENV.fetch('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK', nil)
      ENV.delete('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK')
      example.run
    ensure
      previous ? ENV['CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'] = previous : ENV.delete('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK')
    end

    def version_probe(output)
      stdin_r, stdin_w = IO.pipe
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      out_w.write(output)
      [out_w, err_w, stdin_r].each(&:close)
      [stdin_w, out_r, err_r, instance_double(Process::Waiter, alive?: false, pid: 4242)]
    end

    def check(version, enabled)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude', verbatim_prompts: enabled)
      allow(Open3).to receive(:popen3).and_return(version_probe("#{version} (Claude Code)\n"))
      ClaudeAgentSDK::SubprocessCLITransport.new('hi', options).check_claude_version
    end

    %w[2.1.247 2.0.0].each do |version|
      it "warns when the CLI (#{version}) predates client_composed" do
        expect { check(version, true) }.to output(/verbatim_prompts is enabled.*#{Regexp.escape(version)}.*2\.1\.248/m).to_stderr
      end
    end

    %w[2.1.248 2.1.285].each do |version|
      it "does not warn when the CLI (#{version}) supports client_composed" do
        expect { check(version, true) }.not_to output.to_stderr
      end
    end

    it 'does not warn when the option is off' do
      expect { check('2.1.247', false) }.not_to output.to_stderr
    end
  end
end
