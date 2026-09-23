# Troubleshooting

## Claude Code CLI not found

Symptoms:
- `ClaudeAgentSDK::CLINotFoundError`

Fix:
- Install Claude Code CLI (Node.js required), or vendor a pinned binary with `ClaudeAgentSDK::CLIInstaller.install_pinned` (0.34.0+; installs the CLI version the gem release was tested against, `CLIInstaller::PINNED_CLI_VERSION`) or `CLIInstaller.install(version: 'x.y.z')` for a concrete pin of your own (`'stable'`, the default, and `'latest'` are floating dist-tags that re-resolve on every install). Downloads into `vendor/claude/`; discovery prefers it over `PATH` — since 0.30.0.
- If the CLI is installed in a non-standard path, set `ClaudeAgentSDK::ClaudeAgentOptions#cli_path` (see `references/options.md`) or the `CLAUDE_CLI_PATH` environment variable.

## Session APIs fail in a container without a home directory

Symptoms:
- `ClaudeAgentSDK::ConfigDirError` from `list_sessions`, `get_session_*`, `rename_session` and the other local-disk session APIs
- With a `session_store`, a `MirrorErrorMessage` (nil `key`) per turn saying the Claude config directory is unknown

Fix:
- The host has no usable home (`HOME` unset with no passwd entry, as under `docker --user` in a minimal image, or an empty/relative `HOME`), so the default `~/.claude` cannot be located. Set `CLAUDE_CONFIG_DIR` in the environment (or in `options.env` for the subprocess and the transcript mirror).

## Control requests timing out

Symptoms:
- `ClaudeAgentSDK::ControlRequestTimeoutError`

Checks and fixes:
- Increase control timeout for long-running sessions:
```bash
export CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS=1800
```
- Tune for your workload; default is 1200 seconds.
- Rescue `ControlRequestTimeoutError` in jobs/workers and retry when appropriate.
- Review long-running hooks, permission callbacks, or MCP tools that may delay control responses.

## Tool calls not working

Checks:
- Add the tool to `allowed_tools` — see `references/options.md` (Tools and permissions).
- Use an appropriate `permission_mode` (for example `acceptEdits` for file edits).
- If using MCP tools, include `mcp__server__tool` in `allowed_tools` — see `references/mcp-servers.md`.

## Permission callback not firing

Checks:
- Since 0.31.0 both `ClaudeAgentSDK.query` (String prompt included) and `ClaudeAgentSDK::Client` support `can_use_tool` — see `references/options.md` (Permission callback). Before 0.31.0, `query` raised `ArgumentError` for it.
- Do not combine `can_use_tool` with `permission_prompt_tool_name`.
- **Something auto-approved before the callback.** The callback only runs when the permission ladder lands on "ask". An `allowed_tools` entry allowing a whole tool, `permission_mode: 'bypassPermissions'`, or a settings-file rule short-circuits it. The SDK warns to stderr about the rules it can see, but **settings files are invisible to it** — a user-level `permissions.defaultMode: auto` in `~/.claude/settings.json` silently auto-approves with no warning. Pass `setting_sources: []` to isolate from user/project settings when testing a callback.

## Resume fails with an opaque error

- A refused or invalid resume (nonexistent session, or a `resume_drops_turn` guard failure) raises `ResultError` (0.31.0+) carrying the CLI's own reason. Before 0.31.0 this surfaced as a bare `ProcessError` "exit code 1" with the reason discarded — including on the initial handshake.
- Match `Resume rejected by --resume-drops-turn:` in the message and treat it as deterministic: clear the fork target and resume plainly instead of retrying the same request.

## Unknown content block or message types

Since v0.7.2, the SDK gracefully handles unrecognized types:
- Unknown content block types (e.g., `document` from PDF reading) return `UnknownBlock` instead of raising.
- Unknown message types return `nil` and are skipped.
- If you were rescuing `MessageParseError` for unknown types, switch to checking for `UnknownBlock` or `nil`.

## No assistant text printed

Checks:
- Extract text from `AssistantMessage#content` blocks (only `TextBlock` has `.text`) — see `references/message-handling.md`.
- Stop only after `ResultMessage` so you do not exit early.
