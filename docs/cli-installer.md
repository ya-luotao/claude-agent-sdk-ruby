# Vendoring the CLI (`CLIInstaller`)

The SDK runs the `claude` CLI as a subprocess, so a deploy is only reproducible if the CLI version is pinned with it. `ClaudeAgentSDK::CLIInstaller` downloads a pinned binary from the official release endpoint into a project-local directory (`vendor/claude` by default) — checksum-verified, no npm/Node at runtime, and nothing extra shipped inside the gem.

## Usage

```ruby
require 'claude_agent_sdk'

# Install the CLI version this gem release was tested against
# (CLIInstaller::PINNED_CLI_VERSION) — recommended: bumping the gem
# then carries the CLI forward with it, e.g. via Dependabot.
ClaudeAgentSDK::CLIInstaller.install_pinned
# => "/app/vendor/claude/claude"

# Or pin a concrete version of your own:
ClaudeAgentSDK::CLIInstaller.install(version: 'x.y.z', dir: '/opt/claude')

# 'stable' (the default) and 'latest' are floating dist-tags, not pins:
# they re-resolve on every call, so a rebuild may install a newer CLI.
ClaudeAgentSDK::CLIInstaller.install(version: 'stable')

# nil unless a binary is already installed there
ClaudeAgentSDK::CLIInstaller.installed_path
```

`install` is idempotent and safe to run concurrently, so it fits `bin/setup`, a cached Docker layer, and every process of a multi-process boot:

- The install directory's `VERSION` file records the installed version, verified SHA-256, and target platform (OS, architecture, libc). The shortcut re-hashes the vendored binary (~0.1s for the real 245MB binary) and only skips the download when all three match — a truncated binary or a cache copied from another platform is reinstalled instead of trusted. It makes **no network request**, so same-platform repeat boots work offline — with a pinned concrete version; `'stable'`/`'latest'` must always re-resolve through the endpoint, which is one more reason to pin in production. Older one- or two-line metadata lacks a platform and requires one online reinstall to migrate; subsequent pinned installs work offline again.
- An exclusive `flock` on `<dir>/.install.lock` covers the whole check → download → place → record sequence, so parallel installs into one directory don't race; the loser simply observes the finished install.

Failures (unsupported platform, invalid version, HTTP error, response-size cap, oversized download, checksum mismatch, filesystem errors) raise `ClaudeAgentSDK::CLIInstallError`.

**A failed install never breaks a working one.** The new binary is downloaded to a temp file, checksum-verified and recorded, and only then renamed into place — the rename is the last step, and nothing can fail after it. So a failed upgrade leaves the previously installed binary intact and runnable (the SDK keeps working), and the next `install` redoes it cleanly. A first install that fails leaves nothing behind at all.

## When the pin moves

`PINNED_CLI_VERSION` follows the CLI the Python SDK bundles. A bot PR moves it on `main`, usually within a few days, but the new pin reaches rubygems only with the next gem release: pin-only changes are batched rather than released one by one. A CLI security fix, or an SDK change that needs a newer CLI, gets a release sooner. Each release's CHANGELOG says when the pin moved. So `install_pinned` can trail the newest CLI by days. That is the price of installing the version the gem was tested with.

A gem upgrade can therefore move your CLI, even in a patch release. If Dependabot merges gem patches for you, check the CHANGELOG for a `PINNED_CLI_VERSION` entry: a new CLI can behave differently even where the SDK's API does not change.

To run a newer CLI before a gem release pins it, pin it yourself with `install(version: 'x.y.z')`, or `CLAUDE_CLI_VERSION=x.y.z` for the rake task and the `bin/setup` example below. Go back to `install_pinned` once a gem release catches up. `'stable'` and `'latest'` follow the newest CLI automatically, but they are not pins: a rebuild can pick up a different version.

## Where `vendor/claude` is

With no `dir:`, `install`, `install_pinned` and `installed_path` use `CLIInstaller.default_dir`: `vendor/claude` under `CLIInstaller.root`, or under the process's working directory at call time while `root` is unset (the default). Transport discovery uses the same directory, so installing and finding the binary agree.

Set `root` when a process that runs agents does not start in the project root — a daemonized worker, a job runner launched from `/`, a systemd unit without `WorkingDirectory=`. Otherwise that process looks for `vendor/claude` under its own working directory, misses the vendored binary, and falls through to whatever `claude` is on `PATH`:

```ruby
# early in boot, before the first query
ClaudeAgentSDK::CLIInstaller.root = '/srv/myapp'   # a String or a Pathname
ClaudeAgentSDK::CLIInstaller.default_dir           # => "/srv/myapp/vendor/claude"
```

