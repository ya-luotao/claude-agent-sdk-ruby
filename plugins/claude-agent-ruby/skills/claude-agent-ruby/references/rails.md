# Rails integration patterns

Use `ClaudeAgentSDK::Client` when you need streaming chunks, long-running tasks, or session resumption.

## Configure defaults once (initializer)

Set shared defaults in `config/initializers/claude_agent_sdk.rb` so jobs/services stay consistent:

```ruby
ClaudeAgentSDK.configure do |config|
  config.default_options = {
    model: 'claude-sonnet-4-5',
    permission_mode: 'bypassPermissions',
    env: { 'ANTHROPIC_API_KEY' => ENV.fetch('ANTHROPIC_API_KEY') }
  }
end
```

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
- `ClaudeAgentSDK::ControlRequestTimeoutError` (control protocol request exceeded timeout)

For long-running agent orchestration, tune timeout via:

```bash
export CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS=1800
```

## Where to look for full examples

If you have the gem repo checked out, scan the `examples/` folder for:
- ActionCable streaming
- background jobs
- session resumption
