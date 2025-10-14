# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Query Integration', :integration do
  # These integration tests demonstrate how the components work together
  # They don't actually connect to Claude Code CLI (would require it to be installed)
  # but show the expected flow

  describe 'ClaudeAgentSDK.query' do
    it 'has the correct method signature' do
      expect(ClaudeAgentSDK).to respond_to(:query)
    end

    it 'requires a prompt parameter' do
      # We can't actually test this without mocking heavily,
      # but we can verify the method exists
      expect { ClaudeAgentSDK.method(:query) }.not_to raise_error
    end

    # Note: Actual integration tests would require Claude Code CLI to be installed
    # and would be marked with :integration tag to be skipped in CI
  end

  describe 'ClaudeAgentSDK::Client' do
    it 'can be instantiated' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new
      client = ClaudeAgentSDK::Client.new(options: options)

      expect(client).to be_a(ClaudeAgentSDK::Client)
      expect(client).to respond_to(:connect)
      expect(client).to respond_to(:query)
      expect(client).to respond_to(:receive_messages)
      expect(client).to respond_to(:disconnect)
    end

    it 'has interrupt capability' do
      client = ClaudeAgentSDK::Client.new
      expect(client).to respond_to(:interrupt)
    end

    it 'can change permission mode' do
      client = ClaudeAgentSDK::Client.new
      expect(client).to respond_to(:set_permission_mode)
    end

    it 'can change model' do
      client = ClaudeAgentSDK::Client.new
      expect(client).to respond_to(:set_model)
    end

    it 'can get server info' do
      client = ClaudeAgentSDK::Client.new
      expect(client).to respond_to(:server_info)
    end
  end

  describe 'SDK MCP Server Integration' do
    it 'creates a working calculator server' do
      add_tool = ClaudeAgentSDK.create_tool('add', 'Add numbers', { a: :number, b: :number }) do |args|
        result = args[:a] + args[:b]
        { content: [{ type: 'text', text: "Result: #{result}" }] }
      end

      server_config = ClaudeAgentSDK.create_sdk_mcp_server(
        name: 'calculator',
        tools: [add_tool]
      )

      expect(server_config[:type]).to eq('sdk')
      expect(server_config[:instance]).to be_a(ClaudeAgentSDK::SdkMcpServer)

      # Verify the server works
      server = server_config[:instance]
      result = server.call_tool('add', { a: 10, b: 20 })
      expect(result[:content].first[:text]).to eq('Result: 30')
    end

    it 'can be used with ClaudeAgentOptions' do
      tool = ClaudeAgentSDK.create_tool('test', 'Test', {}) { |_| { content: [] } }
      server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'test', tools: [tool])

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        mcp_servers: { test: server },
        allowed_tools: ['mcp__test__test']
      )

      expect(options.mcp_servers[:test]).to eq(server)
      expect(options.allowed_tools).to include('mcp__test__test')
    end
  end

  describe 'Hook Integration' do
    it 'accepts hook configuration' do
      hook_fn = lambda do |input, tool_use_id, context|
        { hookSpecificOutput: { hookEventName: 'PreToolUse' } }
      end

      matcher = ClaudeAgentSDK::HookMatcher.new(
        matcher: 'Bash',
        hooks: [hook_fn]
      )

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        hooks: { 'PreToolUse' => [matcher] }
      )

      expect(options.hooks).to have_key('PreToolUse')
      expect(options.hooks['PreToolUse'].first).to eq(matcher)
    end
  end

  describe 'Permission Callback Integration' do
    it 'accepts permission callback' do
      callback = lambda do |tool_name, input, context|
        ClaudeAgentSDK::PermissionResultAllow.new
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        can_use_tool: callback
      )

      expect(options.can_use_tool).to eq(callback)

      # Test the callback works
      result = callback.call('Read', {}, nil)
      expect(result).to be_a(ClaudeAgentSDK::PermissionResultAllow)
    end
  end

  describe 'End-to-end workflow simulation' do
    it 'demonstrates the expected flow' do
      # 1. Create tools
      add_tool = ClaudeAgentSDK.create_tool('add', 'Add', { a: :number, b: :number }) do |args|
        { content: [{ type: 'text', text: (args[:a] + args[:b]).to_s }] }
      end

      # 2. Create server
      server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: [add_tool])

      # 3. Configure options with hooks and permissions
      permission_cb = lambda do |tool_name, _input, _context|
        tool_name == 'Read' ?
          ClaudeAgentSDK::PermissionResultAllow.new :
          ClaudeAgentSDK::PermissionResultDeny.new(message: 'Not allowed')
      end

      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        mcp_servers: { calc: server },
        allowed_tools: ['mcp__calc__add', 'Read'],
        can_use_tool: permission_cb,
        max_turns: 5
      )

      # 4. Verify configuration
      expect(options.mcp_servers[:calc]).to eq(server)
      expect(options.can_use_tool).to eq(permission_cb)

      # 5. Test permission callback
      result = permission_cb.call('Read', {}, nil)
      expect(result.behavior).to eq('allow')

      result = permission_cb.call('Write', {}, nil)
      expect(result.behavior).to eq('deny')

      # 6. Test tool execution
      calc_result = server[:instance].call_tool('add', { a: 5, b: 7 })
      expect(calc_result[:content].first[:text]).to eq('12')
    end
  end
end
