# frozen_string_literal: true

# Instrumentation adapters for ClaudeAgentSDK.
# Each adapter lazy-requires its external gem, so loading this file has zero cost
# unless you instantiate a specific observer.
require_relative 'instrumentation/otel'
