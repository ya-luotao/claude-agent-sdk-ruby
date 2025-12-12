#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'json'

# Structured Outputs in the Ruby SDK
#
# Get validated JSON results from agent workflows. The Agent SDK supports
# structured outputs through JSON Schemas, ensuring your agents return data
# in exactly the format you need.
#
# WHEN TO USE STRUCTURED OUTPUTS:
# Use structured outputs when you need validated JSON after an agent completes
# a multi-turn workflow with tools (file searches, command execution, etc.).
#
# WHY USE STRUCTURED OUTPUTS:
# - Validated structure: Always receive valid JSON matching your schema
# - Simplified integration: No parsing or validation code needed
# - Type safety: Use with Ruby type checkers (Sorbet, dry-types) for safety
# - Clean separation: Define output requirements separately from task instructions
# - Tool autonomy: Agent chooses which tools to use while guaranteeing output format

puts "=" * 60
puts "=== Quick Start: Company Research ==="
puts "=" * 60
puts

# Define a JSON schema for company information
schema = {
  type: 'object',
  properties: {
    company_name: { type: 'string' },
    founded_year: { type: 'number' },
    headquarters: { type: 'string' }
  },
  required: ['company_name']
}

ClaudeAgentSDK.query(
  prompt: 'Research Anthropic and provide key company information',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(
    output_format: {
      type: 'json_schema',
      schema: schema
    }
  )
) do |message|
  if message.is_a?(ClaudeAgentSDK::ResultMessage) && message.structured_output
    puts "Structured output:"
    puts JSON.pretty_generate(message.structured_output)
    # { company_name: "Anthropic", founded_year: 2021, headquarters: "San Francisco, CA" }
  end
end

puts "\n" + "=" * 60
puts "=== Example: TODO Tracking Agent ==="
puts "=" * 60
puts
puts "Agent uses Grep to find TODOs, Bash to get git blame info\n\n"

# Define structure for TODO extraction
todo_schema = {
  type: 'object',
  properties: {
    todos: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          text: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'number' },
          author: { type: 'string' },
          date: { type: 'string' }
        },
        required: %w[text file line]
      }
    },
    total_count: { type: 'number' }
  },
  required: %w[todos total_count]
}

ClaudeAgentSDK.query(
  prompt: 'Find all TODO comments in this directory and identify who added them',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(
    output_format: {
      type: 'json_schema',
      schema: todo_schema
    }
  )
) do |message|
  if message.is_a?(ClaudeAgentSDK::ResultMessage) && message.structured_output
    data = message.structured_output
    puts "Found #{data[:total_count]} TODOs"
    data[:todos]&.each do |todo|
      puts "#{todo[:file]}:#{todo[:line]} - #{todo[:text]}"
      puts "  Added by #{todo[:author]} on #{todo[:date]}" if todo[:author]
    end
  end
end

puts "\n" + "=" * 60
puts "=== Example: Code Analysis with Nested Schema ==="
puts "=" * 60
puts

# More complex schema with nested objects and enums
analysis_schema = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: %w[low medium high] },
          description: { type: 'string' },
          file: { type: 'string' }
        },
        required: %w[severity description file]
      }
    },
    score: { type: 'number', minimum: 0, maximum: 100 }
  },
  required: %w[summary issues score]
}

ClaudeAgentSDK.query(
  prompt: 'Analyze the codebase for potential improvements',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(
    output_format: {
      type: 'json_schema',
      schema: analysis_schema
    }
  )
) do |message|
  if message.is_a?(ClaudeAgentSDK::ResultMessage) && message.structured_output
    data = message.structured_output
    puts "Score: #{data[:score]}/100"
    puts "Summary: #{data[:summary]}"
    puts "\nIssues found: #{data[:issues]&.length || 0}"
    data[:issues]&.each do |issue|
      puts "  [#{issue[:severity]&.upcase}] #{issue[:file]}: #{issue[:description]}"
    end
  end
end

puts "\n" + "=" * 60
puts "=== Error Handling ==="
puts "=" * 60
puts

# If the agent cannot produce valid output matching your schema,
# you'll receive an error result
ClaudeAgentSDK.query(
  prompt: 'What is 2+2?',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(
    output_format: {
      type: 'json_schema',
      schema: {
        type: 'object',
        properties: {
          answer: { type: 'string' }
        },
        required: ['answer']
      }
    }
  )
) do |message|
  if message.is_a?(ClaudeAgentSDK::ResultMessage)
    if message.subtype == 'success' && message.structured_output
      puts "Success: #{message.structured_output.inspect}"
    elsif message.subtype == 'error_max_structured_output_retries'
      puts "Error: Could not produce valid output"
    else
      puts "Result: #{message.subtype}"
      puts "Structured output: #{message.structured_output.inspect}" if message.structured_output
    end
  end
end

puts "\n" + "=" * 60
puts "=== Type-Safe Schemas with dry-struct (Optional) ==="
puts "=" * 60
puts <<~EXAMPLE

  For Ruby projects wanting type safety similar to Zod (TypeScript) or
  Pydantic (Python), consider using dry-struct:

  ```ruby
  require 'dry-struct'
  require 'dry-types'

  module Types
    include Dry.Types()
  end

  class Issue < Dry::Struct
    attribute :severity, Types::String.enum('low', 'medium', 'high')
    attribute :description, Types::String
    attribute :file, Types::String
  end

  class AnalysisResult < Dry::Struct
    attribute :summary, Types::String
    attribute :issues, Types::Array.of(Issue)
    attribute :score, Types::Integer.constrained(gteq: 0, lteq: 100)
  end

  # Use in query
  ClaudeAgentSDK.query(
    prompt: 'Analyze the codebase',
    options: ClaudeAgentSDK::ClaudeAgentOptions.new(
      output_format: {
        type: 'json_schema',
        schema: {
          type: 'object',
          properties: {
            summary: { type: 'string' },
            issues: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  severity: { type: 'string', enum: ['low', 'medium', 'high'] },
                  description: { type: 'string' },
                  file: { type: 'string' }
                },
                required: ['severity', 'description', 'file']
              }
            },
            score: { type: 'integer', minimum: 0, maximum: 100 }
          },
          required: ['summary', 'issues', 'score']
        }
      }
    )
  ) do |message|
    if message.is_a?(ClaudeAgentSDK::ResultMessage) && message.structured_output
      # Validate with dry-struct
      result = AnalysisResult.new(message.structured_output)
      puts "Score: \#{result.score}"
      result.issues.each { |i| puts "[\#{i.severity}] \#{i.description}" }
    end
  end
  ```

EXAMPLE

puts "=" * 60
puts "=== Tips ==="
puts "=" * 60
puts <<~TIPS

  1. SCHEMA ROOT: JSON schema root must be 'object' type.
     Wrap arrays in an object property.

  2. ACCESS DATA: Structured output is available in:
     - message.structured_output on ResultMessage

  3. KEYS ARE SYMBOLS: JSON parser uses symbolize_names: true,
     so access data with symbols: data[:name], not data['name']

  4. RAILS INTEGRATION: The SDK works in Rails applications.
     No special configuration needed.

  5. SUPPORTED FEATURES: All basic JSON Schema types supported:
     object, array, string, integer, number, boolean, null
     Also: enum, const, required, minimum, maximum, etc.

TIPS
