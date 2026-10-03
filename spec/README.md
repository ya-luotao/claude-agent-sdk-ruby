# Test Suite

This directory contains the test suite for the Claude Agent SDK for Ruby.

## Running Tests

```bash
bundle exec rspec                                   # the default suite (spec/, without spec/rails)
bundle exec rspec spec/unit/message_parser_spec.rb  # one file
bundle exec rspec spec/unit/types_spec.rb:42        # one example
bundle exec rspec --seed 81                         # a given order (the suite runs in random order)
COVERAGE=1 bundle exec rspec                        # with a simplecov report in coverage/
PROFILE=1 bundle exec rspec                         # and the 10 slowest examples
```

The other bundles (`gemfiles/floor.gemfile`, `gemfiles/latest.gemfile`), the Rails specs, `rake rbs:test` and RuboCop are described in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Layout

### `spec/unit/`

One file per area of `lib/`, e.g. `query_spec.rb`, `subprocess_cli_transport_spec.rb`, `sdk_mcp_server_spec.rb`, `sessions_spec.rb`, `types_spec.rb`. Most of them drive one object with doubles. A few go further on purpose:

- **Through the control protocol, in process**: `query_hook_input_spec.rb` (the typed input of every hook event), `query_sdk_mcp_messages_spec.rb` (the JSON-RPC exchange with an SDK MCP server) and `query_permission_result_spec.rb` (a `can_use_tool` callback that returns something else than a `PermissionResult`) open a real `Client` on `ScriptedCLI` and assert on the frames the SDK writes back.
- **Against a real child process**: `subprocess_cli_transport_fake_cli_spec.rb` runs `SubprocessCLITransport` and one `query()` against `FakeClaude`, with nothing stubbed.
- **In child processes**: `callback_process_exit_spec.rb` runs every cell of `CallbackExitHarness` in its own Ruby process, because those cells end the process with `exit` or a signal.

### `spec/integration/`

Both files spawn the real `claude` binary and are skipped by default.

- **`real_cli_integration_spec.rb`** makes live, budget-capped API calls. It is tagged `:integration` and runs only with `RUN_INTEGRATION=1` (`RUN_REAL_INTEGRATION` is accepted as a legacy alias); it then skips itself when `claude` is not on `PATH` or `ANTHROPIC_API_KEY` is unset:

  ```bash
  RUN_INTEGRATION=1 ANTHROPIC_API_KEY=... bundle exec rspec spec/integration/real_cli_integration_spec.rb
  ```

- **`keyless_smoke_spec.rb`** needs no credentials and reaches no model: with a fresh `HOME` and `CLAUDE_CONFIG_DIR` it completes the `initialize` handshake and checks that a prompt the CLI cannot send comes back as a `ResultError`. It runs only with `RUN_KEYLESS_SMOKE=1` and, once enabled, skips nothing (a missing CLI fails). It finds the CLI the way the SDK does (`CLAUDE_CLI_PATH`, the vendored install, `PATH`):

  ```bash
  bundle exec rake claude_agent_sdk:install_cli   # the pinned CLI, into vendor/claude
  RUN_KEYLESS_SMOKE=1 bundle exec rspec spec/integration/keyless_smoke_spec.rb
  ```

  When you run it from a shell that is itself inside Claude Code, start it under `env -i` with only `HOME`, `PATH` and `LANG`: that shell exports `CLAUDE_CODE_*` variables the CLI child would inherit.

The workflow `.github/workflows/integration.yml` runs the keyless smoke on every trigger, and the live suite only when the repository has an `ANTHROPIC_API_KEY` secret.

### `spec/rails/`

Railtie, `claude_agent_sdk:install_cli` rake task, install generator and `Railtie.callback_wrapper`. They load railties/ActiveSupport, which patch core classes process-wide, so the root `.rspec` excludes `spec/rails` from the default run; they run in their own process against a Rails bundle, with `spec/rails/.rspec` replacing the root options:

```bash
BUNDLE_GEMFILE=gemfiles/rails_8.gemfile bundle exec rspec --options spec/rails/.rspec    # latest Rails 8
BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle exec rspec --options spec/rails/.rspec  # Rails 7.1 floor
```

### `spec/examples/`

