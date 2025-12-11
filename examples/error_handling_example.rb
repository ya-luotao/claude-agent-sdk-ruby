#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'claude_agent_sdk'
require 'async'

# Example: Handling errors with AssistantMessage.error
# The error field can contain values like:
# - authentication_failed: API key or auth issue
# - billing_error: Account billing problem
# - rate_limit: Too many requests
# - invalid_request: Malformed request
# - server_error: Claude server issue
# - unknown: Unclassified error

puts "=== Error Handling Example ==="
puts "Demonstrating AssistantMessage.error field handling\n\n"

# Helper to display error information
def display_error(error_type)
  case error_type
  when 'authentication_failed'
    puts "  -> Authentication failed. Check your API key."
    puts "     Action: Verify ANTHROPIC_API_KEY environment variable"
  when 'billing_error'
    puts "  -> Billing error. Check your account status."
    puts "     Action: Visit console.anthropic.com to check billing"
  when 'rate_limit'
    puts "  -> Rate limited. Too many requests."
    puts "     Action: Implement exponential backoff and retry"
  when 'invalid_request'
    puts "  -> Invalid request format."
    puts "     Action: Check request parameters"
  when 'server_error'
    puts "  -> Claude server error."
    puts "     Action: Retry after a short delay"
  when 'unknown'
    puts "  -> Unknown error occurred."
    puts "     Action: Check logs for details"
  else
    puts "  -> Unhandled error type: #{error_type}"
  end
end

# Example 1: Basic error checking
puts "--- Example 1: Basic Error Checking ---"

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  max_turns: 1
)

ClaudeAgentSDK.query(
  prompt: "Hello, how are you?",
  options: options
) do |message|
  case message
  when ClaudeAgentSDK::AssistantMessage
    if message.error
      puts "Error detected: #{message.error}"
      display_error(message.error)
    else
      message.content.each do |block|
        puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
      end
    end
  when ClaudeAgentSDK::ResultMessage
    if message.is_error
      puts "\nResult indicates error occurred"
    else
      puts "\nCompleted successfully"
    end
  end
end

puts "\n" + "=" * 50 + "\n"

# Example 2: Error handling with retry logic
puts "\n--- Example 2: Error Handling with Retry ---"

def query_with_retry(prompt, max_retries: 3, base_delay: 1)
  retries = 0
  success = false

  while retries < max_retries && !success
    puts "Attempt #{retries + 1}/#{max_retries}..."

    ClaudeAgentSDK.query(prompt: prompt) do |message|
      case message
      when ClaudeAgentSDK::AssistantMessage
        if message.error
          case message.error
          when 'rate_limit'
            delay = base_delay * (2**retries)
            puts "Rate limited. Waiting #{delay}s before retry..."
            sleep(delay)
            retries += 1
          when 'server_error'
            delay = base_delay * (2**retries)
            puts "Server error. Waiting #{delay}s before retry..."
            sleep(delay)
            retries += 1
          when 'authentication_failed', 'billing_error'
            puts "Non-retryable error: #{message.error}"
            display_error(message.error)
            return false
          else
            puts "Error: #{message.error}"
            retries += 1
          end
        else
          message.content.each do |block|
            puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
          end
        end
      when ClaudeAgentSDK::ResultMessage
        success = !message.is_error
      end
    end
  end

  success
end

result = query_with_retry("What is 1 + 1?")
puts result ? "Query succeeded!" : "Query failed after retries"

puts "\n" + "=" * 50 + "\n"

# Example 3: Client with comprehensive error handling
puts "\n--- Example 3: Client with Comprehensive Error Handling ---"

Async do
  client = ClaudeAgentSDK::Client.new

  begin
    puts "Connecting..."
    client.connect
    puts "Connected!\n"

    queries = [
      "What is Ruby?",
      "What is Python?",
      "What is JavaScript?"
    ]

    queries.each_with_index do |query, idx|
      puts "\n--- Query #{idx + 1}: #{query} ---"

      begin
        client.query(query)

        client.receive_response do |msg|
          case msg
          when ClaudeAgentSDK::AssistantMessage
            if msg.error
              puts "Error in response: #{msg.error}"
              display_error(msg.error)

              # Decide whether to continue based on error type
              case msg.error
              when 'authentication_failed', 'billing_error'
                puts "Fatal error - stopping further queries"
                raise "Fatal API error: #{msg.error}"
              when 'rate_limit'
                puts "Will retry after delay..."
                sleep(2)
              end
            else
              msg.content.each do |block|
                puts block.text if block.is_a?(ClaudeAgentSDK::TextBlock)
              end
            end
          when ClaudeAgentSDK::ResultMessage
            if msg.is_error
              puts "Query #{idx + 1} completed with error"
            else
              puts "Query #{idx + 1} completed successfully"
              puts "Cost: $#{msg.total_cost_usd}" if msg.total_cost_usd
            end
          end
        end
      rescue StandardError => e
        puts "Exception during query: #{e.message}"
        break
      end
    end

  rescue StandardError => e
    puts "Client error: #{e.message}"
  ensure
    puts "\nDisconnecting..."
    client.disconnect
    puts "Done!"
  end
end.wait

puts "\n" + "=" * 50 + "\n"

# Example 4: Error type constants reference
puts "\n--- Error Type Reference ---"
puts "Available error types (from ASSISTANT_MESSAGE_ERRORS):"
ClaudeAgentSDK::ASSISTANT_MESSAGE_ERRORS.each do |error_type|
  puts "  - #{error_type}"
end

puts "\nUsage pattern:"
puts <<~EXAMPLE
  ClaudeAgentSDK.query(prompt: "...") do |message|
    if message.is_a?(ClaudeAgentSDK::AssistantMessage) && message.error
      case message.error
      when 'rate_limit'
        # Handle rate limiting
      when 'authentication_failed'
        # Handle auth errors
      # ... etc
      end
    end
  end
EXAMPLE
