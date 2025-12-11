#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'json'

# Example: Using output_format for structured JSON output
# This feature allows you to specify a JSON schema and receive structured data
# that conforms to that schema in the result.
#
# output_format accepts two formats:
# 1. Direct schema: { type: 'object', properties: {...} }
# 2. Wrapped format (official SDK style): { type: 'json_schema', schema: {...} }

puts "=== Structured Output Example ==="
puts "Requesting structured data with a JSON schema\n\n"

# Define a JSON schema for the expected output
person_schema = {
  type: 'object',
  properties: {
    name: { type: 'string', description: 'Full name of the person' },
    age: { type: 'integer', description: 'Age in years' },
    occupation: { type: 'string', description: 'Current job or profession' },
    skills: {
      type: 'array',
      items: { type: 'string' },
      description: 'List of professional skills'
    },
    contact: {
      type: 'object',
      properties: {
        email: { type: 'string', format: 'email' },
        phone: { type: 'string' }
      }
    }
  },
  required: %w[name age occupation skills]
}

# Create options with output_format (using wrapped format like Python/TS SDKs)
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  output_format: {
    type: 'json_schema',
    schema: person_schema
  },
  max_turns: 1
)

# Query Claude and expect structured output
ClaudeAgentSDK.query(
  prompt: "Create a fictional software engineer profile with name, age, occupation, skills, and contact info.",
  options: options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    message.content.each do |block|
      puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\n--- Result ---"
    puts "Cost: $#{message.total_cost_usd}" if message.total_cost_usd
    puts "Turns: #{message.num_turns}"

    # Access the structured output
    if message.structured_output
      puts "\n--- Structured Output ---"
      puts JSON.pretty_generate(message.structured_output)

      # You can now work with the data programmatically
      data = message.structured_output
      puts "\nExtracted data:"
      puts "  Name: #{data['name']}"
      puts "  Age: #{data['age']}"
      puts "  Occupation: #{data['occupation']}"
      puts "  Skills: #{data['skills']&.join(', ')}"
    end
  end
end

puts "\n" + "=" * 50 + "\n"

# Example 2: Object with array property
# Note: JSON schema root must be 'object' type, so we wrap arrays in an object
puts "\n=== Example 2: Task List Schema ==="

tasks_schema = {
  type: 'object',
  properties: {
    tasks: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'integer' },
          title: { type: 'string' },
          priority: { type: 'string', enum: %w[low medium high] },
          estimated_hours: { type: 'number' }
        },
        required: %w[id title priority]
      }
    }
  },
  required: ['tasks']
}

options_tasks = ClaudeAgentSDK::ClaudeAgentOptions.new(
  output_format: {
    type: 'json_schema',
    schema: tasks_schema
  },
  max_turns: 1
)

ClaudeAgentSDK.query(
  prompt: "Generate a list of 3 tasks for building a simple web application.",
  options: options_tasks
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    message.content.each do |block|
      puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
    end
  when ClaudeAgentSDK::ResultMessage
    if message.structured_output && message.structured_output['tasks']
      puts "\n--- Task List (Structured) ---"
      message.structured_output['tasks'].each do |task|
        puts "  [#{task['priority']&.upcase}] ##{task['id']}: #{task['title']}"
        puts "    Estimated: #{task['estimated_hours']} hours" if task['estimated_hours']
      end
    end
  end
end
