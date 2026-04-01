# frozen_string_literal: true

require_relative 'types'
require_relative 'errors'

module ClaudeAgentSDK
  # Parse message from CLI output into typed Message objects
  class MessageParser
    def self.parse(data)
      raise MessageParseError.new("Invalid message data type", data: data) unless data.is_a?(Hash)

      message_type = data[:type]
      raise MessageParseError.new("Message missing 'type' field", data: data) unless message_type

      case message_type
      when 'user'
        parse_user_message(data)
      when 'assistant'
        parse_assistant_message(data)
      when 'system'
        parse_system_message(data)
      when 'result'
        parse_result_message(data)
      when 'stream_event'
        parse_stream_event(data)
      when 'rate_limit_event'
        parse_rate_limit_event(data)
      when 'tool_progress'
        parse_tool_progress_message(data)
      when 'auth_status'
        parse_auth_status_message(data)
      when 'tool_use_summary'
        parse_tool_use_summary_message(data)
      when 'prompt_suggestion'
        parse_prompt_suggestion_message(data)
      end
      # Forward-compatible: returns nil for unrecognized message types so
      # newer CLI versions don't crash older SDK versions.
    rescue KeyError => e
      raise MessageParseError.new("Missing required field: #{e.message}", data: data)
    end

    def self.parse_user_message(data)
      parent_tool_use_id = data[:parent_tool_use_id]
      uuid = data[:uuid] # UUID for rewind support
      tool_use_result = data[:tool_use_result]
      message_data = data[:message]
      raise MessageParseError.new("Missing message field in user message", data: data) unless message_data

      content = message_data[:content]
      raise MessageParseError.new("Missing content in user message", data: data) unless content

      if content.is_a?(Array)
        content_blocks = content.map { |block| parse_content_block(block) }
        UserMessage.new(content: content_blocks, uuid: uuid, parent_tool_use_id: parent_tool_use_id,
                        tool_use_result: tool_use_result)
      else
        UserMessage.new(content: content, uuid: uuid, parent_tool_use_id: parent_tool_use_id,
                        tool_use_result: tool_use_result)
      end
    end

    def self.parse_assistant_message(data)
      content = data.dig(:message, :content)
      raise MessageParseError.new("Missing content in assistant message", data: data) unless content

      content_blocks = content.map { |block| parse_content_block(block) }
      AssistantMessage.new(
        content: content_blocks,
        model: data.dig(:message, :model),
        parent_tool_use_id: data[:parent_tool_use_id],
        error: data[:error], # authentication_failed, billing_error, rate_limit, invalid_request, server_error, unknown
        usage: data.dig(:message, :usage)
      )
    end

    def self.parse_system_message(data)
      case data[:subtype]
      when 'init'
        InitMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          agents: data[:agents], api_key_source: data[:apiKeySource] || data[:api_key_source],
          betas: data[:betas], claude_code_version: data[:claude_code_version],
          cwd: data[:cwd], tools: data[:tools], mcp_servers: data[:mcp_servers],
          model: data[:model], permission_mode: data[:permissionMode] || data[:permission_mode],
          slash_commands: data[:slash_commands], output_style: data[:output_style],
          skills: data[:skills], plugins: data[:plugins],
          fast_mode_state: data[:fastModeState] || data[:fast_mode_state]
        )
      when 'compact_boundary'
        raw_metadata = data[:compact_metadata]
        CompactBoundaryMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          compact_metadata: CompactMetadata.from_hash(raw_metadata)
        )
      when 'status'
        StatusMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          status: data[:status],
          permission_mode: data[:permissionMode] || data[:permission_mode]
        )
      when 'api_retry'
        APIRetryMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          attempt: data[:attempt], max_retries: data[:maxRetries] || data[:max_retries],
          retry_delay_ms: data[:retryDelayMs] || data[:retry_delay_ms],
          error_status: data[:errorStatus] || data[:error_status],
          error: data[:error]
        )
      when 'local_command_output'
        LocalCommandOutputMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          content: data[:content]
        )
      when 'hook_started'
        HookStartedMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          hook_id: data[:hookId] || data[:hook_id],
          hook_name: data[:hookName] || data[:hook_name],
          hook_event: data[:hookEvent] || data[:hook_event]
        )
      when 'hook_progress'
        HookProgressMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          hook_id: data[:hookId] || data[:hook_id],
          hook_name: data[:hookName] || data[:hook_name],
          hook_event: data[:hookEvent] || data[:hook_event],
          stdout: data[:stdout], stderr: data[:stderr], output: data[:output]
        )
      when 'hook_response'
        HookResponseMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          hook_id: data[:hookId] || data[:hook_id],
          hook_name: data[:hookName] || data[:hook_name],
          hook_event: data[:hookEvent] || data[:hook_event],
          output: data[:output], stdout: data[:stdout], stderr: data[:stderr],
          exit_code: data[:exitCode] || data[:exit_code],
          outcome: data[:outcome]
        )
      when 'session_state_changed'
        SessionStateChangedMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          state: data[:state]
        )
      when 'files_persisted'
        FilesPersistedMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          files: data[:files], failed: data[:failed],
          processed_at: data[:processedAt] || data[:processed_at]
        )
      when 'elicitation_complete'
        ElicitationCompleteMessage.new(
          subtype: data[:subtype], data: data,
          uuid: data[:uuid], session_id: data[:session_id],
          mcp_server_name: data[:mcpServerName] || data[:mcp_server_name],
          elicitation_id: data[:elicitationId] || data[:elicitation_id]
        )
      when 'task_started'
        TaskStartedMessage.new(
          subtype: data[:subtype], data: data,
          task_id: data[:task_id], description: data[:description],
          uuid: data[:uuid], session_id: data[:session_id],
          tool_use_id: data[:tool_use_id], task_type: data[:task_type],
          workflow_name: data[:workflowName] || data[:workflow_name],
          prompt: data[:prompt]
        )
      when 'task_progress'
        TaskProgressMessage.new(
          subtype: data[:subtype], data: data,
          task_id: data[:task_id], description: data[:description],
          usage: data[:usage], uuid: data[:uuid], session_id: data[:session_id],
          tool_use_id: data[:tool_use_id], last_tool_name: data[:last_tool_name],
          summary: data[:summary]
        )
      when 'task_notification'
        TaskNotificationMessage.new(
          subtype: data[:subtype], data: data,
          task_id: data[:task_id], status: data[:status],
          output_file: data[:output_file], summary: data[:summary],
          uuid: data[:uuid], session_id: data[:session_id],
          tool_use_id: data[:tool_use_id], usage: data[:usage]
        )
      else
        SystemMessage.new(subtype: data[:subtype], data: data)
      end
    end

    def self.parse_result_message(data)
      ResultMessage.new(
        subtype: data[:subtype],
        duration_ms: data[:duration_ms],
        duration_api_ms: data[:duration_api_ms],
        is_error: data[:is_error],
        num_turns: data[:num_turns],
        session_id: data[:session_id],
        stop_reason: data[:stop_reason],
        total_cost_usd: data[:total_cost_usd],
        usage: data[:usage],
        result: data[:result],
        structured_output: data[:structured_output],
        model_usage: data[:modelUsage] || data[:model_usage],
        permission_denials: data[:permission_denials],
        errors: data[:errors],
        uuid: data[:uuid],
        fast_mode_state: data[:fastModeState] || data[:fast_mode_state]
      )
    end

    def self.parse_stream_event(data)
      StreamEvent.new(
        uuid: data[:uuid],
        session_id: data[:session_id],
        event: data[:event],
        parent_tool_use_id: data[:parent_tool_use_id]
      )
    end

    def self.parse_rate_limit_event(data)
      info = data[:rate_limit_info] || {}
      rate_limit_info = RateLimitInfo.new(
        status: info[:status],
        resets_at: info[:resetsAt],
        rate_limit_type: info[:rateLimitType],
        utilization: info[:utilization],
        overage_status: info[:overageStatus],
        overage_resets_at: info[:overageResetsAt],
        overage_disabled_reason: info[:overageDisabledReason],
        raw: info
      )
      RateLimitEvent.new(
        rate_limit_info: rate_limit_info,
        uuid: data[:uuid],
        session_id: data[:session_id],
        raw_data: data
      )
    end

    def self.parse_tool_progress_message(data)
      ToolProgressMessage.new(
        uuid: data[:uuid],
        session_id: data[:session_id],
        tool_use_id: data[:toolUseId] || data[:tool_use_id],
        tool_name: data[:toolName] || data[:tool_name],
        parent_tool_use_id: data[:parentToolUseId] || data[:parent_tool_use_id],
        elapsed_time_seconds: data[:elapsedTimeSeconds] || data[:elapsed_time_seconds],
        task_id: data[:taskId] || data[:task_id]
      )
    end

    def self.parse_auth_status_message(data)
      AuthStatusMessage.new(
        uuid: data[:uuid],
        session_id: data[:session_id],
        is_authenticating: data[:isAuthenticating] || data[:is_authenticating],
        output: data[:output],
        error: data[:error]
      )
    end

    def self.parse_tool_use_summary_message(data)
      ToolUseSummaryMessage.new(
        uuid: data[:uuid],
        session_id: data[:session_id],
        summary: data[:summary],
        preceding_tool_use_ids: data[:precedingToolUseIds] || data[:preceding_tool_use_ids]
      )
    end

    def self.parse_prompt_suggestion_message(data)
      PromptSuggestionMessage.new(
        uuid: data[:uuid],
        session_id: data[:session_id],
        suggestion: data[:suggestion]
      )
    end

    def self.parse_content_block(block)
      case block[:type]
      when 'text'
        TextBlock.new(text: block[:text])
      when 'thinking'
        ThinkingBlock.new(thinking: block[:thinking], signature: block[:signature])
      when 'tool_use'
        ToolUseBlock.new(id: block[:id], name: block[:name], input: block[:input])
      when 'tool_result'
        ToolResultBlock.new(
          tool_use_id: block[:tool_use_id],
          content: block[:content],
          is_error: block[:is_error]
        )
      else
        # Forward-compatible: preserve unrecognized content block types (e.g., "document", "image")
        # so newer CLI versions don't crash older SDK versions.
        UnknownBlock.new(type: block[:type], data: block)
      end
    end
  end
end
