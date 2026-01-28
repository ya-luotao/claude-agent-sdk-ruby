# Troubleshooting

## Claude Code CLI not found

Symptoms:
- `ClaudeAgentSDK::CLINotFoundError`

Fix:
- Install Claude Code CLI (Node.js required).
- If the CLI is installed in a non-standard path, set `ClaudeAgentSDK::ClaudeAgentOptions#cli_path`.

## Tool calls not working

Checks:
- Add the tool to `allowed_tools` (or `append_allowed_tools`).
- Use an appropriate `permission_mode` (for example `acceptEdits` for file edits).
- If using MCP tools, include `mcp__server__tool` in `allowed_tools`.

## Permission callback not firing

Checks:
- Use `ClaudeAgentSDK::Client` (streaming mode).
- Do not pass a plain string prompt to `Client#connect` when using `can_use_tool`.
- Do not combine `can_use_tool` with `permission_prompt_tool_name`.

## No assistant text printed

Checks:
- Extract text from `AssistantMessage#content` blocks (only `TextBlock` has `.text`).
- Stop only after `ResultMessage` so you do not exit early.
