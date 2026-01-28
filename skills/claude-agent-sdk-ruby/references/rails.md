# Rails integration patterns

Use `ClaudeAgentSDK::Client` when you need streaming chunks, long-running tasks, or session resumption.

## Stream chunks to the frontend (ActionCable)

Run the agent in an `ActiveJob`, broadcast assistant text as it arrives, and finalize on `ResultMessage`.

Key ideas:
- Wrap SDK calls in `Async do ... end.wait`.
- Extract text from `AssistantMessage` content blocks.
- Broadcast `ResultMessage` fields (final `result`, `total_cost_usd`, `session_id`).

## Session resumption

Persist `ResultMessage#session_id`, then pass it back via `ClaudeAgentOptions#resume`.

## Background job error handling

Rescue and/or retry on SDK errors such as:
- `ClaudeAgentSDK::CLINotFoundError` (Claude Code CLI missing)
- `ClaudeAgentSDK::ProcessError` (CLI exited non-zero)
- `ClaudeAgentSDK::CLIConnectionError` (transport/connect problems)

## Where to look for full examples

If you have the gem repo checked out, scan the `examples/` folder for:
- ActionCable streaming
- background jobs
- session resumption
