#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'json'

# Example: Using output_format for structured JSON output
# This feature allows you to specify a JSON schema and receive structured data
# that conforms to that schema.
#
# The Claude CLI returns structured output via a ToolUseBlock named "StructuredOutput".
# The structured data is in the tool's input field, matching your schema's properties.
#
# output_format accepts two formats:
# 1. Direct schema: { type: 'object', properties: {...} }
# 2. Wrapped format (official SDK style): { type: 'json_schema', schema: {...} }

# Helper to extract structured output from messages
def extract_structured_output(message)
  return nil unless message.is_a?(ClaudeAgentSDK::AssistantMessage)

  message.content.each do |block|
    if block.is_a?(ClaudeAgentSDK::ToolUseBlock) && block.name == 'StructuredOutput'
      return block.input
    end
  end
  nil
end

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
        email: { type: 'string' },
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
  max_turns: 3
)

structured_data = nil

# Query Claude and expect structured output
ClaudeAgentSDK.query(
  prompt: "Create a fictional software engineer profile with name, age, occupation, skills, and contact info.",
  options: options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    # Check for structured output in tool use blocks
    data = extract_structured_output(message)
    if data
      structured_data = data
      puts "Received structured output!"
    else
      message.content.each do |block|
        puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
      end
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\n--- Result ---"
    puts "Cost: $#{message.total_cost_usd}" if message.total_cost_usd
    puts "Turns: #{message.num_turns}"
  end
end

# Display the structured output
if structured_data
  puts "\n--- Structured Output ---"
  puts JSON.pretty_generate(structured_data)

  # Note: Keys are symbols from JSON parser (symbolize_names: true)
  puts "\nExtracted data:"
  puts "  Name: #{structured_data[:name]}"
  puts "  Age: #{structured_data[:age]}"
  puts "  Occupation: #{structured_data[:occupation]}"
  puts "  Skills: #{structured_data[:skills]&.join(', ')}"
  if structured_data[:contact]
    puts "  Email: #{structured_data[:contact][:email]}"
    puts "  Phone: #{structured_data[:contact][:phone]}"
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
  max_turns: 3
)

tasks_data = nil

ClaudeAgentSDK.query(
  prompt: "Generate a list of 3 tasks for building a simple web application.",
  options: options_tasks
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    data = extract_structured_output(message)
    if data
      tasks_data = data
      puts "Received structured output!"
    else
      message.content.each do |block|
        puts "Claude: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
      end
    end
  when ClaudeAgentSDK::ResultMessage
    puts "\nCost: $#{message.total_cost_usd}" if message.total_cost_usd
  end
end

# Note: Keys are symbols from JSON parser (symbolize_names: true)
if tasks_data && tasks_data[:tasks]
  puts "\n--- Task List (Structured) ---"
  tasks_data[:tasks].each do |task|
    puts "  [#{task[:priority]&.upcase}] ##{task[:id]}: #{task[:title]}"
    puts "    Estimated: #{task[:estimated_hours]} hours" if task[:estimated_hours]
  end
end
