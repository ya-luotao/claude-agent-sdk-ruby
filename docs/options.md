# Options Reference

Every attribute of `ClaudeAgentSDK::ClaudeAgentOptions`, with its type, its default, and what it turns into: a flag on the `claude` command line, a field of the control protocol's `initialize` request, a variable in the CLI's environment, or something the SDK handles on its own side. The topic guides explain how to use the larger features; this page is the complete list.

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(model: 'claude-sonnet-5', max_turns: 5)
ClaudeAgentSDK.query(prompt: 'Hello', options: options) { |message| puts message }
```

- An unknown option name raises `ArgumentError`, in `.new`, in `#[]=` and in `#dup_with`. Names may be Symbols or Strings, snake_case or camelCase.
- `options.dup_with(max_turns: 1)` returns a changed copy and leaves the original alone.
- `ClaudeAgentSDK.configure { |config| config.default_options = { ... } }` sets defaults for every `ClaudeAgentOptions` built afterwards. A value you pass replaces the configured one, with two exceptions: `nil` keeps the configured value, and a Hash is merged into a configured Hash (that holds for every Hash-valued option, `env`, `mcp_servers`, `settings` and a Hash `system_prompt` or `output_format` included).

## Reading the tables

- **Type** is the option's type in the gem's RBS signatures (`sig/claude_agent_sdk/types/options.rbs`). Every option also accepts `nil` in `.new`, which means "not set": the default applies. `bool` is `true` or `false`. A name that starts with an underscore is an interface, so any object with the right method fits: `call` for the callbacks, `puts` for `_Puts`, `append` and `load` for `_SessionStore`.
- **Default** is the value of a fresh `ClaudeAgentOptions.new` with no configured defaults.
- **Sent to the CLI as** names the flag, the `initialize` field (`initialize.hooks` is the `hooks` field of that request) or the environment variable. "Nothing (SDK only)" marks an option that changes only what the SDK does in your process.

Three types in the tables are aliases:

| Alias | Stands for |
|-------|------------|
| `system_prompt_config` | `String`, `SystemPromptPreset`, `SystemPromptCustom`, `SystemPromptFile`, or the equivalent Hash (`{ type: 'preset' \| 'custom' \| 'file', ... }`) |
| `thinking_config` | `ThinkingConfigAdaptive`, `ThinkingConfigEnabled`, `ThinkingConfigDisabled`, or the equivalent Hash |
| `mcp_server_config` | `McpStdioServerConfig`, `McpSSEServerConfig`, `McpHttpServerConfig`, `McpSdkServerConfig`, or the equivalent Hash |

## Prompt, model and limits

