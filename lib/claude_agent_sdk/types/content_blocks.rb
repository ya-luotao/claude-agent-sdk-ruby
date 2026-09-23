# frozen_string_literal: true

require_relative 'base'

module ClaudeAgentSDK
  # Content Blocks

  # Text content block
  class TextBlock < Type
    attr_accessor :text

    def to_s
      text.to_s
    end
  end

  # Thinking content block
  class ThinkingBlock < Type
    attr_accessor :thinking, :signature
  end

  # Tool use content block
  class ToolUseBlock < Type
    attr_accessor :id, :name, :input
  end

  # Tool result content block
  class ToolResultBlock < Type
    attr_accessor :tool_use_id, :content, :is_error
  end

  # Server-side tool use (CLI's built-in tools that execute server-side
  # rather than as MCP tools — advisor, web_search, code_execution, etc.).
  # Mirrors Python's `ServerToolUseBlock`.
  class ServerToolUseBlock < Type
    attr_accessor :id, :name, :input
  end

  # Result of a server-side tool execution. Mirrors Python's
  # `ServerToolResultBlock`.
  class ServerToolResultBlock < Type
    attr_accessor :tool_use_id, :content, :is_error
  end

  # Generic content block for types the SDK doesn't explicitly handle (e.g., "document", "image").
  # Preserves the raw hash data for forward compatibility with newer CLI versions.
  class UnknownBlock < Type
    attr_accessor :type, :data
  end

  # Deferred tool use, emitted on `ResultMessage` when a PreToolUse hook
  # returned `permissionDecision: "defer"`. The session can be resumed later
  # to execute the deferred call. Mirrors Python's `DeferredToolUse`.
  class DeferredToolUse < Type
    attr_accessor :id, :name, :input
  end
end
