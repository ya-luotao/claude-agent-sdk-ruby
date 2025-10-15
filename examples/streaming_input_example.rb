#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'

# Example 1: Streaming input from an array of messages
def example_array_streaming
  puts "=" * 80
  puts "Example 1: Streaming Input from Array"
  puts "=" * 80
  puts

  messages = [
    "Hello! I'm going to ask you a few questions.",
    "What is 2 + 2?",
    "What is the capital of France?",
    "Thank you for your answers!"
  ]

  # Create a streaming enumerator from the array
  stream = ClaudeAgentSDK::Streaming.from_array(messages)

  # Configure options
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    max_turns: 10
  )

  # Query with streaming input
  ClaudeAgentSDK.query(prompt: stream, options: options) do |message|
    case message
    when ClaudeAgentSDK::AssistantMessage
      puts "\n[Assistant]:"
      message.content.each do |block|
        case block
        when ClaudeAgentSDK::TextBlock
          puts block.text
        when ClaudeAgentSDK::ThinkingBlock
          puts "[Thinking: #{block.thinking[0..100]}...]" if block.thinking
        end
      end
    when ClaudeAgentSDK::UserMessage
      content = message.content.is_a?(String) ? message.content : message.content.first&.text
      puts "\n[User]: #{content}"
    when ClaudeAgentSDK::ResultMessage
      puts "\n[Result]:"
      puts "  Turns: #{message.num_turns}"
      puts "  Cost: $#{message.total_cost_usd}" if message.total_cost_usd
    end
  end
end

# Example 2: Streaming input with dynamic generation
def example_dynamic_streaming
  puts "\n\n"
  puts "=" * 80
  puts "Example 2: Dynamic Streaming Input"
  puts "=" * 80
  puts

  # Create a stream that generates messages dynamically
  stream = Enumerator.new do |yielder|
    # First message
    yielder << ClaudeAgentSDK::Streaming.user_message(
      "I'm going to send you a series of math problems."
    )

    # Generate math problems dynamically
    3.times do |i|
      a = rand(1..10)
      b = rand(1..10)
      yielder << ClaudeAgentSDK::Streaming.user_message(
        "Problem #{i + 1}: What is #{a} + #{b}?"
      )
    end

    # Final message
    yielder << ClaudeAgentSDK::Streaming.user_message(
      "Great! Thank you for solving these problems."
    )
  end

  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    max_turns: 15
  )

  ClaudeAgentSDK.query(prompt: stream, options: options) do |message|
    case message
    when ClaudeAgentSDK::AssistantMessage
      message.content.each do |block|
        if block.is_a?(ClaudeAgentSDK::TextBlock)
          puts "[Assistant]: #{block.text}"
        end
      end
    when ClaudeAgentSDK::ResultMessage
      puts "\n[Completed in #{message.num_turns} turns]"
    end
  end
end

# Example 3: Streaming with session management
def example_session_streaming
  puts "\n\n"
  puts "=" * 80
  puts "Example 3: Streaming with Session IDs"
  puts "=" * 80
  puts

  # Create streams for different sessions
  stream = Enumerator.new do |yielder|
    # Session 1: Math questions
    yielder << ClaudeAgentSDK::Streaming.user_message(
      "What is 5 + 3?",
      session_id: 'math'
    )
    yielder << ClaudeAgentSDK::Streaming.user_message(
      "What is 10 * 2?",
      session_id: 'math'
    )

    # Session 2: General questions
    yielder << ClaudeAgentSDK::Streaming.user_message(
      "What is the capital of Japan?",
      session_id: 'geography'
    )
  end

  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    max_turns: 10
  )

  ClaudeAgentSDK.query(prompt: stream, options: options) do |message|
    case message
    when ClaudeAgentSDK::AssistantMessage
      session = message.instance_variable_get(:@parent_tool_use_id) || 'default'
      message.content.each do |block|
        if block.is_a?(ClaudeAgentSDK::TextBlock)
          puts "[Session #{session}] Assistant: #{block.text[0..80]}..."
        end
      end
    when ClaudeAgentSDK::ResultMessage
      puts "\n[All sessions completed]"
    end
  end
end

# Example 4: Custom enumerator with delays
def example_timed_streaming
  puts "\n\n"
  puts "=" * 80
  puts "Example 4: Streaming with Delays (simulating user input)"
  puts "=" * 80
  puts

  # Create a stream that simulates delayed user input
  stream = Enumerator.new do |yielder|
    messages = [
      "Let's have a conversation.",
      "Tell me a short joke.",
      "That's funny! Tell me another one."
    ]

    messages.each_with_index do |msg, i|
      yielder << ClaudeAgentSDK::Streaming.user_message(msg)
      puts "[Sent message #{i + 1}]"
      sleep 0.1 if i < messages.length - 1  # Small delay between messages
    end
  end

  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    max_turns: 10
  )

  ClaudeAgentSDK.query(prompt: stream, options: options) do |message|
    if message.is_a?(ClaudeAgentSDK::AssistantMessage)
      message.content.each do |block|
        puts "\n[Assistant]: #{block.text}" if block.is_a?(ClaudeAgentSDK::TextBlock)
      end
    end
  end
end

# Run examples
if __FILE__ == $PROGRAM_NAME
  begin
    puts "Claude Agent SDK - Streaming Input Examples"
    puts "==========================================="
    puts

    # Uncomment the examples you want to run:
    example_array_streaming
    # example_dynamic_streaming
    # example_session_streaming
    # example_timed_streaming

    puts "\n\nAll examples completed successfully!"
  rescue ClaudeAgentSDK::CLINotFoundError => e
    puts "Error: #{e.message}"
    puts "\nPlease install Claude Code to run these examples."
  rescue StandardError => e
    puts "Error: #{e.class} - #{e.message}"
    puts e.backtrace.first(5).join("\n")
  end
end
