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
bundle exec rake rbs:validate                   # the RBS signatures in sig/ parse and resolve
bundle exec rake rbs:test                       # the suite under rbs's runtime type checker (slower)
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

CI runs the unit suite and RuboCop on Ruby 3.2, 3.3 and 3.4 (Linux), the unit suite on macOS, the dependency floor and latest legs, and the Rails specs on Rails 7.1 and 8. The Ruby 3.4 Linux leg also runs `rake rbs:validate`, and a separate job runs `rake rbs:test`. See [`.github/workflows/`](.github/workflows/).

## Pull requests

- **Keep each PR to one change.** A bug fix, a feature or a refactor, not all three. Say in the description why the change is needed and how you verified it.
- **Bug reports and fixes come with a spec.** A failing spec that reproduces the bug is the most useful bug report there is. A fix PR should include one that fails before the fix and passes after.
- **Add a CHANGELOG entry** under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for anything a gem user would notice (Added / Changed / Fixed / Deprecated). Internal-only changes can skip it.
- **Update the docs** when you change public behavior: `docs/`, the README, YARD comments on the methods you touched, and their RBS signatures in `sig/` (see [RBS signatures](#rbs-signatures-sig)).
- `bundle exec rake` must pass. New code follows the existing conventions: plain classes with `attr_accessor` and keyword arguments, `to_h` emitting camelCase for the CLI, user callbacks dispatched through `FiberBoundary.invoke`, and RSpec's `expect` syntax.

### What is public API

From 1.0 on, SemVer covers everything documented in `docs/` and the README, plus every class, module, method and constant that appears in the YARD docs. Anything tagged `@api private` is excluded: it is hidden from the generated docs (`.yardopts` passes `--hide-api private`) and can change or disappear in any release. It stays callable at runtime; the tag is documentation only.

When you add an internal (a helper module, a constant, a method the SDK calls on itself), tag it:

```ruby
# Explains what the helper does.
#
# @api private
module SomeInternalHelper
```

- Put `@api private` on a line of its own. `# @api private Called by Query` sets the API name to "private Called by Query", which the filter doesn't hide.
- A tag on a class or module covers everything nested inside it, so one tag hides a whole internal namespace.
- Every constant needs its own tag. A comment attaches only to the constant directly below it.
- If a class is public but some of its methods aren't (as with `SubprocessCLITransport`), tag those methods one by one.
- To check the result, run `bundle exec yard list` and confirm that the object you tagged is gone from the list.

### RBS signatures (`sig/`)

The gem ships [RBS](https://github.com/ruby/rbs) signatures for exactly that public surface: `sig/claude_agent_sdk.rbs` has the module functions, `Client` and the shared type aliases and interfaces, and `sig/claude_agent_sdk/` has one file per area, with `types/` mirroring `lib/claude_agent_sdk/types/`. When you add, change or remove something public, update its signature in the same PR:

- **Only public objects get a signature.** Never add one for an `@api private` object, since that would freeze it. If a public signature has to mention an internal or third-party object, use a narrow interface or `untyped` with a comment saying why.
- **Duck types are interfaces.** Transports (`_Transport`), session stores (`_SessionStore`, with the optional methods listed in its comment), and every user callback (`_CanUseTool`, `_HookCallback`, `_ToolHandler`, `_CallbackWrapper`, ...) are interfaces, so any object with the right methods fits, including a `Method` or a custom class. A proc type (`^(...) -> ...`) would accept only a `Proc`.
- **Follow the Hash-key rule** in [docs/types.md](docs/types.md#hash-keys): use `wire_hash` (`Hash[Symbol, untyped]`) for a Hash passed through from the CLI stream and `transcript_hash` (`Hash[String, untyped]`) for transcript and store data.
- **Type attributes are nilable.** A `Type` can be built empty, and the SDK parses CLI output leniently, so an attribute reads `nil` whenever the CLI did not send it.
- **Use `void` for a return value the docs don't promise.** It keeps the return value out of the contract, and the runtime checker skips it.
- **Deprecated methods keep their signature** until they are removed, marked with a `# @deprecated` comment.

Then run both checks:

```bash
bundle exec rake rbs:validate   # every file parses, every referenced type exists
bundle exec rake rbs:test       # the suite again, with every call into a signed class or module type-checked
```

`rbs:test` loads `rbs/test/setup` into the spec run, so a signature that disagrees with what the code actually receives or returns fails the example that made the call. Some examples pass values outside the signatures on purpose: bad input that must be rejected, `Object.new` sentinels, a stubbed internal that returns a placeholder, or an assertion on a warning's `file:line` (the checker's wrapper frames change it). Tag those with `rbs_incompatible: '<reason>'` so `rbs:test` skips them, and fix the signature instead whenever the value is one a user could legitimately pass.

### Porting from the Python SDK

Much of this gem tracks the official [Python SDK](https://github.com/anthropics/claude-agent-sdk-python). When you port a feature or fix from it:

- Reference the Python PR number in the commit message and PR description, e.g. `Add list_subagents (Python #825)`.
- Adapt the Python idioms rather than transliterating them: snake_case keyword arguments, plain classes, and specs that mirror the Python tests.
- Update the capability table in the README if the feature appears there.

The full workflow (gap analysis, branch naming, recording what was skipped and why) is in [`.claude/skills/port-python-parity/SKILL.md`](.claude/skills/port-python-parity/SKILL.md).

## Security issues

Please don't open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
