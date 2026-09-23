# Rails integration patterns

Use `ClaudeAgentSDK::Client` when you need streaming chunks, long-running tasks, or session resumption.

## Set up (generator + vendored CLI)

```bash
bin/rails generate claude_agent_sdk:install   # config/initializers/claude_agent_sdk.rb + /vendor/claude/ in .gitignore
bin/rails claude_agent_sdk:install_cli        # PINNED_CLI_VERSION into Rails.root/vendor/claude
bin/rails claude_agent_sdk:install_cli CLAUDE_CLI_VERSION=x.y.z   # or a version of your own ('stable' / 'latest')
```

The rake task does not boot the app, so it works as a Docker build step. The Railtie sets `ClaudeAgentSDK::CLIInstaller.root` to `Rails.root` (unless already set), so the vendored binary is found even when a worker's cwd is not the app root; set `CLIInstaller.root` in `config/application.rb` to override it for both discovery and the task. Outside Rails, `require 'claude_agent_sdk/tasks'` in a Rakefile gives the same task. The `Railtie` loads only when `Rails::Railtie` is defined and installs nothing implicitly.

## Configure defaults once (initializer)

Set shared defaults in `config/initializers/claude_agent_sdk.rb` so jobs/services stay consistent:

```ruby
ClaudeAgentSDK.configure do |config|
  config.default_options = {
    model: 'claude-sonnet-5',
    permission_mode: 'bypassPermissions',
    env: { 'ANTHROPIC_API_KEY' => ENV.fetch('ANTHROPIC_API_KEY') },
    # AR connections go back to the pool after each callback. Never a bare
    # `->(inv) { Rails.application.executor.wrap { inv.call } }`: that deadlocks
    # with development code reloading in the default :thread scheduling.
    callback_wrapper: ClaudeAgentSDK::Railtie.callback_wrapper
  }
end
```

## Stream chunks to the frontend (ActionCable)

Run the agent in an `ActiveJob`, broadcast assistant text as it arrives, and finalize on `ResultMessage`.

Key ideas:
- Use `ClaudeAgentSDK::Client.open(options: options) { |client| ... }` (own reactor, always disconnects); inside the block use `next`, not `break`.
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
