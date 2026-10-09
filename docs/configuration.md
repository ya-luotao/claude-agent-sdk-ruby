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

In the `output_format` Hash, `type` may be a String or a Symbol (`type: :json_schema`), and the keys Symbols or Strings.

See [examples/structured_output_example.rb](https://github.com/rubycatco/claude-agent-sdk-ruby/blob/main/examples/structured_output_example.rb).

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

Valid levels live in `ClaudeAgentSDK::EFFORT_LEVELS` (`low`, `medium`, `high`, `xhigh`, `max`). The set of *supported* levels is model-dependent — `xhigh` is available on Opus 4.7 and later models, and the CLI falls back to the highest supported level at or below the one you set (e.g. `xhigh` → `high` on Opus 4.6). When `effort` is `nil`, the CLI picks a model-native default (e.g. Opus 4.7 → `xhigh`).

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

### System Prompt Snapshot

By default, Claude Code builds the system prompt on a session's first request, records it, and reuses it on every later request, including after you resume the session. A changed custom prompt, or changed `append` text on the `claude_code` preset, then has no effect until the session is compacted or you start a new session. To rebuild the prompt on every request instead, for example while you iterate on its wording, set `snapshot: false` on a `SystemPromptPreset` or on `SystemPromptCustom` (the object form of a String prompt, which exists so `snapshot` can be set alongside it):

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  system_prompt: ClaudeAgentSDK::SystemPromptCustom.new(
    prompt: 'You are a release bot.',
    snapshot: false
  )
)

# Hash forms work too:
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  system_prompt: { type: 'preset', preset: 'claude_code', append: '...', snapshot: false }
)
```

In a Hash form, `type` may be a String or a Symbol (`type: :preset`).

`snapshot` is sent on the control-protocol `initialize` request (never as a CLI flag), so it applies to both `query()` and `Client`. When omitted it acts as `true`, except in bare mode (`bare: true`), where it acts as `false`. A `SystemPromptFile` has no `snapshot`.

Requires Claude Code CLI 2.1.257 or later. Before 2.1.265, a session with an `append` or custom prompt recorded it only when `snapshot` was `true`. See [Modifying system prompts](https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts#change-the-prompt-of-an-existing-session) for details.

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

See [examples/budget_control_example.rb](https://github.com/rubycatco/claude-agent-sdk-ruby/blob/main/examples/budget_control_example.rb).

## Fallback Model

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  model: 'claude-sonnet-5',
  fallback_model: 'claude-haiku-4-5'
)
```

See [examples/fallback_model_example.rb](https://github.com/rubycatco/claude-agent-sdk-ruby/blob/main/examples/fallback_model_example.rb).

## Advisor Model

Pair the main model with a stronger advisor model that Claude consults at key
decision points (before committing to an approach, when stuck on a recurring
error, before declaring a task done). The advisor runs server-side and
receives the full conversation.

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  model: 'claude-haiku-4-5',
  advisor_model: 'claude-opus-5'  # full model ID, or an alias such as 'opus'
)
```

Advisor consultations surface in `AssistantMessage` content as
`ServerToolUseBlock` (name `'advisor'`) and `ServerToolResultBlock`
(`advisor_tool_result`) blocks.

Notes:

- Experimental; requires the Anthropic API (not available on Bedrock, Google
  Cloud's Agent Platform, or Microsoft Foundry). Requires Claude Code CLI with
  advisor support (v2.1.x).
- The CLI validates the pairing — the advisor must be at least as capable as
  the main model (e.g. a Haiku main accepts an Opus advisor; the reverse is
  rejected). Pairing rules are CLI-version-dependent, so the SDK passes the
  value through without validating it.
- Advisor calls are billed at the advisor model's rates in addition to the
  main model's usage.
- `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1` (settable via `options.env`) disables
  the advisor tool entirely; a configured `advisor_model` is then ignored.

See [examples/advisor_example.rb](https://github.com/rubycatco/claude-agent-sdk-ruby/blob/main/examples/advisor_example.rb) and the
[advisor documentation](https://code.claude.com/docs/en/advisor).

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

# The same names as one String, in the comma-separated form of the CLI's --tools flag
options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: 'Read,Edit,Bash')

# Preset
options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code'))

# The preset as a Hash
options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: { type: 'preset', preset: 'claude_code' })
```

A String is passed to the CLI as written. In the Hash form, `type` may be a String or a Symbol (`type: :preset`).

## Skills

