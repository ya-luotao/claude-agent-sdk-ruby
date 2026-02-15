# Options (ClaudeAgentOptions)

Configure the SDK via `ClaudeAgentSDK::ClaudeAgentOptions.new(...)`. Set only what you need.

## Global defaults (`ClaudeAgentSDK.configure`)

Set defaults once, then override only when needed per call.

```ruby
ClaudeAgentSDK.configure do |config|
  config.default_options = {
    model: 'claude-sonnet-4-5',
    permission_mode: 'bypassPermissions',
    env: { 'ANTHROPIC_API_KEY' => ENV.fetch('ANTHROPIC_API_KEY') }
  }
end
```

Notes:
- `ClaudeAgentOptions.new(...)` still overrides defaults you pass explicitly.
- Hash options like `env` and `mcp_servers` merge with configured defaults.

## Core knobs

- `system_prompt`: Set an overall instruction as a string, or use `ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', append: '...')` to extend a preset prompt.
- `model`: Select the model.
- `fallback_model`: Use when the primary model is unavailable.
- `max_turns`: Cap the number of turns.
- `max_budget_usd`: Cap total spend (USD).
- `include_partial_messages`: Include partial assistant messages in the stream when supported.
- `cwd`: Run Claude Code in a specific working directory.
- `max_thinking_tokens`: Stored for API parity, but not currently passed through to Claude CLI.

## Tools and permissions

- `tools`: Set base tools (Array, Hash, or `ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code')`).
- `allowed_tools`: Explicit allow-list (examples: `Read`, `Write`, `Edit`, `Bash`, and `mcp__name__tool`).
- `append_allowed_tools`: Append to tool allow-list without replacing it.
- `disallowed_tools`: Explicit block-list.
- `permission_mode`: Common values include `default`, `acceptEdits`, and `bypassPermissions`.

## Permission callback (programmable allow/deny)

Use `can_use_tool:` to control tool execution from Ruby.

- Use `ClaudeAgentSDK::PermissionResultAllow.new(updated_input: ..., updated_permissions: ...)` to allow.
- Use `ClaudeAgentSDK::PermissionResultDeny.new(message: ..., interrupt: ...)` to deny.

Important constraints:
- Use `can_use_tool` only with `ClaudeAgentSDK::Client` (streaming mode); it is not supported by `ClaudeAgentSDK.query`.
- Do not use `can_use_tool` together with `permission_prompt_tool_name`.

## Hooks

Use `hooks:` with hook event names (for example `PreToolUse`, `PostToolUse`) and `ClaudeAgentSDK::HookMatcher` instances.

```ruby
ClaudeAgentSDK::HookMatcher.new(
  matcher: 'Bash',           # Tool name to match (string or regex)
  hooks: [my_callback],      # Array of callback lambdas
  timeout: 5                 # Optional: timeout in seconds
)
```

Hook callbacks receive typed input objects (for example `ClaudeAgentSDK::PreToolUseHookInput`) and a `ClaudeAgentSDK::HookContext`. Access fields via Ruby accessors like `input.tool_name` and `input.tool_input`.

Hook callbacks should return a hash. Only top-level keys are auto-converted; use CLI-style camelCase for nested keys.

## Structured output

Use `output_format:` to request validated structured output (JSON schema).

Structured data may be available in either of these places:
- `ResultMessage#structured_output`
- A `ToolUseBlock` named `StructuredOutput` inside `AssistantMessage#content`

## Sessions and rewind

- `resume`: Resume a previous session (store the `ResultMessage#session_id`).
- `fork_session`: Fork a session (create an isolated branch of the conversation).
- `continue_conversation`: Continue an existing conversation when supported by the CLI.
- `enable_file_checkpointing`: Enable file checkpoints so `UserMessage#uuid` can be used with `Client#rewind_files`.

## MCP servers

Use `mcp_servers:` to add SDK MCP servers (in-process) or external MCP servers. See `references/mcp-servers.md`.

## Sandbox

Use `sandbox:` with `ClaudeAgentSDK::SandboxSettings` to run tool execution in an isolated sandbox when supported.

## Experimental and runtime controls

- `betas`: Enable CLI beta features (`--betas`).
- Client runtime APIs:
- `Client#interrupt`
- `Client#set_permission_mode`
- `Client#set_model`
- `Client#get_mcp_status`
- `Client#get_server_info`
