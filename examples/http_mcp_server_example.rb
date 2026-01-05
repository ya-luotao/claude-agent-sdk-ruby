#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Using HTTP-based MCP Servers
#
# This example demonstrates how to configure and use HTTP-based MCP servers
# with the Claude Agent SDK. HTTP MCP servers are useful for:
# - Connecting to remote tool services (APIs, databases, etc.)
# - Using shared MCP servers across multiple agents
# - Integrating with existing HTTP-based tooling infrastructure
#
# Supported MCP server types:
# - McpStdioServerConfig: Local subprocess servers
# - McpSSEServerConfig: Server-Sent Events servers
# - McpHttpServerConfig: HTTP/REST servers
# - McpSdkServerConfig: In-process SDK servers

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Configure multiple MCP servers
def build_mcp_servers
  servers = {}

  # HTTP-based MCP server (e.g., remote API toolbox)
  # This connects to a remote MCP server over HTTP
  servers['remote_api'] = ClaudeAgentSDK::McpHttpServerConfig.new(
    url: 'https://api.example.com/mcp',
    headers: {
      'Authorization' => "Bearer #{ENV['API_TOKEN'] || 'demo_token'}",
      'X-Request-ID' => SecureRandom.uuid
    }
  ).to_h

  # SSE-based MCP server (for real-time streaming tools)
  servers['streaming_tools'] = ClaudeAgentSDK::McpSSEServerConfig.new(
    url: 'https://sse.example.com/mcp/events',
    headers: {
      'Authorization' => "Bearer #{ENV['SSE_TOKEN'] || 'demo_token'}"
    }
  ).to_h

  # Stdio-based MCP server (local subprocess)
  # Useful for local tools or CLI-based services
  servers['local_tools'] = ClaudeAgentSDK::McpStdioServerConfig.new(
    command: 'npx',
    args: ['-y', '@anthropic/mcp-server-example'],
    env: { 'DEBUG' => 'true' }
  ).to_h

  servers
end

# Example: In-process SDK MCP server with custom tools
def build_sdk_mcp_server
  # Create custom tools
  weather_tool = ClaudeAgentSDK.create_tool(
    'get_weather',
    'Get current weather for a city',
    {
      type: 'object',
      properties: {
        city: {
          type: 'string',
          description: 'City name (e.g., "San Francisco")'
        },
        units: {
          type: 'string',
          enum: %w[celsius fahrenheit],
          description: 'Temperature units'
        }
      },
      required: ['city']
    }
  ) do |args|
    city = args[:city] || args['city']
    units = args[:units] || args['units'] || 'celsius'

    # Simulated weather data (would call real API in production)
    temp = rand(15..30)
    temp = (temp * 9 / 5) + 32 if units == 'fahrenheit'

    {
      city: city,
      temperature: temp,
      units: units,
      conditions: %w[sunny cloudy rainy].sample,
      humidity: rand(30..80)
    }.to_json
  end

  database_tool = ClaudeAgentSDK.create_tool(
    'query_database',
    'Execute a read-only database query',
    {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'SQL SELECT query to execute'
        },
        database: {
          type: 'string',
          enum: %w[users products orders],
          description: 'Database to query'
        }
      },
      required: %w[query database]
    }
  ) do |args|
    query = args[:query] || args['query']
    database = args[:database] || args['database']

    # Simulated query result (would execute real query in production)
    # IMPORTANT: Always validate and sanitize queries in production!
    if query.downcase.include?('select')
      {
        database: database,
        query: query,
        rows: [
          { id: 1, name: 'Example Row 1' },
          { id: 2, name: 'Example Row 2' }
        ],
        row_count: 2
      }.to_json
    else
      { error: 'Only SELECT queries are allowed' }.to_json
    end
  end

  # Create the SDK MCP server
  ClaudeAgentSDK.create_sdk_mcp_server(
    name: 'custom_tools',
    version: '1.0.0',
    tools: [weather_tool, database_tool]
  )
end

# Example: Agent with multiple MCP servers
class MultiToolAgent
  def initialize
    @sdk_server = build_sdk_mcp_server
  end

  def query(prompt)
    # Combine HTTP servers with SDK server
    mcp_servers = build_mcp_servers
    mcp_servers['custom_tools'] = ClaudeAgentSDK::McpSdkServerConfig.new(
      name: 'custom_tools',
      instance: @sdk_server
    ).to_h

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: {
        type: 'preset',
        preset: 'claude_code',
        append: <<~PROMPT
          You have access to multiple tool servers:

          1. remote_api - Remote API tools for external services
          2. streaming_tools - Real-time streaming tools
          3. local_tools - Local subprocess tools
          4. custom_tools - Custom Ruby-based tools:
             - get_weather: Get weather for a city
             - query_database: Query a database

          Use these tools to help answer questions.
        PROMPT
      },
      mcp_servers: mcp_servers,
      permission_mode: 'bypassPermissions',
      setting_sources: []
    )

    Async do
      client = ClaudeAgentSDK::Client.new(options: options)
      response = nil

      begin
        client.connect
        client.query(prompt)

        client.receive_response do |message|
          case message
          when ClaudeAgentSDK::AssistantMessage
            message.content.each do |block|
              case block
              when ClaudeAgentSDK::TextBlock
                puts "[Text] #{block.text}"
              when ClaudeAgentSDK::ToolUseBlock
                puts "[Tool Call] #{block.name}: #{block.input.to_json}"
              when ClaudeAgentSDK::ToolResultBlock
                puts "[Tool Result] #{block.content}"
              end
            end

          when ClaudeAgentSDK::ResultMessage
            response = message.result
            puts "\n[Complete] Cost: $#{message.total_cost_usd}"
          end
        end

        response

      ensure
        client.disconnect
      end
    end.wait
  end
end

# Demo: Using the multi-tool agent
if __FILE__ == $PROGRAM_NAME
  puts "=== HTTP MCP Server Example ===\n\n"

  puts "Note: This example uses simulated MCP servers."
  puts "In production, configure real server URLs and tokens.\n\n"

  agent = MultiToolAgent.new

  # Example 1: Weather query (uses custom SDK tool)
  puts "--- Query 1: Weather ---"
  puts "User: What's the weather in San Francisco?\n"
  agent.query("What's the weather in San Francisco? Use the get_weather tool.")

  puts "\n--- Query 2: Database ---"
  puts "User: How many users are in the database?\n"
  agent.query("Query the users database to count records. Use the query_database tool with 'SELECT COUNT(*) FROM users'.")

  puts "\n=== Example Complete ==="
  puts "\nMCP Server Types Available:"
  puts "  - McpHttpServerConfig: HTTP/REST servers"
  puts "  - McpSSEServerConfig: Server-Sent Events servers"
  puts "  - McpStdioServerConfig: Local subprocess servers"
  puts "  - McpSdkServerConfig: In-process Ruby servers"
end