`skills` is the single place to enable skills for the main session — it auto-allows the `Skill` tool and defaults `setting_sources` to `['user', 'project']` (when unset) so skill files are discovered:

```ruby
# Every discovered skill ('all' is the only valid String)
options = ClaudeAgentSDK::ClaudeAgentOptions.new(skills: 'all')

# Specific skills only — also sent to the CLI so only these are loaded
options = ClaudeAgentSDK::ClaudeAgentOptions.new(skills: %w[pdf docx])
```

Semantics: `nil` (default) leaves CLI defaults untouched; `[]` hides every skill from the listing; an Array adds `Skill(name)` allow-rules per entry (use `plugin:skill` for plugin-qualified names). An explicitly set `setting_sources` (including `[]`) is never overridden. This is a context filter, not a sandbox — skill files remain readable on disk.

If you also give `tools` as a list of names, put `'Skill'` in it. `skills` adds the `Skill` tool to the *allowed* tools, while `tools` decides which tools the session has at all: with `tools: ['Read'], skills: 'all'` there is no `Skill` tool, and no skill can run. Leaving `tools` unset keeps it.

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(tools: %w[Read Skill], skills: %w[pdf docx])
```

## Sandbox Settings

Configure [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) restrictions (network policy, filesystem access) with the `sandbox` option. The SDK sends it to the CLI as the `sandbox` key of the `--settings` argument, merged into your `settings:` when you pass both; there is no separate sandbox flag. The CLI handles OS-level process isolation using `srt`.

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

`sandbox` also takes a Hash, and so do `network` and `filesystem`, inside that Hash or inside a `SandboxSettings`. A Hash may spell the fields of `SandboxSettings`, `SandboxNetworkConfig` and `SandboxFilesystemConfig` as the classes do (`denied_domains`) or as the CLI does (`deniedDomains`), with Symbol or String keys:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  sandbox: {
    enabled: true,
    network: { denied_domains: ['evil.example'] },
    filesystem: { deny_read: ['~/.ssh'] }
  }
)
```

- Any other key is sent as written. That is how to pass a sandbox setting the classes have no attribute for (`allowAppleEvents`, `strictAllowlist` inside `network`): spell it as the CLI does.
- A snake_case key is sent under the CLI's name only when its value has the shape the CLI accepts for that key: `true` or `false` for a switch, an Array of Strings for a list, a port number (an Integer from 0 to 65535) for a proxy port, a Hash of String Arrays for `ignore_violations`. With a value of any other shape (`denied_domains: 'evil.example'`, a String where an Array belongs) the key is sent as written, and the CLI ignores a key it does not know.
- A field holding `nil` is left out, in either spelling, as a `nil` attribute of the typed classes is.

The second rule exists because of how the CLI validates these settings (observed with CLI 2.1.287). When one sandbox value fails its settings schema, the CLI discards the **whole** `--settings` value: the sandbox, and everything you passed in `settings:` next to it, `permissions` rules included. The CLI reports the failure in the `errors` of its `get_settings` control response, and the SDK does not surface that: `connect` succeeds, nothing appears on stderr, and the session runs unsandboxed. That applies to a value written under the CLI's own name (`excludedCommands: 'docker'`) and to the typed classes, which send each value as you gave it: `SandboxSettings.new(excluded_commands: 'docker')` leaves the session without a sandbox.

`enabled: true` asks for a sandbox. It does not make one a requirement. When the sandbox cannot start on the host (missing dependencies, an unsupported platform), the CLI carries on without it. Its settings schema describes the setting that decides this, `failIfUnavailable`, as follows (CLI 2.1.287):

> Exit with an error at startup if sandbox.enabled is true but the sandbox cannot start (missing dependencies or unsupported platform). When false (default), a warning is shown and commands run unsandboxed.

The SDK sends your sandbox settings as you wrote them and does not add this one. If commands must never run unsandboxed, set it yourself:

```ruby
sandbox = ClaudeAgentSDK::SandboxSettings.new(enabled: true, fail_if_unavailable: true)
```

Without it, the sign is the CLI's warning on stderr ("Sandbox disabled: ... Commands will run WITHOUT sandboxing. Network and filesystem restrictions will NOT be enforced."), and stderr reaches your code only through the `stderr` (or `debug_stderr`) option. This is the CLI's own description of its behavior: the fallback has not been reproduced in this SDK's testing, where the sandbox was always available.

