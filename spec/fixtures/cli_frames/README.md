# Recorded CLI frames

Each `.jsonl` file is the stdout of one real `claude` run in stream-JSON mode: one frame per line, in the order the CLI wrote them, as `SubprocessCLITransport#read_messages` yields them. Specs replay these instead of hand-building frames because the shape is the point. The CLI sends one `assistant` frame per content block, and every frame of one API response repeats that response's `message.id` and `usage`; a hand-built message that holds a whole response in one frame hides bugs that only show with the real shape.

| File | CLI | What it holds |
| --- | --- | --- |
| `tool_turn.jsonl` | 2.1.286 | One prompt. Response 1 is a thinking frame and a `tool_use` (Bash) frame, then the tool result; response 2 is a thinking frame and a text frame; then the `result`. |

## What a recording keeps and what it does not

A recording is sanitized before it is committed.

- **Left out:** the `control_response` that answers `initialize` (the first line the CLI writes). It lists the installed commands, agents and models and names the account. `Query` consumes it, so no message consumer or observer ever sees it.
- **Replaced with placeholders:** every text, thinking signature, tool input and tool output, and the result text; the session id and the per-frame `uuid`s; the local paths in `init` (`cwd`, `memory_paths`, `scratchpad_path`, `messaging_socket_path`); the rate-limit utilization figures.
- **Trimmed:** the `tools`, `slash_commands`, `skills`, `agents` and `plugins` lists in `init`.
- **Kept as recorded:** the order, type and keys of every frame; `message.id`, tool-use ids and request ids; the model; usage, cost and duration numbers; stop reasons; timestamps.

When you add a recording, read the sanitized file line by line before committing it.
