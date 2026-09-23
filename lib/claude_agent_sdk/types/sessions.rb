# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
  # Result of a session fork operation
  class ForkSessionResult < Type
    attr_accessor :session_id
  end
end
