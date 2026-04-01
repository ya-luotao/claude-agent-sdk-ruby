# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK, '.query' do
  it 'passes entrypoint via transport env without mutating global ENV' do
    original_entrypoint = ENV['CLAUDE_CODE_ENTRYPOINT']
    ENV.delete('CLAUDE_CODE_ENTRYPOINT')

    captured_options = nil
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)
    allow(transport).to receive(:read_messages) # returns nil immediately

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages) # yields nothing

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |opts|
      captured_options = opts
      transport
    end
    allow(ClaudeAgentSDK::Query).to receive(:new).and_return(query_handler)

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(env: { 'EXTRA' => '1' })

    # query() calls Async do...end.wait internally; wrap in Async to prevent nested reactor issues.
    begin
      Async do
        described_class.query(prompt: 'hello', options: options) { |_message| nil }
      end.wait
    rescue StandardError
      # Ignore errors from mock transport — we're only testing options configuration
    end

    expect(captured_options).not_to be_nil
    # CLAUDE_CODE_ENTRYPOINT is now set as a default-if-absent by the transport,
    # not by query(). The caller's env should pass through without an override.
    expect(captured_options.env).not_to have_key('CLAUDE_CODE_ENTRYPOINT')
    expect(captured_options.env['EXTRA']).to eq('1')
    expect(options.env['CLAUDE_CODE_ENTRYPOINT']).to be_nil
    expect(ENV['CLAUDE_CODE_ENTRYPOINT']).to be_nil
  ensure
    if original_entrypoint.nil?
      ENV.delete('CLAUDE_CODE_ENTRYPOINT')
    else
      ENV['CLAUDE_CODE_ENTRYPOINT'] = original_entrypoint
    end
  end

  it 'passes hooks into the control protocol for one-shot queries' do
    hook_fn = ->(_input, _tool_use_id, _context) { {} }
    matcher = ClaudeAgentSDK::HookMatcher.new(matcher: 'Bash', hooks: [hook_fn], timeout: 30)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      hooks: { 'PreToolUse' => [matcher] }
    )

    writes = []
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write) { |payload| writes << JSON.parse(payload, symbolize_names: true) }

    captured_query_args = nil
    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
      captured_query_args = kwargs
      query_handler
    end

    Async do
      described_class.query(prompt: 'hello', options: options) { |_message| nil }
    end.wait

    expect(captured_query_args[:hooks]).to eq(
      'PreToolUse' => [
        {
          matcher: 'Bash',
          hooks: [hook_fn],
          timeout: 30
        }
      ]
    )
    expect(query_handler).to have_received(:wait_for_result_and_end_input)
    expect(writes.first[:session_id]).to eq('')
  end

  it 'passes nil hooks when all matcher lists are empty' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      hooks: { 'PreToolUse' => [] }
    )

    captured_query_args = nil
    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      wait_for_result_and_end_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new).and_return(transport)
    allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
      captured_query_args = kwargs
      query_handler
    end

    Async do
      described_class.query(prompt: 'hello', options: options) { |_message| nil }
    end.wait

    expect(captured_query_args[:hooks]).to be_nil
  end

  it 'configures can_use_tool for streaming one-shot queries' do
    callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)
    prompt = [ClaudeAgentSDK::Streaming.user_message('hello')].to_enum

    captured_options = nil
    captured_query_args = nil

    transport = instance_double(ClaudeAgentSDK::SubprocessCLITransport, connect: true, close: nil, end_input: nil)
    allow(transport).to receive(:write)

    query_handler = instance_double(
      ClaudeAgentSDK::Query,
      start: true,
      initialize_protocol: nil,
      stream_input: nil,
      close: nil
    )
    allow(query_handler).to receive(:receive_messages)

    allow(ClaudeAgentSDK::SubprocessCLITransport).to receive(:new) do |opts|
      captured_options = opts
      transport
    end
    allow(ClaudeAgentSDK::Query).to receive(:new) do |**kwargs|
      captured_query_args = kwargs
      query_handler
    end

    Async do
      described_class.query(prompt: prompt, options: options) { |_message| nil }
    end.wait

    expect(captured_options.permission_prompt_tool_name).to eq('stdio')
    expect(captured_query_args[:can_use_tool]).to eq(callback)
    expect(query_handler).to have_received(:stream_input).with(prompt)
  end

  it 'rejects string prompts when can_use_tool is configured' do
    callback = ->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new }
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)

    expect do
      described_class.query(prompt: 'hello', options: options) { |_message| nil }
    end.to raise_error(ArgumentError, /can_use_tool callback requires streaming mode/)
  end
end