See [examples/sandbox_example.rb](https://github.com/rubycatco/claude-agent-sdk-ruby/blob/main/examples/sandbox_example.rb).

When the `sandbox:` option enabled the sandbox and the CLI reports `Sandbox disabled: …` on its stderr, the SDK repeats that line as a Ruby warning prefixed `[claude-agent-sdk]`, once per session, whether or not you set `stderr:`.

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

See [examples/bare_mode_example.rb](https://github.com/rubycatco/claude-agent-sdk-ruby/blob/main/examples/bare_mode_example.rb).

## Verbatim Prompts

Claude Code expands an `@/absolute/path` token anywhere in a user message into
that file's contents, and dispatches a leading `/name` as a slash command. The
expansion happens before the model runs and without a tool call, so `tools: []`,
`allowed_tools` and `disallowed_tools` do not stop it. If your prompt includes
text your end user did not type (earlier turns, tool output, third-party
content), set `verbatim_prompts` so that text cannot make Claude Code read a
local file:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(verbatim_prompts: true)
ClaudeAgentSDK.query(prompt: text_that_may_contain_at_paths, options: options) { |message| ... }
```

Every user message the SDK writes is then marked `client_composed`, and Claude
Code delivers it exactly as written. That covers String prompts and every
message of a streamed prompt, through `ClaudeAgentSDK.query`, `Client#connect`
and `Client#query`.

- **No per-message opt-out.** A `client_composed` key on a streamed message
  Hash is overwritten. For per-turn control, leave the option off and set
  `client_composed: true` on individual streamed messages.
- Your message Hashes are never mutated.
- A streamed JSONL String is parsed, marked and re-serialized. One that is not
  a single JSON object raises `ArgumentError` instead of going out unmarked
  (on the background streaming paths the stream stops with a warning, like any
  stream error).
- `Client` reads the option once, at `connect`.
- **It skips more than `@path` expansion.** On current Claude Code versions a
  turn delivered this way skips the whole turn-start attachment pass:
  `@server:resource` MCP mentions are not expanded, and the prompt goes without
  the context Claude Code normally attaches (nested `CLAUDE.md` and rules files,
  skill and tool listings, other per-turn reminders). The pass between tool
  calls still runs, so most of that context arrives after the turn's first tool
  call.
- Requires Claude Code **2.1.248** or later. Older versions ignore the field
  and still expand prompts; the SDK prints a warning when it connects to one
  with the option on.

Matches the Python SDK's `verbatim_prompts`.

## Session Isolation

Claude Code keeps an **auto-memory** for each project: Markdown notes and an
index file, `<config dir>/projects/<project key>/memory/MEMORY.md`. It is a
CLI feature, it is on by default, and SDK sessions take part in it. If one
process runs sessions for more than one user or tenant, three things follow:

- **Every session reads the index.** The CLI puts `MEMORY.md` into the context
  of every session of that project, under the same heading as `CLAUDE.md` (in
  CLI 2.1.287: "IMPORTANT: These instructions OVERRIDE any default behavior
  and you MUST follow them exactly as written"). That holds with the SDK's
  default (empty) system prompt and with `tools: []`. `setting_sources: []`
  does not change it either: that option selects the user, project and local
  sources (their settings files and their `CLAUDE.md` files), and the
  auto-memory is not one of them.
- **A session on the `claude_code` preset also writes it.** The preset system
  prompt includes instructions for keeping memories, so a message such as
  "remember that ..." makes the model save a note and update the index with
  its file tools. The CLI allows those writes by itself: in testing (CLI
  2.1.286) they succeeded in the default permission mode with no
  `can_use_tool` callback, no hook and no allow rule. Do not count on your
  permission setup to stop them. With the SDK's default system prompt the
  sessions tested only read the index: asked to remember something, they
  wrote nothing (an observation, not a guarantee).
- **The memory belongs to the project, not to the session.** The project key
  is the root of the git repository that contains the working directory, so
  every subdirectory and every git worktree of one repository shares one
  memory directory. Outside a repository the key is the working directory
  itself.

So on a server that runs every user's session from one checkout and one config
directory with the `claude_code` preset, what one user asks the agent to
remember can be saved without a permission check and then reach every later
session as an instruction. With the default system prompt the exposure is the
read side: whatever memory already exists for that project and config
directory, a developer's own for instance, is in every session's context.

### Turning auto-memory off

Servers and multi-tenant hosts should switch it off. Both forms work with
`query()` and `Client`:

```ruby
# An environment variable for the CLI process
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }
)

# Or the CLI setting
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  settings: { autoMemoryEnabled: false }
)
```

To apply it to every session, set it as a default (a per-call `env` Hash is
merged into the configured one):

```ruby
ClaudeAgentSDK.configure do |config|
  config.default_options = { env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' } }
end
```

- The variable must be `'1'`. `'0'` and `'false'` do not mean "the default":
  they force auto-memory **on** and override `autoMemoryEnabled: false`.
- `bare: true` turns auto-memory off as well, but bare mode never reads an
  OAuth login or the keychain: it authenticates with `ANTHROPIC_API_KEY` (or
  an `apiKeyHelper` setting) only. See [Bare Mode](#bare-mode).
- Both switches reach the CLI that `query()` and `Client` start themselves,
  through the default `SubprocessCLITransport`: it puts `env` into the CLI's
  environment and `settings` on its command line (`--settings`).
- A [custom transport](client.md#custom-transport) starts the CLI its own way,
  so neither switch reaches that CLI unless the transport passes it through:
  `env` into the environment it gives the CLI, `settings` onto the command
  line (a transport that builds its command line with `CommandBuilder` gets
  `--settings` from it; one that does not, has to add it). Until then the
  session is not isolated.

### What does not isolate sessions

- **A different `cwd`** separates the memory only when the two directories
  are not in the same git repository.
- **A different `CLAUDE_CONFIG_DIR`** separates it only when the two config
  directories do not share `projects/` (a `projects/` that is a symlink to
  another config directory's is shared). A new config directory also has no
  login, so give the CLI `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`
  (in the process environment or in `env`).
- **`setting_sources: []`** keeps the user, project and local settings and
  `CLAUDE.md` files out of a session. The auto-memory index still loads. So
  do the MCP servers connected to the claude.ai account the CLI is logged in
  with: `strict_mcp_config: true` is what limits a session to the servers in
  `mcp_servers` (see the [options reference](options.md#strict_mcp_config)).

"One working directory per tenant" is therefore not enough on its own. Use the
switch.

### Checking what a session loaded

`Client#context_usage` reports the files in a session's context without a
model call. The auto-memory index is the entry whose `:type` is `"AutoMem"`:

```ruby
ClaudeAgentSDK::Client.open(options: options) do |client|
  client.context_usage.fetch(:memoryFiles, []).each do |file|
    puts "#{file[:type]} #{file[:path]} (#{file[:tokens]} tokens)"
  end
end
# AutoMem /home/app/.claude/projects/-srv-app/memory/MEMORY.md (27 tokens)
```

With auto-memory off the list has no `AutoMem` entry. `query()` has no
equivalent; run the check through a `Client` with the same options.

## Forwarding Subagent Text

By default only `tool_use` / `tool_result` blocks from subagents (spawned via
the Agent tool) reach the message stream, as `AssistantMessage` /
`UserMessage` objects whose `parent_tool_use_id` is the spawning Agent
`tool_use` id — enough for a progress heartbeat. Set `forward_subagent_text`
to forward the subagent's **text and thinking** blocks the same way, so you
can render the full nested transcript:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(forward_subagent_text: true)
```

Matches the TypeScript SDK's `forwardSubagentText`. The capability is
negotiated on the control-protocol handshake, so it applies to both
`ClaudeAgentSDK.query` and `Client`.

## Subagent Progress Summaries

Set `agent_progress_summaries` to **request** model-generated one-line progress
summaries for subagent (`local_agent`) tasks. While the CLI has generation
enabled, a subagent's `TaskProgressMessage#summary` **may** be present; the
field stays optional on the wire, so not every progress frame carries one —
read it nil-safely:

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(agent_progress_summaries: true)

# ...
when ClaudeAgentSDK::TaskProgressMessage
  puts "#{message.task_id}: #{message.summary}" if message.summary
```

`false` and `nil` do not enable generation. They do not promise suppression
either: a process that already enabled summaries keeps producing them, and a
backgrounded `mcp_task` reports its own status in `summary` regardless of this
option.

The option is tri-state: `nil` (the default) omits the key from the `initialize`
control request, while `true` and `false` are forwarded verbatim as
`agentProgressSummaries`. It is an **enable switch, not a live toggle**: CLI
2.1.278 only acts on a truthy value, so `false` is schema-valid but equivalent
to leaving the option unset — it does not switch summaries off on a process that
already enabled them. With `ClaudeAgentSDK.configure` defaults, a per-call
`false` overrides a global `true`, and an unset per-call value inherits the
global one. It applies to both `ClaudeAgentSDK.query` and `Client`. The key was
read from the schema embedded in Claude Code CLI 2.1.278 and has not been
verified against a live run. See
[subagent capabilities](subagents.md).

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
