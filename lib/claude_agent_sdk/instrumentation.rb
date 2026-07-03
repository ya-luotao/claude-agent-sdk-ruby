# frozen_string_literal: true

# Instrumentation adapters for ClaudeAgentSDK.
# Each adapter lazy-requires its external gem, so loading this file has zero cost
# unless you instantiate a specific observer.
#
# This entry point is documented as a standalone require (docs/rails.md's
# initializer, OTelObserver's @example), so it must load the SDK core too —
# otherwise ClaudeAgentSDK exists (observer.rb reopens the module) but has
# no .configure/.query/ClaudeAgentOptions.
require_relative '../claude_agent_sdk'
require_relative 'instrumentation/otel'
