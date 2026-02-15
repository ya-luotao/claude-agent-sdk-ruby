# Troubleshooting

## Claude Code CLI not found

Symptoms:
- `ClaudeAgentSDK::CLINotFoundError`

Fix:
- Install Claude Code CLI (Node.js required).
- If the CLI is installed in a non-standard path, set `ClaudeAgentSDK::ClaudeAgentOptions#cli_path`.

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
- Add the tool to `allowed_tools` (or `append_allowed_tools`).
- Use an appropriate `permission_mode` (for example `acceptEdits` for file edits).
- If using MCP tools, include `mcp__server__tool` in `allowed_tools`.

## Permission callback not firing

Checks:
- Use `ClaudeAgentSDK::Client` (streaming mode).
- `ClaudeAgentSDK.query` does not support `can_use_tool` (use `ClaudeAgentSDK::Client`).
- Do not combine `can_use_tool` with `permission_prompt_tool_name`.

## No assistant text printed

Checks:
- Extract text from `AssistantMessage#content` blocks (only `TextBlock` has `.text`).
- Stop only after `ResultMessage` so you do not exit early.
