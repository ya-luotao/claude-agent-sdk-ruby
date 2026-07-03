# frozen_string_literal: true

# Bundler autorequire shim. The gem is named `claude-agent-sdk`, so
# `Bundler.require` tries `require 'claude-agent-sdk'` and then
# `require 'claude/agent/sdk'` — and silently swallows both LoadErrors when
# neither file exists, leaving the SDK unloaded in default Rails/Bundler
# apps. This file makes the gem-named require resolve to the real entry point.
require_relative 'claude_agent_sdk'
