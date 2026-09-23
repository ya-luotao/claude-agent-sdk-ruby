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

# Or pin your own: 'stable' (default), 'latest', or a concrete version.
ClaudeAgentSDK::CLIInstaller.install(version: 'stable', dir: '/opt/claude')

# nil unless a binary is already installed there
ClaudeAgentSDK::CLIInstaller.installed_path
```

`install` is idempotent and safe to run concurrently, so it fits `bin/setup`, a cached Docker layer, and every process of a multi-process boot:

- The install directory's `VERSION` file records the installed version, verified SHA-256, and target platform (OS, architecture, libc). The shortcut re-hashes the vendored binary (~0.1s for the real 245MB binary) and only skips the download when all three match — a truncated binary or a cache copied from another platform is reinstalled instead of trusted. It makes **no network request**, so same-platform repeat boots work offline — with a pinned concrete version; `'stable'`/`'latest'` must always re-resolve through the endpoint, which is one more reason to pin in production. Older one- or two-line metadata lacks a platform and requires one online reinstall to migrate; subsequent pinned installs work offline again.
- An exclusive `flock` on `<dir>/.install.lock` covers the whole check → download → place → record sequence, so parallel installs into one directory don't race; the loser simply observes the finished install.

Failures (unsupported platform, invalid version, HTTP error, response-size cap, oversized download, checksum mismatch, filesystem errors) raise `ClaudeAgentSDK::CLIInstallError`.

**A failed install never breaks a working one.** The new binary is downloaded to a temp file, checksum-verified and recorded, and only then renamed into place — the rename is the last step, and nothing can fail after it. So a failed upgrade leaves the previously installed binary intact and runnable (the SDK keeps working), and the next `install` redoes it cleanly. A first install that fails leaves nothing behind at all.

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

## Supported platforms

`darwin-arm64`, `darwin-x64` (Rosetta 2 gets the arm64 build), `linux-x64`, `linux-arm64`, and the `-musl` variants. Windows is not supported.

## CLI discovery order

With no explicit `cli_path:` in `ClaudeAgentOptions`, the transport probes in this order:

1. `CLAUDE_CLI_PATH` — an explicit path to an executable, no discovery at all (a relative value is resolved against the process's working directory, not `cwd:`)
2. The vendored binary (`CLIInstaller.installed_path`) — deliberately ahead of `PATH`, so a pinned install beats whatever is installed globally
3. `which claude`
4. Common install locations (`~/.claude/local/claude`, `/usr/local/bin/claude`, …)
