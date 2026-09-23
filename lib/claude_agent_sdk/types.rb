# frozen_string_literal: true

# Entry point for the SDK's value types. The definitions live in
# lib/claude_agent_sdk/types/, one file per area; this file loads all of them,
# so `require 'claude_agent_sdk/types'` still defines every type. `base` (the
# Type superclass) comes first; each part also requires it itself.
require_relative 'types/base'
require_relative 'types/content_blocks'
require_relative 'types/messages'
require_relative 'types/option_values'
require_relative 'types/permissions'
require_relative 'types/hooks'
require_relative 'types/mcp'
require_relative 'types/sessions'
require_relative 'types/options'