The SessionStore reference adapters under `examples/session_stores/`. The S3 one runs against an in-process fake; the Redis and Postgres ones are live-only and filter themselves out unless their client gem is installed (the optional `examples` Bundler group) and a server is reachable (see the comment at the top of each file).

## Test Helpers (`spec/support/`)

`spec_helper.rb` requires every file here.

- **`test_helpers.rb`** (included in every example group): `sample_user_message`, `sample_assistant_message`, `sample_assistant_message_with_tool_use`, `sample_result_message` and `sample_system_message` return small message Hashes with Symbol keys, the key style the transport yields (they are trimmed, not copies of real frames); `mock_transport` takes no arguments and returns a double whose `connect`, `close`, `write`, `ready?` and `end_input` are stubbed. An example that needs `read_messages` stubs it on that double itself (`query_run_end_spec.rb` feeds it from a queue). `connect_draining_stderr(transport)` runs `#connect` over a stubbed `Open3.popen3` and waits for the stderr drain thread it starts.
- **`scripted_cli.rb`** — `ScriptedCLI`, the CLI's end of the control protocol in process. `ScriptedCLI.session(options) { |cli, client| ... }` opens a real `Client` on it; `cli.request(...)` sends a control request (`hook_callback`, `can_use_tool`, `mcp_message`) and returns the control response the SDK wrote; `initialize` is answered the way CLI 2.1.286 answers it.
- **`fake_claude.rb`** — `FakeClaude`, a stand-in for the `claude` executable: a plain-Ruby child process that speaks the stream-JSON protocol. `FakeClaude.install(dir)` writes the executable and returns its absolute path for `cli_path:`; `FakeClaude.env(scenario:, log:)` selects what the child does (a conversation, a slow exit after stdin EOF, a process that ignores EOF and SIGTERM, stderr lines followed by a failure, an immediate exit); `FakeClaude.events(log)` reads back what the child received and did.
- **`callback_exit_harness.rb`** — `CallbackExitHarness`, the child-process side of `callback_process_exit_spec.rb`.

## Conventions

- `expect` syntax only (`disable_monkey_patching!`), random order, and status persisted to `.rspec_status` for `--only-failures` / `--next-failure`.
- An example must not leave anything in `SubprocessCLITransport`'s at-exit process registry: a check in `spec_helper.rb` fails the example that does, and empties the registry for the next one.
- No background thread may read an rspec double. A double expires with its example; a thread that outlives the example dies on its next call, and Ruby prints the report on `$stderr` in whichever example is running then, which fails an `output.to_stderr` matcher there. `#connect` starts such a thread (the stderr drain): an example that stubs `Open3.popen3` returns `StringIO`s for stdout and stderr and connects through `connect_draining_stderr`.
- Synchronize on events, never on the clock: a queue, a barrier, the child's own output. `sleep` to "let things settle" makes an example pass or fail with the machine's load.
- Bound every wait that a regression could turn into a hang (`task.with_timeout`, `Thread#join(seconds)`, `Queue#pop(timeout:)`), and stop or kill whatever is left waiting, so a hang fails the example instead of the run. CI jobs also have a time limit.
- Fixtures should look like what the real CLI sends: same keys, same nesting. Several bugs hid behind hand-simplified frames.
- Examples that pass values outside the RBS signatures on purpose carry `rbs_incompatible: '<reason>'` metadata, which `rake rbs:test` skips (see CONTRIBUTING.md).

## Troubleshooting

### A test hangs

Run it alone with `--format documentation` to see which example it is. A hang usually means something waits without a bound: a process that does not exit, a task left parked on a condition, a queue that is never fed.

### LoadError or require failures

Ensure dependencies are installed:

```bash
bundle install
```

If `bundle exec` cannot find gems that `bundle install` just installed, see the note on version managers in CONTRIBUTING.md.

### Integration tests are skipped

`real_cli_integration_spec.rb` needs `RUN_INTEGRATION=1`, `ANTHROPIC_API_KEY` and `claude` on `PATH`; `keyless_smoke_spec.rb` needs `RUN_KEYLESS_SMOKE=1` and a CLI (see above). Check the CLI with:

```bash
which claude
claude -v
```
