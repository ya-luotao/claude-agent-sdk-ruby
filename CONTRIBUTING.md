# Contributing

Thanks for helping out. This is a community-maintained Ruby SDK for the Claude Code CLI; bug reports, fixes and parity ports from the official SDKs are all welcome.

## Setup

You need Ruby 3.2 or newer.

```bash
git clone https://github.com/ya-luotao/claude-agent-sdk-ruby.git
cd claude-agent-sdk-ruby
bundle install
bundle exec rake          # unit suite + RuboCop, the same checks as CI's main leg
```

Some notes on the environment:

- `Gemfile.lock` is gitignored, as is usual for a gem. Your bundle resolves fresh, so if something fails that CI doesn't hit, run `bundle update` first. RuboCop is pinned to one minor version so local lint matches CI.
- If `bundle exec` can't find gems that `bundle install` just installed, your shell is probably running a different Ruby than the one you installed into. This happens with a version manager in a non-interactive shell. Run through the manager explicitly, e.g. `rbenv exec bundle exec rspec` (add `RBENV_VERSION=3.4.x` to pick a version), or the equivalent for mise, asdf or chruby.
- Two optional bundle groups are left out of a plain `bundle install`. `examples` holds the Redis/Postgres clients for the SessionStore example adapters, whose specs skip unless those gems load and a backend is reachable; enable it with `bundle config set --local with examples && bundle install`. `instrumentation` holds the OpenTelemetry SDK/exporter for the OTel examples only; the instrumentation spec uses its own mock and breaks if the real gem is on the load path.

## Running the specs

```bash
bundle exec rspec                               # unit suite (spec/, excluding spec/rails)
bundle exec rspec spec/unit/query_spec.rb:42    # one example
COVERAGE=1 bundle exec rspec                    # with a simplecov report in coverage/
bundle exec rubocop                             # lint
```

**Rails specs** (`spec/rails/`) load railties, which patch core classes, so they run in their own process against a Rails bundle:

```bash
BUNDLE_GEMFILE=gemfiles/rails_8.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8.gemfile bundle exec rspec --options spec/rails/.rspec     # latest Rails 8
BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle exec rspec --options spec/rails/.rspec   # Rails 7.1 floor
```

`gemfiles/floor.gemfile` and `gemfiles/latest.gemfile` work the same way (plain `bundle exec rspec`). They pin the oldest supported runtime dependencies and the newest allowed majors.

**Real-CLI integration specs** (`spec/integration/`) spawn the actual `claude` binary and make live API calls, each capped by `max_budget_usd`. They are skipped unless you opt in, and they skip themselves when `claude` isn't on `PATH` or `ANTHROPIC_API_KEY` is unset:

```bash
bundle exec rake claude_agent_sdk:install_cli   # optional: the pinned CLI, into vendor/claude
PATH="$PWD/vendor/claude:$PATH" RUN_INTEGRATION=1 ANTHROPIC_API_KEY=... bundle exec rspec spec/integration
```

Run them when you change anything on the CLI wire protocol (the transport, `Query`, the control protocol, `CommandBuilder`). CI also runs them weekly, and on PRs that touch `cli_installer.rb`, against the pinned CLI version.

CI runs the unit suite and RuboCop on Ruby 3.2, 3.3 and 3.4 (Linux), the unit suite on macOS, the dependency floor and latest legs, and the Rails specs on Rails 7.1 and 8. See [`.github/workflows/`](.github/workflows/).

## Pull requests

- **Keep each PR to one change.** A bug fix, a feature or a refactor, not all three. Say in the description why the change is needed and how you verified it.
- **Bug reports and fixes come with a spec.** A failing spec that reproduces the bug is the most useful bug report there is. A fix PR should include one that fails before the fix and passes after.
- **Add a CHANGELOG entry** under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for anything a gem user would notice (Added / Changed / Fixed / Deprecated). Internal-only changes can skip it.
- **Update the docs** when you change public behavior: `docs/`, the README, and YARD comments on the methods you touched.
- `bundle exec rake` must pass. New code follows the existing conventions: plain classes with `attr_accessor` and keyword arguments, `to_h` emitting camelCase for the CLI, user callbacks dispatched through `FiberBoundary.invoke`, and RSpec's `expect` syntax.

### Porting from the Python SDK

Much of this gem tracks the official [Python SDK](https://github.com/anthropics/claude-agent-sdk-python). When you port a feature or fix from it:

- Reference the Python PR number in the commit message and PR description, e.g. `Add list_subagents (Python #825)`.
- Adapt the Python idioms rather than transliterating them: snake_case keyword arguments, plain classes, and specs that mirror the Python tests.
- Update the capability table in the README if the feature appears there.

The full workflow (gap analysis, branch naming, recording what was skipped and why) is in [`.claude/skills/port-python-parity/SKILL.md`](.claude/skills/port-python-parity/SKILL.md).

## Security issues

Please don't open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
