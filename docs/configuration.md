# Configuration & Features

Reference for advanced `ClaudeAgentOptions` features.

## Structured Output

Use `output_format` to get validated JSON responses matching a schema. The Claude CLI returns structured output via a `StructuredOutput` tool use block.

```ruby
require 'claude_agent_sdk'
require 'json'

schema = {
  type: 'object',
  properties: {
    name: { type: 'string' },
    age: { type: 'integer' },
    skills: { type: 'array', items: { type: 'string' } }
  },
  required: %w[name age skills]
}

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  output_format: { type: 'json_schema', schema: schema },
  max_turns: 3
)

structured_data = nil
ClaudeAgentSDK.query(prompt: "Create a profile for a software engineer", options: options) do |message|
  if message.is_a?(ClaudeAgentSDK::AssistantMessage)
    message.content.each do |block|
      structured_data = block.input if block.is_a?(ClaudeAgentSDK::ToolUseBlock) && block.name == 'StructuredOutput'
    end
  end
end
```

See [examples/structured_output_example.rb](../examples/structured_output_example.rb).

## Thinking Configuration

Control extended thinking behavior with typed configuration objects. The `thinking` option takes precedence over the deprecated `max_thinking_tokens`.

```ruby
# Adaptive — CLI dynamically adjusts budget based on task complexity
options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new)

# Enabled with explicit token budget
options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 50_000))

# Explicitly disabled
options = ClaudeAgentSDK::ClaudeAgentOptions.new(thinking: ClaudeAgentSDK::ThinkingConfigDisabled.new)
```

Use the `effort` option to control the model's effort level:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(effort: 'xhigh')
```

Valid levels live in `ClaudeAgentSDK::EFFORT_LEVELS` (`low`, `medium`, `high`, `xhigh`, `max`). The set of *supported* levels is model-dependent — `xhigh` is available on Opus 4.7 and the CLI falls back to the highest supported level at or below the one you set (e.g. `xhigh` → `high` on Opus 4.6). When `effort` is `nil`, the CLI picks a model-native default (Opus 4.7 → `xhigh`).

> **Note:** When `system_prompt` is `nil` (the default), the SDK passes `--system-prompt ""` to the CLI, which suppresses the default Claude Code system prompt. To use the default system prompt, use a `SystemPromptPreset`.

### Cross-User Prompt Caching

When running a multi-user fleet with shared preset prompts, enable `exclude_dynamic_sections` to make the system prompt byte-identical across users for prompt-caching hits:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  system_prompt: ClaudeAgentSDK::SystemPromptPreset.new(
    preset: 'claude_code',
    append: '...your shared domain instructions...',
    exclude_dynamic_sections: true
  )
)
```

When set, the CLI strips per-user dynamic sections (working directory, auto-memory, git status) from the system prompt and re-injects them into the first user message instead. Older CLIs silently ignore this option.

## Budget Control

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  max_budget_usd: 0.10,  # Cap at $0.10
  max_turns: 3
)

ClaudeAgentSDK.query(prompt: "Explain recursion", options: options) do |message|
  puts "Cost: $#{message.total_cost_usd}" if message.is_a?(ClaudeAgentSDK::ResultMessage)
end
```

See [examples/budget_control_example.rb](../examples/budget_control_example.rb).

## Fallback Model

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  model: 'claude-sonnet-4-20250514',
  fallback_model: 'claude-3-5-haiku-20241022'
)
```

See [examples/fallback_model_example.rb](../examples/fallback_model_example.rb).

## Beta Features

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  betas: ['context-1m-2025-08-07']  # Extended context window
)
```

Available beta features are listed in the `SDK_BETAS` constant.

## Tools Configuration

```ruby
# Array of tool names
options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: ['Read', 'Edit', 'Bash'])

# Preset
options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code'))

# Append to allowed tools
options = ClaudeAgentSDK::ClaudeAgentOptions.new(append_allowed_tools: ['Write', 'Bash'])
```

## Sandbox Settings

Configure [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) restrictions (network policy, filesystem access) via the CLI's `--sandbox` flag. The CLI handles OS-level process isolation using `srt`.

```ruby
sandbox = ClaudeAgentSDK::SandboxSettings.new(
  enabled: true,
  auto_allow_bash_if_sandboxed: true,
  network: ClaudeAgentSDK::SandboxNetworkConfig.new(allow_local_binding: true)
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  sandbox: sandbox,
  permission_mode: 'acceptEdits'
)
```

See [examples/sandbox_example.rb](../examples/sandbox_example.rb).

## Bare Mode

Bare mode (`--bare`) is a minimal startup mode that skips hooks, LSP, plugin sync, attribution, auto-memory, background prefetches, keychain reads, and CLAUDE.md auto-discovery. It sets `CLAUDE_CODE_SIMPLE=1` internally. Useful for scripted/programmatic usage where you want fast startup and full control over what's loaded.

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  bare: true,
  system_prompt: 'You are a code reviewer.',
  permission_mode: 'bypassPermissions'
)
```

In bare mode, explicitly provide any context you need:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  bare: true,
  system_prompt: 'You are a helpful assistant.',
  add_dirs: ['/path/to/project'],       # CLAUDE.md directories (auto-discovery is off)
  setting_sources: ['project'],          # load .claude/settings.json
  allowed_tools: ['Read', 'Grep', 'Glob'],
  permission_mode: 'bypassPermissions'
)
```

**What bare mode skips:** hooks, LSP, plugin sync, attribution, auto-memory, background prefetches, keychain reads, CLAUDE.md auto-discovery, teammate snapshots, release notes.

**What still works:** skills (via `/skill-name`), explicit `--add-dir` CLAUDE.md, `--settings`, `--mcp-config`, `--agents`, `--plugin-dir`, API key from `ANTHROPIC_API_KEY` env var.

See [examples/bare_mode_example.rb](../examples/bare_mode_example.rb).

## File Checkpointing & Rewind

Enable file checkpointing to revert file changes to a previous state:

```ruby
require 'async'

Async do
  options = ClaudeAgentSDK::ClaudeAgentOptions.new(
    enable_file_checkpointing: true,
    permission_mode: 'acceptEdits'
  )

  client = ClaudeAgentSDK::Client.new(options: options)
  client.connect

  user_message_uuids = []

  client.query("Create a test.rb file with some code")
  client.receive_response do |message|
    user_message_uuids << message.uuid if message.is_a?(ClaudeAgentSDK::UserMessage) && message.uuid
  end

  client.query("Modify the test.rb file to add error handling")
  client.receive_response do |message|
    user_message_uuids << message.uuid if message.is_a?(ClaudeAgentSDK::UserMessage) && message.uuid
  end

  # Rewind to the first checkpoint (undoes the second query's changes)
  client.rewind_files(user_message_uuids.first) if user_message_uuids.first

  client.disconnect
end.wait
```

> **Note:** The `uuid` field on `UserMessage` is populated by the CLI and represents checkpoint identifiers. Rewinding to a UUID restores file state to what it was at that point in the conversation.
