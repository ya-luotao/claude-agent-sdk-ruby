# frozen_string_literal: true

require 'spec_helper'
require 'async'

RSpec.describe 'Real Claude CLI Integration', :integration, :real_integration do
  before do
    skip 'Set RUN_REAL_INTEGRATION=1 to run real CLI integration tests' unless ENV['RUN_REAL_INTEGRATION'] == '1'
    skip 'Claude CLI is not available on PATH' unless system('command -v claude >/dev/null 2>&1')
    skip 'ANTHROPIC_API_KEY is required for real CLI integration tests' if ENV['ANTHROPIC_API_KEY'].to_s.empty?
  end

  def run_one_shot_query(prompt:, options:)
    seen_result = nil

    ClaudeAgentSDK.query(prompt: prompt, options: options) do |message|
      seen_result = message if message.is_a?(ClaudeAgentSDK::ResultMessage)
    end

    expect(seen_result).to be_a(ClaudeAgentSDK::ResultMessage)
    expect(seen_result.is_error).to eq(false)
    seen_result
  end

  it 'completes a minimal one-shot query through Claude CLI' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      max_turns: 1,
      max_budget_usd: 0.02,
      tools: []
    )

    run_one_shot_query(prompt: 'Reply with exactly: OK', options: options)
  end

  it 'invokes PreToolUse hooks for one-shot query() calls through Claude CLI' do
    hook_invocations = []
    hook_fn = lambda do |input, tool_use_id, _context|
      hook_invocations << {
        hook_event_name: input.hook_event_name,
        tool_name: input.tool_name,
        tool_use_id: input.tool_use_id || tool_use_id
      }
      {}
    end

    matcher = ClaudeAgentSDK::HookMatcher.new(
      matcher: 'Bash',
      hooks: [hook_fn]
    )

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code'),
      permission_mode: 'bypassPermissions',
      allowed_tools: ['Bash'],
      tools: ['Bash'],
      max_turns: 3,
      max_budget_usd: 0.05,
      hooks: { 'PreToolUse' => [matcher] }
    )

    run_one_shot_query(
      prompt: "Use the Bash tool exactly once to run: printf 'ruby-hook-test'. After the command completes, reply with exactly HOOK_OK.",
      options: options
    )

    expect(hook_invocations).not_to be_empty
    expect(hook_invocations.any? { |invocation| invocation[:tool_name] == 'Bash' }).to eq(true)
    expect(hook_invocations.any? { |invocation| invocation[:tool_use_id] }).to eq(true)
  end

  it 'invokes SDK MCP tools for one-shot query() calls through Claude CLI' do
    executions = []

    echo_tool = ClaudeAgentSDK.create_tool('echo', 'Echo back the provided text', { text: :string }) do |args|
      executions << args
      { content: [{ type: 'text', text: "Echo: #{args[:text]}" }] }
    end

    server = ClaudeAgentSDK.create_sdk_mcp_server(
      name: 'test',
      version: '1.0.0',
      tools: [echo_tool]
    )

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code'),
      permission_mode: 'bypassPermissions',
      max_turns: 3,
      max_budget_usd: 0.05,
      mcp_servers: { test: server },
      allowed_tools: ['mcp__test__echo']
    )

    run_one_shot_query(
      prompt: "Call the mcp__test__echo tool once with text 'ruby real cli mcp'. After the tool returns, reply with exactly MCP_OK.",
      options: options
    )

    expect(executions).not_to be_empty
    expect(executions.first[:text]).to eq('ruby real cli mcp')
  end

  it 'initializes Client and returns server info' do
    Async do
      client = ClaudeAgentSDK::Client.new
      begin
        client.connect
        info = client.get_server_info

        expect(info).to be_a(Hash)
        expect(info).not_to eq({})
      ensure
        client.disconnect
      end
    end.wait
  end
end