Guides: [Structured Output](configuration.md#structured-output), [Thinking Configuration](configuration.md#thinking-configuration), [Budget Control](configuration.md#budget-control), [Fallback Model](configuration.md#fallback-model), [Advisor Model](configuration.md#advisor-model), [Beta Features](configuration.md#beta-features).

| Option | Type | Default | Sent to the CLI as |
|--------|------|---------|--------------------|
| `system_prompt` | `system_prompt_config` | `nil` | `--system-prompt`, `--system-prompt-file` or `--append-system-prompt`, and two `initialize` fields. See [System prompt forms](#system-prompt-forms) |
| `model` | `String` | `nil` | `--model` |
| `fallback_model` | `String` | `nil` | `--fallback-model` |
| `advisor_model` | `String` | `nil` | `--advisor` |
| `max_turns` | `Integer` | `nil` | `--max-turns` |
| `max_budget_usd` | `Numeric` | `nil` | `--max-budget-usd` |
| `task_budget` | `TaskBudget \| Hash[Symbol \| String, untyped]` | `nil` | `--task-budget <total>`. See [`task_budget`](#task_budget) |
| `thinking` | `thinking_config` | `nil` | `--thinking adaptive`, `--thinking disabled` or `--max-thinking-tokens <budget_tokens>`; `display:` adds `--thinking-display` |
| `effort` | `String \| Symbol \| Integer` | `nil` | `--effort` |
| `max_thinking_tokens` | `Integer` | `nil` | `--max-thinking-tokens`. Deprecated: used only when `thinking` is unset |
| `betas` | `Array[String]` | `nil` | `--betas` (comma-joined) |
| `output_format` | `Hash[Symbol \| String, untyped] \| String` | `nil` | `--json-schema <schema as JSON>` |

`effort` takes one of `ClaudeAgentSDK::EFFORT_LEVELS`; which levels a model supports is in [Thinking Configuration](configuration.md#thinking-configuration).

### System prompt forms

| `system_prompt` | Command line |
|-----------------|--------------|
| `nil` (the default) | `--system-prompt ""`: an empty prompt, not Claude Code's default one |
| a String, `SystemPromptCustom`, or `{ type: 'custom', prompt: '...' }` | `--system-prompt <text>` |
| `SystemPromptFile`, or `{ type: 'file', path: '...' }` | `--system-prompt-file <path>` |
| `SystemPromptPreset`, or `{ type: 'preset', preset: 'claude_code' }` | no system prompt flag, so the CLI uses its default prompt; `append:` adds `--append-system-prompt <text>` |

`exclude_dynamic_sections` on a preset is sent as `initialize.excludeDynamicSections` ([Cross-User Prompt Caching](configuration.md#cross-user-prompt-caching)), and `snapshot` on a preset or a custom prompt as `initialize.systemPromptSnapshot` ([System Prompt Snapshot](configuration.md#system-prompt-snapshot)). Both are left out when unset.

### `task_budget`

A token budget for the task, counted on the API side: the model is told how much of it is left, so it can pace its tool use and wrap up before the limit. Pass `ClaudeAgentSDK::TaskBudget.new(total: 50_000)` or `{ total: 50_000 }`. It is not `max_budget_usd`, which is a spending limit in dollars.

## Tools and permissions

Guides: [Tools Configuration](configuration.md#tools-configuration), [Skills](configuration.md#skills), [Sandbox Settings](configuration.md#sandbox-settings), [Hooks & Permission Callbacks](hooks-and-permissions.md).

| Option | Type | Default | Sent to the CLI as |
|--------|------|---------|--------------------|
| `tools` | `Array[String] \| ToolsPreset \| Hash[Symbol \| String, untyped]` | `nil` | `--tools <comma-joined names>`. `[]` sends `--tools ""` (no built-in tools); a `ToolsPreset` sends `--tools default` |
| `allowed_tools` | `Array[String]` | `[]` | `--allowedTools` (comma-joined; no flag when empty) |
| `disallowed_tools` | `Array[String]` | `[]` | `--disallowedTools` (comma-joined; no flag when empty) |
| `permission_mode` | `String` | `nil` | `--permission-mode` |
| `can_use_tool` | `_CanUseTool` | `nil` | `--permission-prompt-tool stdio`: the CLI asks over the control protocol and the SDK calls the callback |
| `permission_prompt_tool_name` | `String` | `nil` | `--permission-prompt-tool <name>`. Combining it with `can_use_tool` raises `ArgumentError` |
| `hooks` | `Hash[String \| Symbol, Array[HookMatcher]?]` | `nil` | `initialize.hooks` (matchers, callback ids, timeouts). The callbacks run in your process |
| `skills` | `String \| Array[String]` | `nil` | `Skill` or `Skill(name)` entries in `--allowedTools`; an Array is also sent as `initialize.skills`; `--setting-sources user,project` when `setting_sources` is `nil` |
| `sandbox` | `SandboxSettings \| Hash[Symbol \| String, untyped] \| bool` | `nil` | The `sandbox` key of `--settings` |

`permission_mode` takes one of `ClaudeAgentSDK::PERMISSION_MODES`.

## MCP servers, agents and plugins

Guides: [Custom Tools (SDK MCP Servers)](mcp-servers.md), [Subagent capabilities](subagents.md).

| Option | Type | Default | Sent to the CLI as |
|--------|------|---------|--------------------|
| `mcp_servers` | `Hash[String \| Symbol, mcp_server_config] \| String` | `{}` | `--mcp-config`: a Hash as `{"mcpServers": {...}}` JSON, a String (a file path or JSON) as given. An SDK server contributes only its `type` and `name`; its tools are served in your process over the control protocol |
| `strict_mcp_config` | `bool` | `false` | `--strict-mcp-config`. See [`strict_mcp_config`](#strict_mcp_config) |
| `agents` | `Hash[String \| Symbol, AgentDefinition \| Hash[Symbol \| String, untyped]]` | `nil` | `initialize.agents` |
| `plugins` | `Array[SdkPluginConfig \| Hash[Symbol \| String, untyped]]` | `nil` | `--plugin-dir <path>`, once per plugin |

### `strict_mcp_config`

`true` makes the CLI use only the servers in `mcp_servers` and ignore every other MCP configuration (the CLI's own description of `--strict-mcp-config`: "Only use MCP servers from --mcp-config, ignoring all other MCP configurations").

"Every other" includes the MCP servers connected to the claude.ai account the CLI is logged in with. A session loads those by default, and `setting_sources: []` does not keep them out, because they do not come from a settings file. `client.mcp_status` shows them: their `:config` has `type: 'claudeai-proxy'`. A host that runs sessions for other people under its own login should set `strict_mcp_config: true`.

## Settings and context

Guides: [Bare Mode](configuration.md#bare-mode), [Verbatim Prompts](configuration.md#verbatim-prompts), [Session Isolation](configuration.md#session-isolation).

| Option | Type | Default | Sent to the CLI as |
|--------|------|---------|--------------------|
| `settings` | `String \| Hash[Symbol \| String, untyped]` | `nil` | `--settings`: a Hash as JSON, a String (a file path or JSON) as given. With `sandbox` set as well, one merged JSON value |
| `setting_sources` | `Array[String]` | `nil` | `--setting-sources` (comma-joined). `[]` sends `--setting-sources ""`; `nil` sends no flag |
| `add_dirs` | `Array[String \| Pathname]` | `[]` | `--add-dir`, once per directory |
| `bare` | `bool` | `nil` | `--bare` |
| `verbatim_prompts` | `bool` | `false` | `client_composed: true` on every user message the SDK writes |

`setting_sources` takes entries of `ClaudeAgentSDK::SETTING_SOURCES` (`user`, `project`, `local`). With `nil`, the default, the CLI decides, and it loads the user's and the project's settings and `CLAUDE.md` files. `[]` loads none of the three sources. Neither value affects the auto-memory: see [Session Isolation](configuration.md#session-isolation).

## Sessions

Guide: [Session Browsing & Mutations](sessions.md), which also covers `session_store`. [File Checkpointing & Rewind](configuration.md#file-checkpointing--rewind) is in the configuration guide.

| Option | Type | Default | Sent to the CLI as |
|--------|------|---------|--------------------|
| `resume` | `String` | `nil` | `--resume=<session id>` |
| `continue_conversation` | `bool` | `false` | `--continue`. Combining it with `resume` raises `ArgumentError` |
| `fork_session` | `bool` | `false` | `--fork-session` |
| `session_id` | `String` | `nil` | `--session-id=<uuid>` |
| `resume_session_at` | `String` | `nil` | `--resume-session-at=<uuid>`. Without `resume` it raises `ArgumentError` |
| `resume_drops_turn` | `String` | `nil` | `--resume-drops-turn=<uuid>` |
| `enable_file_checkpointing` | `bool` | `false` | `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` in the CLI's environment |
| `session_store` | `_SessionStore` | `nil` | `--session-mirror`. The SDK appends the mirrored transcript to the store and can resume from it |
| `session_store_flush` | `String \| Symbol` | `"batched"` | Nothing (SDK only): `'batched'` or `'eager'` |
| `load_timeout_ms` | `Numeric` | `60000` | Nothing (SDK only): the limit, in milliseconds, for each store call while a resume loads the transcript |

To find the session to resume, `ClaudeAgentSDK.list_sessions` lists sessions and `ClaudeAgentSDK.get_session_info(session_id:, directory: nil, session_store: nil)` reads the metadata of one session without listing the others. It returns an `SDKSessionInfo`, or `nil` when there is no session to report under that id. Both are plain functions that need neither a `Client` nor the CLI; the sessions guide has the rest of them.

## Message stream

Guides: [Forwarding Subagent Text](configuration.md#forwarding-subagent-text), [Subagent Progress Summaries](configuration.md#subagent-progress-summaries). The message classes are in the [types reference](types.md#message-types).

| Option | Type | Default | Sent to the CLI as |
|--------|------|---------|--------------------|
| `include_partial_messages` | `bool` | `false` | `--include-partial-messages`. See [`include_partial_messages`](#include_partial_messages) |
| `include_hook_events` | `bool` | `false` | `--include-hook-events`. See [`include_hook_events`](#include_hook_events) |
| `forward_subagent_text` | `bool` | `false` | `initialize.forwardSubagentText`, sent only when `true` |
| `agent_progress_summaries` | `bool` | `nil` | `initialize.agentProgressSummaries`, left out when `nil` |

### `include_partial_messages`

Asks the CLI for partial message chunks while the model is still producing a message. Each chunk arrives as a `StreamEvent` whose `event` is the raw API stream event, a Hash with Symbol keys; the complete `AssistantMessage` still follows. Without the option the CLI sends no `StreamEvent`.

### `include_hook_events`

Asks the CLI to put all hook lifecycle events into the message stream, as `HookStartedMessage`, `HookProgressMessage` and `HookResponseMessage` (see [System and progress messages](types.md#system-and-progress-messages)). It only adds messages: the callbacks you register with `hooks` are called whether or not it is set.

## The CLI process

Guides: [Vendoring the CLI](cli-installer.md), [Custom Transport](client.md#custom-transport).

| Option | Type | Default | Sent to the CLI as |
|--------|------|---------|--------------------|
| `cli_path` | `String \| Pathname` | `nil` | The executable the SDK starts. `nil`: the [discovery order](cli-installer.md#cli-discovery-order) |
| `cwd` | `String \| Pathname` | `nil` | The working directory of the CLI process (and its `PWD`) |
| `env` | `Hash[String \| Symbol, String?]` | `{}` | Merged over the environment the CLI process inherits. A `nil` value unsets the variable |
| `user` | `String \| Integer` | `nil` | The user the CLI process runs as (name or uid; Unix, and the SDK process needs the privilege to switch) |
| `extra_args` | `Hash[String \| Symbol, untyped]` | `{}` | `--<flag> <value>` per pair, `--<flag>` for a `nil` value. See [`extra_args`](#extra_args) |
| `stderr` | `_StderrCallback` | `nil` | Nothing (SDK only): called with each line the CLI writes to stderr |
| `debug_stderr` | `_Puts \| String` | `nil` | Nothing (SDK only): an IO-like object (`puts`) or a file path that receives each CLI stderr line |
| `max_buffer_size` | `Integer` | `nil` | Nothing (SDK only): the largest single message, in bytes, accepted from the CLI. `nil` means 1 MiB |

These options describe the process the SDK starts itself. A [custom transport](client.md#custom-transport) starts the CLI its own way and decides what to do with them.

### `extra_args`

The way to pass a CLI flag the SDK has no option for. A key is the flag's name without the leading dashes; the value follows it, and `nil` means a flag without a value:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  extra_args: {
    'no-session-persistence' => nil, # --no-session-persistence
    'agent' => 'reviewer'            # --agent reviewer
  }
)
```

- A flag name may contain only lowercase letters, digits and hyphens. Anything else raises `ArgumentError` when the command line is built, before the CLI starts.
- Values are converted with `to_s`. One that starts with `-` is sent as `--flag=value`, so the CLI cannot read it as another flag.
- The flags go at the end of the command line, after everything the options above produce. The SDK does not check that the CLI knows them: an unknown flag makes the CLI exit at startup, which raises `ProcessError` (`error: unknown option '--...'`).
- Use an option when there is one. A flag given here as well as through its option reaches the CLI twice.

## Callbacks and observers

Guides: [Observability](observability.md), [Rails Integration](rails.md).

| Option | Type | Default | Sent to the CLI as |
|--------|------|---------|--------------------|
| `observers` | `Array[untyped]` | `[]` | Nothing (SDK only): observer instances, or callables that return a fresh one per query or session |
| `callback_scheduling` | `:thread \| :inline` | `:thread` | Nothing (SDK only): `:thread` runs each callback on a plain thread, `:inline` on the reactor fiber |
| `callback_wrapper` | `_CallbackWrapper` | `nil` | Nothing (SDK only): a callable wrapped around every callback dispatch |

## Environment variables

Variables that change what the SDK or a session does. "SDK process" means your Ruby process's own environment; `env` means `ClaudeAgentOptions#env`, which reaches only the CLI.

| Variable | Set it in | Effect |
|----------|-----------|--------|
| `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` | SDK process (the CLI inherits it) or `env` | Credentials the CLI can authenticate with |
| `CLAUDE_CLI_PATH` | SDK process | The CLI executable, ahead of the vendored binary and `PATH`, when `cli_path` is `nil`. A relative path is resolved against the SDK process's working directory. A value that does not name an executable file is skipped without a warning, and discovery goes on to the vendored binary, `PATH` and the common install locations |
| `CLAUDE_CONFIG_DIR` | SDK process, and `env` for the CLI | Where Claude Code keeps its configuration and transcripts, instead of `~/.claude`. The session functions read it from the SDK process ([Sessions](sessions.md)) |
| `CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS` | SDK process | How long the SDK waits for the CLI's answer to a control request. Default 1200 ([Error Handling](errors.md#configuring-timeout)) |
| `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` | `env`, or the SDK process | See below |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY` | `env` | `'1'` turns the CLI's auto-memory off ([Session Isolation](configuration.md#session-isolation)) |
| `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS` | `env` | `'1'` makes `SessionStateChangedMessage` reach your message block |
| `CLAUDE_CODE_DISABLE_ADVISOR_TOOL` | `env` | `'1'` disables the advisor tool ([Advisor Model](configuration.md#advisor-model)) |

### `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`

A one-shot `query()` or `ask` that has hooks, a `can_use_tool` callback or SDK MCP servers keeps the CLI's stdin open after a turn's result, because background work can still wake the session for another turn whose hook, permission and tool requests are answered over stdin. It closes stdin when the CLI reports that it is idle. This variable bounds that wait: if the CLI still reports work this many milliseconds after a result and no new turn has started, the run ends anyway.

- The default is 600000 (10 minutes). `0` means no limit.
- It is read from `env` first and from the SDK process's environment otherwise. Only a plain non-negative integer counts; anything else gives the default.
- The clock runs only between turns. A turn in progress, a request the SDK is still answering and a background agent that is still running stop it.
- The CLI reads the same variable for its own wait for background work once stdin is closed.
- A CLI that reports no session state (2.1.282 and earlier) is not waited for: stdin closes at the first result with no tracked background task still running.
- A `Client` session driven with `Client#query` is not affected: its stdin stays open until `disconnect`.