A relative path is resolved against the working directory once, when you set it. `nil` restores the working-directory default. In a Rails app you don't need this line: the Railtie sets `root` to `Rails.root` during boot (see [docs/rails.md](rails.md)). An explicit `dir:` argument always wins over `root`.

> The vendored directory is trusted input: anything that can write to it can replace the binary the SDK executes. Keep it inside your deploy artifact, owned by the deploy user and not world-writable, exactly as you would treat `bin/`.

## Docker and `bin/setup`

```dockerfile
# Dockerfile — the gem's pinned CLI version in its own cached layer
RUN bundle exec ruby -e "require 'claude_agent_sdk'; \
    ClaudeAgentSDK::CLIInstaller.install_pinned"
```

```ruby
#!/usr/bin/env ruby
# bin/setup — gem's pin by default, overridable per developer
require 'claude_agent_sdk'
version = ENV.fetch('CLAUDE_CLI_VERSION', ClaudeAgentSDK::CLIInstaller::PINNED_CLI_VERSION)
puts ClaudeAgentSDK::CLIInstaller.install(version: version)
```

## Rake task

Rails apps get `claude_agent_sdk:install_cli` from the gem's Railtie; any other project can load it from its `Rakefile`:

```ruby
# Rakefile (non-Rails)
require 'claude_agent_sdk/tasks'   # loads only CLIInstaller, not the whole SDK
```

```bash
bin/rails claude_agent_sdk:install_cli                 # Rails: installs PINNED_CLI_VERSION into Rails.root/vendor/claude
rake claude_agent_sdk:install_cli                      # elsewhere: into CLIInstaller.default_dir (vendor/claude under the working directory unless root is set)
rake claude_agent_sdk:install_cli CLAUDE_CLI_VERSION=x.y.z   # a version of your own, or 'stable' / 'latest'
```

The task calls `install_pinned` (or `install(version:)` when `CLAUDE_CLI_VERSION` is set — the same variable the `bin/setup` example above reads), prints the installed path, and doesn't boot the Rails app, so it runs in a Docker build without a database or credentials:

```dockerfile
RUN bin/rails claude_agent_sdk:install_cli
```

The variable is deliberately not rake's conventional `VERSION`, which Rails' `db:migrate` uses and build environments often export for an app version or git SHA. An empty `CLAUDE_CLI_VERSION` means the gem's pin.

## Supported platforms

`darwin-arm64`, `darwin-x64` (Rosetta 2 gets the arm64 build), `linux-x64`, `linux-arm64`, and the `-musl` variants. Windows is not supported.

## CLI discovery order

With no explicit `cli_path:` in `ClaudeAgentOptions`, the transport probes in this order:

1. `CLAUDE_CLI_PATH` — a path to the CLI, used when it names an executable regular file (a relative value is resolved against the process's working directory, not `cwd:`). A value that names anything else — a missing file, a directory, a file that is not executable — is skipped without a warning, and discovery continues with the steps below
2. The vendored binary (`CLIInstaller.installed_path`, i.e. `vendor/claude` under `CLIInstaller.root` or the working directory — see [above](#where-vendorclaude-is)) — deliberately ahead of `PATH`, so a pinned install beats whatever is installed globally
3. `claude` on the process's `PATH` — the first executable regular file of that name. The SDK searches `PATH` itself and does not run `which`. A `PATH` passed in `env:` belongs to the session and is not searched here. When the process has no `PATH` at all, the system directories are searched (`/usr/local/bin`, `/usr/bin`, `/bin`), as Ruby's own command lookup would — never the working directory
4. Common install locations (`~/.claude/local/claude`, `/usr/local/bin/claude`, …) — only an executable regular file counts, and the `~` ones are skipped when there is no usable home directory (HOME unset with no passwd entry, or a non-absolute HOME)

However the CLI is named, the transport settles on one absolute path before it runs anything, and uses that path for both the version check and the session. Anything relative is resolved against the process's working directory, never against `cwd:` — a relative `cli_path:` (a leading `~` expands to the home directory), and a `PATH` hit that came from a relative `PATH` entry (`bin`, `.`, an empty entry). A `PATH` entry that is `~` or starts with `~/` is not one of those: it is expanded against the home directory, as Ruby's own command lookup does. A bare `cli_path: 'claude'` is looked up by the SDK in the same way, but on the `PATH` the session will get: the one in `env:` when you set one there, otherwise the process's. A `cli_path:` that names no file raises `CLINotFoundError` from `connect`.
