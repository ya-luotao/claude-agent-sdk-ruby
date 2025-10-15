#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'
require 'json'

# Example demonstrating MCP Resources and Prompts

# Example 1: Create resources for configuration and data
def example_resources
  puts "=" * 80
  puts "Example 1: MCP Resources"
  puts "=" * 80
  puts

  # Create a configuration resource
  config_resource = ClaudeAgentSDK.create_resource(
    uri: 'config://app/settings',
    name: 'Application Settings',
    description: 'Current application configuration',
    mime_type: 'application/json'
  ) do
    config_data = {
      app_name: 'MyApp',
      version: '1.0.0',
      debug_mode: false,
      max_connections: 100
    }

    {
      contents: [{
        uri: 'config://app/settings',
        mimeType: 'application/json',
        text: JSON.pretty_generate(config_data)
      }]
    }
  end

  # Create a status resource
  status_resource = ClaudeAgentSDK.create_resource(
    uri: 'status://system',
    name: 'System Status',
    description: 'Current system status and metrics',
    mime_type: 'text/plain'
  ) do
    uptime = `uptime`.strip rescue 'N/A'
    memory = `free -h 2>/dev/null | grep Mem`.strip rescue 'N/A'

    status_text = <<~STATUS
      System Status Report
      ===================
      Uptime: #{uptime}
      Memory: #{memory}
      Ruby Version: #{RUBY_VERSION}
      Time: #{Time.now}
    STATUS

    {
      contents: [{
        uri: 'status://system',
        mimeType: 'text/plain',
        text: status_text
      }]
    }
  end

  # Create a data resource
  data_resource = ClaudeAgentSDK.create_resource(
    uri: 'data://users/count',
    name: 'User Count',
    description: 'Total number of users in the system'
  ) do
    # Simulate fetching from database
    user_count = 1234

    {
      contents: [{
        uri: 'data://users/count',
        mimeType: 'text/plain',
        text: user_count.to_s
      }]
    }
  end

  # Create server with resources
  server = ClaudeAgentSDK.create_sdk_mcp_server(
    name: 'app-resources',
    resources: [config_resource, status_resource, data_resource]
  )

  puts "Created MCP server with #{server[:instance].resources.length} resources:"
  server[:instance].list_resources.each do |res|
    puts "  - #{res[:name]} (#{res[:uri]})"
  end

  # Test resource reading
  puts "\nReading configuration resource:"
  config_data = server[:instance].read_resource('config://app/settings')
  puts config_data[:contents].first[:text]

  puts "\nResources can be accessed by Claude Code to get current data!"
end

# Example 2: Create prompts for common tasks
def example_prompts
  puts "\n\n"
  puts "=" * 80
  puts "Example 2: MCP Prompts"
  puts "=" * 80
  puts

  # Simple prompt without arguments
  code_review_prompt = ClaudeAgentSDK.create_prompt(
    name: 'code_review',
    description: 'Review code for best practices and suggest improvements'
  ) do |args|
    {
      messages: [
        {
          role: 'user',
          content: {
            type: 'text',
            text: 'Please review the following code for best practices, potential bugs, ' \
                  'and suggest improvements. Focus on readability, performance, and maintainability.'
          }
        }
      ]
    }
  end

  # Prompt with arguments
  git_commit_prompt = ClaudeAgentSDK.create_prompt(
    name: 'git_commit',
    description: 'Generate a git commit message',
    arguments: [
      { name: 'changes', description: 'Description of the changes made', required: true },
      { name: 'type', description: 'Type of commit (feat, fix, docs, etc.)', required: false }
    ]
  ) do |args|
    changes = args[:changes] || args['changes']
    commit_type = args[:type] || args['type'] || 'feat'

    {
      messages: [
        {
          role: 'user',
          content: {
            type: 'text',
            text: "Generate a concise git commit message for a '#{commit_type}' commit. " \
                  "Changes: #{changes}. " \
                  "Follow conventional commits format and keep the first line under 50 characters."
          }
        }
      ]
    }
  end

  # Documentation prompt
  doc_gen_prompt = ClaudeAgentSDK.create_prompt(
    name: 'generate_docs',
    description: 'Generate documentation for code',
    arguments: [
      { name: 'code', description: 'The code to document', required: true },
      { name: 'style', description: 'Documentation style (YARD, RDoc, etc.)', required: false }
    ]
  ) do |args|
    code = args[:code] || args['code']
    style = args[:style] || args['style'] || 'YARD'

    {
      messages: [
        {
          role: 'user',
          content: {
            type: 'text',
            text: "Generate comprehensive #{style} documentation for the following code. " \
                  "Include parameter descriptions, return values, examples, and any important notes.\n\n" \
                  "Code:\n#{code}"
          }
        }
      ]
    }
  end

  # Create server with prompts
  server = ClaudeAgentSDK.create_sdk_mcp_server(
    name: 'dev-prompts',
    prompts: [code_review_prompt, git_commit_prompt, doc_gen_prompt]
  )

  puts "Created MCP server with #{server[:instance].prompts.length} prompts:"
  server[:instance].list_prompts.each do |prompt|
    puts "  - #{prompt[:name]}: #{prompt[:description]}"
  end

  # Test prompt generation
  puts "\nGenerating git commit prompt with arguments:"
  commit_prompt = server[:instance].get_prompt('git_commit', { changes: 'Added new feature', type: 'feat' })
  puts "Prompt: #{commit_prompt[:messages].first[:content][:text][0..100]}..."

  puts "\nPrompts can be used by Claude Code to generate consistent responses!"
