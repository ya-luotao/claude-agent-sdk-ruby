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
- An exclusive `flock` on `<dir>/.install.lock` covers the whole check → download → place → record sequence, so parallel installs into one directory don't race — whether they come from separate processes, threads, or fibers of one `Async` reactor (a waiting installer polls the lock rather than blocking its thread on it); the loser simply observes the finished install.
- The shortcut also works where the running process cannot write the install directory: an image built as root and run as another user, or a read-only root filesystem. `install` cannot open its lock file there (`EACCES`, `EROFS` or `EPERM`), and still returns the binary when the request is a concrete version that is already installed and intact — the same `VERSION` and SHA-256 check, without the lock. Anything that would need a write raises `CLIInstallError` as before: a dist-tag (`'stable'` / `'latest'`, which has to be resolved and may have to be installed), a different version, a damaged binary, an empty directory.

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

## Proxies and custom CAs

The installer downloads over HTTPS with Ruby's `Net::HTTP` and reads the usual environment variables:

- **`HTTPS_PROXY`** (or `https_proxy`) names the proxy to download through, as an `http://` URL: `HTTPS_PROXY=http://proxy.corp.example:3128`, with `user:password@` in front of the host for an authenticating proxy (percent-encode special characters). The download is tunnelled through it with `CONNECT`, so TLS still ends at the release endpoint.
- **`NO_PROXY`** (or `no_proxy`) lists the hosts, domain suffixes and IP ranges to reach directly, separated by commas.
- With neither spelling of `HTTPS_PROXY` set, `Net::HTTP`'s own default applies: it goes through `http_proxy` when that is set.
- **`SSL_CERT_FILE`** points OpenSSL at another CA bundle, which is what a TLS-inspecting proxy needs. Set it in the environment the process starts with. The server certificate is always verified; there is no switch to turn that off.

This is not everything `curl` understands. `ALL_PROXY` is not read, and only an `http://` proxy URL is used: a value without a scheme (`proxy.corp.example:3128`), a `socks5://` proxy or an `https://` one is ignored.

## Supported platforms

`darwin-arm64`, `darwin-x64` (Rosetta 2 gets the arm64 build), `linux-x64`, `linux-arm64`, and the `-musl` variants. Windows is not supported.

## CLI discovery order

With no explicit `cli_path:` in `ClaudeAgentOptions`, the transport probes in this order:

1. `CLAUDE_CLI_PATH` — an explicit path to an executable, no discovery at all (a relative value is resolved against the process's working directory, not `cwd:`)
2. The vendored binary (`CLIInstaller.installed_path`, i.e. `vendor/claude` under `CLIInstaller.root` or the working directory — see [above](#where-vendorclaude-is)) — deliberately ahead of `PATH`, so a pinned install beats whatever is installed globally
3. `which claude`
4. Common install locations (`~/.claude/local/claude`, `/usr/local/bin/claude`, …) — only an executable regular file counts, and the `~` ones are skipped when there is no usable home directory (HOME unset with no passwd entry, or a non-absolute HOME)