end

# Example 3: Complete server with tools, resources, and prompts
def example_complete_server
  puts "\n\n"
  puts "=" * 80
  puts "Example 3: Complete MCP Server (Tools + Resources + Prompts)"
  puts "=" * 80
  puts

  # Define a tool
  calculator_tool = ClaudeAgentSDK.create_tool(
    'calculate',
    'Perform a calculation',
    { expression: :string }
  ) do |args|
    begin
      result = eval(args[:expression]) # Note: eval is dangerous in production!
      { content: [{ type: 'text', text: "Result: #{result}" }] }
    rescue StandardError => e
      { content: [{ type: 'text', text: "Error: #{e.message}" }], is_error: true }
    end
  end

  # Define a resource
  help_resource = ClaudeAgentSDK.create_resource(
    uri: 'help://calculator',
    name: 'Calculator Help',
    description: 'Help documentation for the calculator'
  ) do
    help_text = <<~HELP
      Calculator Tool Help
      ===================

      The calculator tool can evaluate mathematical expressions.

      Examples:
      - 2 + 2
      - 10 * 5
      - (100 - 25) / 3
      - Math.sqrt(16)

      Note: Uses Ruby's eval, so any Ruby expression is valid.
    HELP

    {
      contents: [{
        uri: 'help://calculator',
        mimeType: 'text/plain',
        text: help_text
      }]
    }
  end

  # Define a prompt
  calc_prompt = ClaudeAgentSDK.create_prompt(
    name: 'solve_problem',
    description: 'Solve a mathematical problem',
    arguments: [
      { name: 'problem', description: 'The problem to solve', required: true }
    ]
  ) do |args|
    problem = args[:problem] || args['problem']

    {
      messages: [
        {
          role: 'user',
          content: {
            type: 'text',
            text: "Solve this mathematical problem step by step: #{problem}. " \
                  "Use the calculate tool to perform calculations."
          }
        }
      ]
    }
  end

  # Create complete server
  server = ClaudeAgentSDK.create_sdk_mcp_server(
    name: 'calculator-complete',
    version: '2.0.0',
    tools: [calculator_tool],
    resources: [help_resource],
    prompts: [calc_prompt]
  )

  puts "Created complete MCP server:"
  puts "  Name: #{server[:instance].name}"
  puts "  Version: #{server[:instance].version}"
  puts "  Tools: #{server[:instance].tools.length}"
  puts "  Resources: #{server[:instance].resources.length}"
  puts "  Prompts: #{server[:instance].prompts.length}"

  puts "\nThis server provides:"
  puts "  - Tools: Executable functions Claude can call"
  puts "  - Resources: Data sources Claude can read"
  puts "  - Prompts: Reusable prompt templates"

  # Test all capabilities
  puts "\nTesting tool:"
  result = server[:instance].call_tool('calculate', { expression: '2 + 2' })
  puts "  calculate('2 + 2') = #{result[:content].first[:text]}"

  puts "\nTesting resource:"
  help = server[:instance].read_resource('help://calculator')
  puts "  help resource (first 100 chars): #{help[:contents].first[:text][0..100]}..."

  puts "\nTesting prompt:"
  prompt = server[:instance].get_prompt('solve_problem', { problem: 'What is 15% of 80?' })
  puts "  solve_problem prompt (first 100 chars): #{prompt[:messages].first[:content][:text][0..100]}..."
end

# Run examples
if __FILE__ == $PROGRAM_NAME
  begin
    puts "Claude Agent SDK - MCP Resources and Prompts Examples"
    puts "=" * 80
    puts

    example_resources
    example_prompts
    example_complete_server

    puts "\n\n"
    puts "=" * 80
    puts "All examples completed successfully!"
    puts "=" * 80
  rescue StandardError => e
    puts "Error: #{e.class} - #{e.message}"
    puts e.backtrace.first(5).join("\n")
  end
end
