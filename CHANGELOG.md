# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

1.0 ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)): three breaking changes, the first two of which 0.37 warns about at the call site. **Read [UPGRADING-1.0.md](UPGRADING-1.0.md) before upgrading** and run your suite on 0.37 with warnings visible first: an app that runs on 0.37 without SDK warnings is unaffected by those two, except that `respond_to?` on a camelCase non-attribute (`msg.respond_to?(:toH)`) silently answered `true` on 0.37 and answers `false` now.

### Added
- **`ClaudeAgentSDK::SessionStoreError`** (a `ClaudeSDKError`), raised by `query`, `ask` and `Client#connect` when resuming from `session_store:` fails: a store call (`#load`, `#list_sessions`, `#list_subkeys`) raised or exceeded `load_timeout_ms` while the SDK materialized the transcript. The message names the store call, and `#cause` holds the adapter's exception (or the timeout). Documented in `docs/errors.md` and `docs/sessions.md`.
- **RBS signatures for the public API** ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)). The gem now ships `sig/`, so Steep and other RBS tools type-check code that uses it (through `rbs collection`; `sig/manifest.yaml` declares the one stdlib dependency, `pathname`). The signatures cover the whole public surface (the objects documented in `docs/` and YARD without `@api private`): `ClaudeAgentSDK.query` / `.ask` / `.configure` / `.offload`, the SDK MCP helpers, every session function (including `session_store:` and the deprecated twins), `Client` with its Ruby-style aliases, `ClaudeAgentOptions` (every option as a typed keyword), the message, content-block, hook, permission and MCP types, the error hierarchy, `CLIInstaller`, `Streaming`, `Railtie.callback_wrapper` and the observers. Duck types are interfaces, so any object with the right methods fits: `_Transport`, `_SessionStore` (only `#append` and `#load` are required), and one interface per user callback (`_CanUseTool`, `_HookCallback`, `_ToolHandler`, `_CallbackWrapper`, ...). Hashes follow the documented key rule: `wire_hash` (`Hash[Symbol, untyped]`) for data from the CLI stream, `transcript_hash` (`Hash[String, untyped]`) for transcripts and store data. Internals tagged `@api private` have no signatures. CI validates the signatures (`rake rbs:validate`) and runs the suite under RBS's runtime type checker (`rake rbs:test`), so a signature that disagrees with the code fails the build. `CONTRIBUTING.md` explains how to keep `sig/` in step with API changes.

### Changed
- **Breaking: unknown keys on user-constructed types raise `ArgumentError`.** `.new` and `#[]=` on the value types you build and pass in (option values such as `AgentDefinition`, `SandboxSettings`, the thinking and MCP server configs; `HookMatcher`; hook outputs; `PermissionResultAllow` / `PermissionResultDeny`; `PermissionUpdate`; `PermissionRuleValue`) raise instead of warning, with a message naming the class, the key and the known keys: `ClaudeAgentSDK::HookMatcher: unknown attribute :matchr (known: hooks, matcher, timeout)`. camelCase and String keys and a type's own discriminator are still accepted; `.from_hash`, `.wrap` and every type parsed from CLI output stay lenient.
- **Breaking: `Type#[]`, `#[]=` and camelCase methods reach attributes only.** A name that is not an attribute behaves like an undefined one: `msg[:to_h]` is `nil`, `#[]=` ignores it (raises on the strict types above), `msg.toH` raises `NoMethodError` and `respond_to?(:toH)` is `false`. Methods your own code adds to a subclass, mixin or instance still count as attributes.
- **Breaking: store-backed resume failures raise `SessionStoreError` instead of `RuntimeError`.** The two SDK-raised `RuntimeError`s (store call failed, store call timed out) become `SessionStoreError`, and a `RuntimeError` raised by the adapter itself, which 0.37 let through unwrapped, is now wrapped too, so `rescue ClaudeSDKError` catches every resume-materialization failure. Code that rescued `RuntimeError` there must rescue `SessionStoreError`. The failure message now includes the adapter exception's class (`... failed during resume materialization: IOError: connection reset`).
- `UPGRADING-1.0.md` ships in the gem and the YARD docs, linked from the README.
- The deprecation warning printed by the ten `*_from_store` / `*_via_store` session functions, and their YARD and docs, now say they will be removed in **2.0**. 0.36 and 0.37 said 1.0, but they stay, deprecated, for all of 1.x ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)). Nothing else about them changes: each still works and still warns once per process.

## [0.37.0] - 2026-09-23

The last 0.x release before 1.0 ([roadmap](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)). No runtime behaviour changes — only new warnings for things 1.0 will reject. **Run your suite on 0.37 with warnings visible before moving to 1.0:**
- A misspelled key on a value type you build (`HookMatcher`, `AgentDefinition`, `SandboxSettings`, MCP server configs, permission results, hook outputs, …) now warns once, pointing at your call; 1.0 raises `ArgumentError`.
- `msg[:name]` / camelCase readers reaching a non-attribute method (e.g. `msg[:to_h]`) warn once; in 1.0 they only reach attributes.
- The 1.0 SemVer surface is now visible: SDK internals are tagged `@api private` and hidden from the API docs, and the documented contracts (Hash-key rule, `mcp_status` / `context_usage` return Hashes, `Type#[]`) are written down.

### Changed
- **Docs: pre-1.0 contracts written down** ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)). No code changes. `Client#mcp_status` / `#get_mcp_status` and `#context_usage` / `#get_context_usage` return the CLI's raw Hash with camelCase Symbol keys. `docs/types.md` had described `McpStatusResponse` as the response type; it is the optional typed view, via `McpStatusResponse.parse(client.mcp_status)`, and there is no typed context-usage class (`docs/client.md`). A new "Hash keys" section in `docs/types.md` states one rule: Hashes passed through from the live CLI stream (`origin`, `usage`, `model_usage`, hook `tool_input`, `can_use_tool` input, SDK MCP tool args, control responses) have Symbol keys spelled as on the wire, and Hashes read from transcripts or a `SessionStore` (`SessionMessage#message`, `get_subagent_metadata`, store keys and entries) have String keys. The docs, examples and bundled skill drop their `h[:key] || h['key']` fallbacks in favour of the one correct form. `Type#[]`, `#[]=` and the camelCase readers are documented as public API, including that `#[]=` changes the object you received. `docs/sessions.md` documents `ClaudeAgentSDK.project_key_for_directory` and `ClaudeAgentSDK.fold_session_summary` for adapter authors, and `import_session_to_store`'s batching (`batch_size:` defaults to 500 entries, and a batch also ends at about 1 MiB).
- **SDK internals are now tagged `@api private` and hidden from the YARD docs** ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)). The tagged namespaces are `Query`, `MessageParser`, `TranscriptMirrorBatcher`, `Sessions`, `SessionMutations`, `SessionResume`, `MaterializedResume`, `SessionSummary`, `SessionStores`, `OptionWarnings` and `FiberBoundary`, including everything nested in them. Some public classes also have internal members, and those are tagged individually: `SubprocessCLITransport`'s methods outside the `Transport` interface and its constants; `CommandBuilder`'s constants (`.new` and `#build` stay public); `CLIInstaller::Http`, `Platform`, `Release` and `Metadata` and the installer's constants other than `PINNED_CLI_VERSION`; `SdkMcpServer#handle_json`, `#handle_message` and `SdkMcpServer::ToolInputSchema`; `Client#query_handler`; and `ClaudeAgentSDK::OBSERVER_INTERFACE`. Their public faces are unchanged: `ClaudeAgentSDK.offload`, `fold_session_summary`, the session functions and `SDKSessionInfo` / `SessionMessage` remain public. Nothing changes at runtime. No method or constant was renamed, removed or made private, so every existing call keeps working. From 1.0, SemVer covers `docs/` and the YARD API without `@api private`; objects tagged `@api private` are not covered and may change in any release. `CONTRIBUTING.md` has a new "What is public API" section.
- `lib/claude_agent_sdk/types.rb` is split into one file per area under `lib/claude_agent_sdk/types/` (messages, hooks, options, ...). The code moved without edits and `types.rb` still loads every part, so `require 'claude_agent_sdk/types'` and every class and constant are unchanged; no API change ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)).
- `Type`'s internal machinery is tagged `@api private` and leaves the rendered docs: `Type#dup_for_options`, `Type.deep_dup_for_options`, `Type::OptionValue`, `Type.inspect_filtered`, `Type.inspect_filtered_attributes`, and the new `Type.strict_attributes` / `.strict_attributes?` / `.declare_attributes` / `.attribute?` / `.attribute_names`. They are not part of the SemVer surface. `Type#[]`, `#[]=`, the camelCase readers, `#to_h`, `.wrap` and `.from_hash` stay public ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)).

### Deprecated
- **Unknown keys on user-constructed types.** The value types you build and pass in (option values such as `AgentDefinition`, `SandboxSettings`, the thinking configs and the MCP server configs; `HookMatcher`; hook outputs; `PermissionResultAllow` / `PermissionResultDeny`; `PermissionUpdate`; `PermissionRuleValue`) silently dropped a misspelled key, so `HookMatcher.new(matchr: 'Bash')` quietly built a matcher with no `matcher` set. `.new` and `#[]=` now warn once per class and key, at the caller's line: `ClaudeAgentSDK::HookMatcher: unknown attribute :matchr ignored; this will raise ArgumentError in 1.0 (known: hooks, matcher, timeout)`. **In 1.0 they raise `ArgumentError`**, as `ClaudeAgentOptions` already does. camelCase and String keys and a type's own discriminator (`type`, `hook_event_name`, `behavior`) are accepted, so `klass.new(value.to_h)` round-trips silently. Types parsed from CLI output (messages, content blocks, hook inputs) and every construction through `.from_hash` / `.wrap` stay lenient, so a newer CLI's extra fields never warn; permission suggestions from the CLI are now hydrated through `PermissionUpdate.wrap` for that reason. Full list in `docs/types.md` ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)).
- **`Type#[]`, `#[]=` and camelCase methods reaching something other than an attribute.** They are public API for a type's attributes (its `attr_*` fields, the backward-compatible `RateLimitEvent#data`, predicates such as `options.forkSession?`, and any method your own code adds to a subclass, mixin or instance), but they resolved any public method: `msg[:to_h]` returned a Hash, `msg['freeze']` froze the message, `msg.toH` called `#to_h`. Such a call still works but warns once per class and name, e.g. `ClaudeAgentSDK::ResultMessage#[]: :to_h is not an attribute; Type#[] will only read attributes in 1.0`. **In 1.0 a name that is not an attribute behaves like an undefined one:** `#[]` returns `nil`, `#[]=` ignores it (raises on the types above), a camelCase call raises `NoMethodError`, and `respond_to?` says `false`. Names that are not methods at all keep today's behaviour and do not warn. `UserMessage#text` / `AssistantMessage#text` are convenience methods, not attributes ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)).

## [0.36.0] - 2026-09-23

The first step on the [road to 1.0](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126): one `session_store:` argument for every session function (the store-specific twins are deprecated), `ClaudeAgentSDK.ask`, String tool results, and the last audit follow-ups (#119–#121). **Read before upgrading:**
- An `exit`, `Interrupt` or signal raised inside a hook, `can_use_tool` or SDK MCP handler now **ends the process after the CLI gets its error response**. Since 0.34.0 a tool handler's `exit` was turned into an `isError` result and the process kept running, which also swallowed a real Ctrl-C or SIGTERM in `:inline` mode.
- The `*_from_store` / `*_via_store` session functions print a one-time deprecation warning; switch to `list_sessions(session_store: store)` etc. (table under **Deprecated**).
- Local-disk session APIs raise `ConfigDirError` (not `ArgumentError`) on hosts without a home directory; a session with no prompt has `first_prompt` `nil` on the disk path too (was `''`).

### Added
- **SDK MCP tool handlers may return a String.** `create_tool('greet', ...) { |args| "Hello, #{args[:name]}!" }` now sends Claude a single text block, the same as returning `{ content: [{ type: 'text', text: "Hello, ..." }] }`. Both dispatch paths (`tools/call` through the MCP server and the direct `SdkMcpServer#call_tool`) accept it. Hash returns behave exactly as before and remain the form for `is_error`, `structured_content`, images and several blocks; any other non-Hash return still produces the in-band "must return a hash with :content key" error. The `create_tool` YARD examples, README and `docs/mcp-servers.md` (new "Handler Return Values" section) lead with the String form.
- **`ClaudeAgentSDK.ask(prompt, options: nil)`** — runs `query` to completion and returns the final `ResultMessage`, so `ClaudeAgentSDK.ask("What is 2 + 2?").result` is the answer text, with cost, usage and `session_id` on the same object. It is `query` underneath: same prompt types (String or Enumerable), same `options:` and `transport:`, same errors (a terminal error exit still raises `ResultError`; an `is_error` result that is not followed by an error exit is returned like any other). An optional block receives every message as it arrives, so callers can stream progress and still get the result. It consumes the whole stream and returns the last `ResultMessage`; if the stream ends without one it raises `CLIConnectionError`. The README Quick Start now leads with it.
- **Ruby-style `Client` method names next to the Python-parity ones**: `client.model = 'haiku'` (`set_model`), `client.permission_mode = 'plan'` (`set_permission_mode`), `client.context_usage` (`get_context_usage`) and `client.mcp_status` (`get_mcp_status`). Each delegates to its parity counterpart, so both spellings send the same control request, raise the same `CLIConnectionError` before `connect`, and an override of the parity method covers both. The parity names stay, so code ported from the Python docs keeps working. (`server_info` / `get_server_info` already existed as a pair.) `docs/client.md` lists both spellings.
- **`CLIInstaller.root` — a configurable root for the vendored CLI.** `CLIInstaller.default_dir` (and so `install`, `install_pinned`, `installed_path` without `dir:`, and the transport's discovery of the vendored binary) is `vendor/claude` under `CLIInstaller.root` when it is set, and under the working directory at call time when it is `nil`, the default. A process whose cwd is not the project root, such as a daemonized worker, can now find the vendored binary instead of falling through to `PATH`. The setter takes a String or Pathname, absolutizes it once, and rejects an empty path; `nil` restores the working-directory default. Unset, nothing changes, and an explicit `dir:` still wins.
- **The Railtie anchors CLI discovery to `Rails.root`**: an initializer sets `CLIInstaller.root ||= Rails.root` before `config/initializers` run, so an app initializer can override it and a root set in `config/application.rb` is kept. The `claude_agent_sdk:install_cli` task, which does not boot the app, installs under an explicitly set `CLIInstaller.root` if there is one, and under `Rails.root/vendor/claude` as before otherwise. The generated initializer's commented `cli_path:` line no longer describes a cwd workaround. `docs/cli-installer.md` gains a "Where `vendor/claude` is" section.
Groundwork for 1.0 ([#126](https://github.com/ya-luotao/claude-agent-sdk-ruby/issues/126)): the sessions API collapses to one function per operation, and the store-specific twins are deprecated. Nothing is removed; every existing call keeps working.
- **`session_store:` on every session function.** `list_sessions`, `get_session_info`, `get_session_messages`, `list_subagents`, `get_subagent_metadata`, `get_subagent_messages`, `rename_session`, `tag_session`, `delete_session` and `fork_session` take an optional `session_store:`. Omitted or `nil`, they work on local disk exactly as before; given a store, they run the same code the `*_from_store` / `*_via_store` function did, with the same arguments. Two differences between the paths are documented in `docs/sessions.md`: `directory: nil` means every project on disk but the current working directory with a store (a store cannot enumerate projects), and `include_worktrees:` is disk-only: with `session_store:`, `list_sessions` accepts only the default `true` and raises `ArgumentError` for `false` or `nil` instead of silently ignoring the filter.
- **`ClaudeAgentSDK::ConfigDirError`** (a `ClaudeSDKError`), raised by the local-disk session APIs when the Claude config directory cannot be located: `CLAUDE_CONFIG_DIR` is unset and there is no usable home directory for the default `~/.claude`. Its message says to set `CLAUDE_CONFIG_DIR` (#120).
- CI: a macOS leg (Ruby 3.4) for the main suite; simplecov coverage (`COVERAGE=1 bundle exec rspec`) on the Linux Ruby 3.4 leg, with line/branch totals in the job summary and the HTML report as an artifact; and a weekly real-CLI integration run (`.github/workflows/integration.yml`) against `CLIInstaller::PINNED_CLI_VERSION`, also triggered by PRs that touch the installer. Dependabot keeps the workflows' actions current.
- `CONTRIBUTING.md`, `SECURITY.md`, and issue and pull request templates.

### Changed
- **`exit` / `Interrupt` / signal exceptions from an SDK MCP tool handler terminate the process again, after the CLI gets its `isError` result.** Since #77 (0.34.0) they were converted into an `isError` result and the process kept running. That also swallowed a real Ctrl-C or `SIGTERM` landing in an `:inline` handler. The `isError` text now names the exception class (`"SystemExit: exit"` rather than `"exit"`). `SdkMcpServer#call_tool` and `#handle_message`, called directly without a session, let these exceptions propagate instead of returning an `isError` result. (#119)
- **Root-module plumbing is tagged `@api private`** and no longer appears in the generated YARD docs (`.yardopts` gains `--hide-api private`; `--no-private` alone never hid `@api private` objects): `resolve_observers`, `extract_sdk_mcp_servers`, `convert_hooks_to_internal_format`, `configure_can_use_tool`, `extract_exclude_dynamic_sections`, `extract_system_prompt_snapshot`, `notify_observers`, `check_inline_isolation`, `extract_user_prompt_text`, `prompt_text_from_content`, `observing_prompt_stream`, `flexible_fetch`, `normalize_tool_result`, and the tool-schema helpers `deep_symbolize_keys`, `deep_normalize_schema`, `prebuilt_json_schema?`, `normalize_tool_schema`, `ruby_type_to_json_schema`. They still work, but they are not part of the public API and move under `ClaudeAgentSDK::Internal` in 1.0. `fold_session_summary` stays public, since SessionStore adapters call it from `#append`. The existing `@api private` tags (`FiberBoundary` internals, `CancellationSignal#cancel`) are hidden too; `#cancel`'s tag is moved to its own line, where YARD recognizes it.
- `examples/rails_actioncable_example.rb` and `examples/rails_background_job_example.rb` use `ClaudeAgentSDK::Client.open` instead of hand-rolled `Async { connect … ensure disconnect }.wait`, matching `docs/rails.md`.
- RuboCop targets Ruby 3.2, the gemspec floor (was 3.0). The resulting autocorrections (anonymous block forwarding, dropping `require 'set'`) change no behavior.

### Deprecated
- **The ten store-specific session functions**, removed in 1.0. Each still returns exactly what it did before (a `nil` `session_store:` still fails rather than falling back to disk), and prints a one-time warning per method per process naming its replacement and the calling line, e.g. `app/jobs/sync.rb:12: warning: ClaudeAgentSDK.list_sessions_from_store is deprecated and will be removed in 1.0; use ClaudeAgentSDK.list_sessions(session_store: store)`. The warning uses plain `Kernel#warn`, not `category: :deprecated`, because Ruby hides that category unless `Warning[:deprecated]` is enabled; `-W0` / `$VERBOSE = nil` silences it.

  | Deprecated | Replacement |
  |---|---|
  | `list_sessions_from_store(session_store: s, ...)` | `list_sessions(session_store: s, ...)` |
  | `get_session_info_from_store(session_store: s, ...)` | `get_session_info(session_store: s, ...)` |
  | `get_session_messages_from_store(session_store: s, ...)` | `get_session_messages(session_store: s, ...)` |
  | `list_subagents_from_store(session_store: s, ...)` | `list_subagents(session_store: s, ...)` |
  | `get_subagent_metadata_from_store(session_store: s, ...)` | `get_subagent_metadata(session_store: s, ...)` |
  | `get_subagent_messages_from_store(session_store: s, ...)` | `get_subagent_messages(session_store: s, ...)` |
  | `rename_session_via_store(session_store: s, ...)` | `rename_session(session_store: s, ...)` |
  | `tag_session_via_store(session_store: s, ...)` | `tag_session(session_store: s, ...)` |
  | `delete_session_via_store(session_store: s, ...)` | `delete_session(session_store: s, ...)` |
  | `fork_session_via_store(session_store: s, ...)` | `fork_session(session_store: s, ...)` |

  All other arguments carry over unchanged. `import_session_to_store` is not affected.

### Fixed
- **`exit`, `Interrupt` and signal exceptions raised while a hook, `can_use_tool`, or an SDK MCP resource reader / prompt generator runs no longer leave the CLI without an answer.** The SDK now responds first, then re-raises. The CLI gets exactly the response an ordinary exception from that callback produces, naming the exception class (`"SystemExit: exit"`, `"Interrupt"`, `"SignalException: SIGTERM"`). For hooks and `can_use_tool` that is the error control response; for `resources/read` / `prompts/get` it is a JSON-RPC `-32603` error. The transport flushes that response, and then the original exception propagates, so the process terminates as plain Ruby would: `exit 3` exits with status 3, and Ctrl-C interrupts. Previously no response was written and the reactor stopped. In the default `:thread` scheduling, Ruby also re-raised the worker thread's `SystemExit` on the main thread, which answered with a misleading `Cancelled`. This covers every dispatch site: `can_use_tool`, hooks with and without a `HookMatcher#timeout` (both variants), resources, prompts and tool handlers. It also covers a real Ctrl-C / `SIGTERM` that MRI delivers to the main thread while an `:inline` callback runs there, and a `:thread` hook that calls `exit` after its timeout expired (only `exit` is carried out of such an abandoned worker: an `Interrupt` or signal exception it raises ends that thread alone, as in plain Ruby). Cancellation (`Async::Stop`, hook timeouts) still propagates unchanged. A `callback_wrapper` sees an internal `StandardError` carrier whose `#cause` is the original, so ensure-based wrappers still clean up; the original is re-raised even if the wrapper swallows the carrier. Observers and message blocks are unchanged. (#119)
- **Session APIs on hosts without a home directory (#120).** With `CLAUDE_CONFIG_DIR` unset and `HOME` unset with no passwd entry (`docker --user` in a minimal image) or an empty/relative `HOME`:
  - the local-disk session APIs (`list_sessions`, `get_session_*`, `list_subagents`, `rename_session` / `tag_session` / `delete_session` / `fork_session`, `import_session_to_store`) raise `ConfigDirError` instead of a bare `ArgumentError` from `~` expansion;
  - a fresh session with a `session_store` no longer fails at connect. The transcript mirror cannot map the CLI's transcript files to store keys without a projects dir, so each unmappable batch is reported as a `MirrorErrorMessage` (with a `nil` key) and counted as dropped, while the session itself runs normally. `SessionStores.projects_dir` returns `nil` in this case instead of raising.
- **Store-backed resume seeds auth and settings from the home the CLI subprocess will use (#120).** When `options.env` sets `HOME`, `.credentials.json`, `settings.json` / `cowork_settings.json` and `.claude.json` are now read from under that home, as `CLAUDE_CONFIG_DIR` already was, instead of the parent process's home. An empty or relative `HOME` there, or `HOME => nil`, counts as no home, so those files are skipped. The transcript mirror resolves the subprocess's default `~/.claude/projects` the same way, so a `HOME` override no longer sends every mirror frame down the "not under projects dir" drop path.
- **Remaining disk/store session read inconsistencies (#121):**
  - Store listings report `SDKSessionInfo#last_modified` as Integer epoch milliseconds, as documented, whatever shape the adapter's `mtime` has (ISO-8601 String, numeric String, Float, or now `Time`, e.g. an ActiveRecord `updated_at`). Previously only the ordering was coerced and the raw value leaked through. An unusable mtime (including non-finite numbers) reads as `0`, the value it already sorted by.
  - `continue_conversation` with a `session_store` breaks equal-mtime ties by `session_id`, like the listings, instead of resuming whichever session the adapter listed first.
  - `first_prompt` is `nil` on the disk path too (it was `''`) when a session has no prompt, matching the store path and the Python SDK.
  - `cwd`: both paths take the first non-blank top-level `cwd`. The disk path took the first `cwd` even when empty (then fell back to the project path) and also matched `cwd` keys nested in tool inputs; the store fold now also skips whitespace-only values, so a sidecar no longer locks on one.
  - `rename_session` / `tag_session` / `delete_session` / `fork_session` and their `_via_store` counterparts validate `session_id` (and `up_to_message_id`) at the boundary like the readers: a non-String id raises `ArgumentError` ("Invalid session_id") instead of `NoMethodError`.
  - `list_sessions` deduplicates a session found in several project directories deterministically: newest `last_modified`, then the larger file, then the project directory that sorts first (the global scan now walks project directories in name order). Equal mtimes used to keep whichever copy the filesystem listed first.

## [0.35.0] - 2026-09-23

First-class Rails integration and a first-impressions pass. **Rails users:** if your initializer uses the previously documented `->(inv) { Rails.application.executor.wrap { inv.call } }` callback wrapper, switch to `ClaudeAgentSDK::Railtie.callback_wrapper` — the bare form can deadlock in development (see **Fixed**).

### Added
- **Rails integration: `ClaudeAgentSDK::Railtie`**, loaded only when Rails is (`require_relative 'claude_agent_sdk/railtie' if defined?(Rails::Railtie)`, which Bundler.require satisfies in a Rails app); non-Rails processes load nothing new. It contributes a rake task and installs nothing into callback dispatch.
- **`bin/rails generate claude_agent_sdk:install`** — writes `config/initializers/claude_agent_sdk.rb` (commented `model` / `permission_mode` / `cli_path` / OpenTelemetry defaults, `callback_wrapper: ClaudeAgentSDK::Railtie.callback_wrapper` enabled), appends `/vendor/claude/` to `.gitignore` once (any existing spelling counts), and prints the next steps.
- **`claude_agent_sdk:install_cli` rake task** — `CLIInstaller.install_pinned` into `Rails.root/vendor/claude`, or `install(version:)` with `CLAUDE_CLI_VERSION=x.y.z|stable|latest`; prints the installed path. It does not boot the app, so it runs in a Docker build step. Outside Rails, `require 'claude_agent_sdk/tasks'` in a Rakefile provides the same task (loading only `CLIInstaller`), installing under the working directory.
- **`ClaudeAgentSDK::Railtie.callback_wrapper`** — a `callback_wrapper` that runs SDK callbacks in `Rails.application.executor` (so ActiveRecord connections check back in), except where that deadlocks: with code reloading enabled or `config.allow_concurrency = false` it calls the callback outside the executor and releases the thread's ActiveRecord connections itself; when the executor is already active on the callback's context (`:inline` scheduling) it calls straight through. Supports Rails 7.1+.
- CI: a `rails` job runs the Rails integration specs (`spec/rails`, in their own process via `rspec --options spec/rails/.rspec`) against Rails 7.1 on Ruby 3.2 and the latest Rails 8 on Ruby 3.4 (`gemfiles/rails_7_1.gemfile`, `gemfiles/rails_8.gemfile`). The default `bundle exec rspec` run excludes `spec/rails`.
- **Every SDK type now prints its fields.** `Type#inspect` lists the non-nil attributes (`#<ClaudeAgentSDK::ResultMessage subtype="success" num_turns=3 total_cost_usd=0.012 ...>`) instead of a bare object address, and `#to_s` falls back to it, so the README's `puts message` is readable for every message type. The output is bounded for logging: Strings past 80 characters are truncated with a count of what was cut, Arrays and Hashes show their first five entries plus a count of the rest, nesting past two levels (and any reference cycle) collapses to a placeholder, and objects that only have `Kernel#inspect` (SDK MCP server instances, store adapters, observers) show as `#<ClassName>` rather than dumping their state. Callbacks (`can_use_tool`, hooks, `callback_wrapper`, ...) render from their source location, e.g. `#<Proc(lambda) permissions.rb:17>`, never through their own `#inspect`, so a raising or oversized override cannot break or flood a log line.
- **One-line `to_s` for results and system messages.** `ResultMessage#to_s` prints `[result: success, 3 turns, 4.2s, $0.0120]` (missing fields omitted; an error result appends its `errors`), `SystemMessage#to_s` prints `[system: init]`, and `TextBlock#to_s` returns its text. `UserMessage` / `AssistantMessage` keep printing their text.

### Changed
- `docs/rails.md` opens with a getting-started path (gem → generator → `install_cli` → first job), and its ActionCable, session-resumption and background-job examples use `ClaudeAgentSDK::Client.open` instead of hand-rolled `Async { connect … ensure disconnect }.wait`. README and gemspec description lead with the Rails integration.
- **`#inspect` filters credential-bearing attributes** to `"[FILTERED]"` (Hash keys stay visible): `ClaudeAgentOptions#env` (usually carries `ANTHROPIC_API_KEY`), `McpStdioServerConfig#env`, and `McpHttpServerConfig` / `McpSSEServerConfig#headers`, since these objects end up in logs. The objects are not modified. Type subclasses declare such attributes with `inspect_filtered :name`. Typed `SystemMessage` subclasses (`InitMessage`, ...) leave the raw `@data` frame out of `#inspect`, since it repeats their attributes; a bare `SystemMessage` keeps it. Nothing sent to the CLI changes: wire output still goes through `#to_h`.
- The README's `Client` section and the basic example in `docs/client.md` now lead with `Client.open`, which creates the reactor and always disconnects, instead of the `Async do … begin … ensure client.disconnect end.wait` boilerplate. The manual `connect` / `disconnect` form is still shown for code already running inside an `Async` reactor. No API changes.
- The bundled `claude-agent-ruby` skill recommends `Client.open` and documents the install generator, the `install_cli` task and `Railtie.callback_wrapper`.
- **Gem metadata names its maintainer** (`authors: ["ya-luotao"]`, with a contact email) instead of "Community Contributors". The stale `IMPLEMENTATION.md` is removed, and the past audit reports move from the repository root to `docs/history/`, which is not packaged with the gem.

### Fixed
- **The Rails `callback_wrapper` previously recommended in docs/rails.md, `->(inv) { Rails.application.executor.wrap { inv.call } }`, can deadlock in development.** With code reloading enabled, the request or job calling the SDK holds a share of the reload interlock while it waits for a callback running on its own thread (the default `:thread` scheduling); if a reload is requested meanwhile — e.g. after the agent edits an app file — the reloader queues for the exclusive lock and the callback's `executor.wrap` queues behind it, forever. With `config.allow_concurrency = false` the same wrapper blocks on the executor's monitor every time. The guide (and the `callback_wrapper` API docs and skill reference) now recommend `ClaudeAgentSDK::Railtie.callback_wrapper`; replace the bare lambda with it in existing initializers.

## [0.34.0] - 2026-09-23

The September 2026 audit campaign: 17 fixes from the final audit pass plus the 28 AUDIT-2026-09-22 issues (#66–#93). A few fixes tighten behaviour that was silently wrong — read **Changed** before upgrading.

### Added
- **`CLIInstaller::PINNED_CLI_VERSION`** (`'2.1.280'`, the CLI Python SDK 0.2.158 bundles) — the CLI version this gem release is developed and tested against; the Ruby equivalent of the Python SDK's bundled-CLI pin (`_cli_version.py`), except nothing is shipped inside the gem. Single source of truth: this constant is the only place the pin lives — docs and the transport's guidance reference it rather than repeating the literal.
- **`CLIInstaller.install_pinned(dir: nil)`** — installs exactly `PINNED_CLI_VERSION`. The Dockerfile / `bin/setup` form of "pin the tested pair": a deploy that calls it gets the SDK+CLI combination this release was tested with, and a Dependabot bump of the gem carries the CLI forward with it — no version literal in the caller to keep in sync. `install`'s default is unchanged (`'stable'` dist-tag), and explicit `version:` pins behave exactly as before.
- **`.github/workflows/cli-pin-bump.yml`** — scheduled (and manually dispatchable) workflow that reads the Python SDK's `_cli_version.py` on `main` and opens a PR moving `PINNED_CLI_VERSION` when it changes. It touches only that one line; cutting the follow-up patch release stays a human decision.

### Changed
- **Runtime dependency floors now name versions that actually work: `async >= 2.10, < 3` and `mcp >= 0.22, < 2`** (were `~> 2.0` / `>= 0.20`). A new CI leg runs the suite against exactly these floors: async 2.0.x cannot run on Ruby 3.2+ at all, releases before 2.6.4 break hook timeouts and control-request error delivery, and 2.10 is the first with `Task#defer_stop`, which `Query#close` now relies on. `mcp` 0.20/0.21 fail every `tools/call` of a tool whose schema uses `$ref` into `$defs`. Only bundles pinned below these floors are affected. (#87)
- **`config.default_options = {...}` stores a frozen deep copy.** Change defaults by assigning a new Hash; in-place mutation of the stored defaults (`config.default_options[:model] = 'x'`, `merge!`, including on the initial empty Hash) now raises `FrozenError`, and later changes to the Hash you passed have no effect. The snapshot's Strings are frozen too: a session built from configured defaults shares them, so reassign (`options.model = 'opus'`) rather than mutate in place. Your own Hash and objects, and identity-bearing values such as SDK MCP server instances, are never frozen. (#92)
- **`rename_session_via_store` / `tag_session_via_store` raise `Errno::ENOENT` for a session the store has never seen** (`#load` returns nil or `[]`), like their disk counterparts and `fork_session_via_store`, instead of appending — and so creating — a phantom session that could never be deleted on append-only stores. Deliberately stricter than the Python SDK's store helpers. (#85)
- **`exit`, `Interrupt` and signal exceptions raised inside an SDK MCP tool handler are reported in-band** as an `isError: true` result, so the `tools/call` control response is always written; previously they escaped dispatch (and in the default `:thread` scheduling `exit` tore down the session). Cancellation still propagates. A `callback_wrapper` now observes a `RuntimeError` whose `#cause` is the original exception. Hooks and `can_use_tool` are tracked in #119. (#77)
- **Transcript mirror `eager` mode no longer guarantees one `SessionStore#append` per frame.** At most one background drain runs at a time; frames arriving while an append is in flight are coalesced, in order, into the next one (see Fixed, #84). Adapters must not assume one frame per call.
- **Subagent readers only accept `agent_id`s matching `[A-Za-z0-9._-]+`** (never `.` or `..`); anything else returns `[]` / `nil` without calling the adapter, so a path- or prefix-keyed `SessionStore` can't be re-routed through the synthesized `subagents/agent-<agent_id>` subpath (now documented in the adapter contract). (#79)
- **Blank session metadata reads the same on disk and in a store:** whitespace-only `git_branch` / `tag` are `nil` and a blank `cwd` falls back to the project path on the disk path too. (#67)
- **S3 reference adapter (`examples/session_stores/s3_session_store.rb`)** reserves each part number through a per-transcript `.sequence` object with conditional writes, so appends stay ordered across adapter instances and clock skew. Requires an S3-compatible endpoint with strong consistency and conditional `PUT`; stop old writers before upgrading (mixed old/new writers are unsupported), and quiesce writers before deleting sessions. Each uncontended append costs two extra requests.
- **`CLIInstaller`'s `VERSION` file records the target platform** (OS, architecture, libc) alongside version and checksum, and the offline shortcut requires all three to match, so a cache copied from another platform is reinstalled instead of trusted. Older one- or two-line metadata needs one online reinstall, then works offline again.
- **SDK MCP servers reject a tool whose input schema declares a top-level `server_context` property** at registration (the `mcp` gem would silently overwrite it with its own context), and a call that passes one to a composed/referenced/free-form schema gets an actionable `isError` result without invoking the handler.
- The transport's "Claude Code not found" guidance, `docs/cli-installer.md` and the skill references now point at `install_pinned` (interpolating the constant) instead of a hardcoded example version that went stale with every CLI release.
- Docs, examples and the bundled `claude-agent-ruby` skill now use current model IDs (`claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5`) and recommend adaptive thinking plus `effort:`; `ThinkingConfigEnabled(budget_tokens:)` is described as the older-model path. `examples/extended_thinking_example.rb` no longer teaches the deprecated `max_thinking_tokens`. No API changes.

### Fixed

**Subprocess transport and teardown**
- **A stdin write cancelled mid-frame now poisons the transport instead of corrupting the session.** An `Async::Stop`, inline cooperative timeout or deadline landing while a large frame was parked on a full pipe left `ready?` true, so the next frame was appended to the partial one and every later message was invalid JSON. The original cancellation still propagates; every later write raises `CLIConnectionError` ("possible partial frame"). Recovery is a new session. (#80)
- **`close` and `end_input` no longer hang or strand a writer parked on a full stdin pipe.** A reactor fiber parked in the write is woken with the documented `CLIConnectionError`, and on Ruby 3.3+ a reactor-side close no longer hangs the whole reactor while a FiberBoundary worker thread is parked in the write. (#80)
- **`read_messages` no longer waits forever for a CLI that closes stdout and then hangs.** After stdout EOF the SDK waits 5 s, then TERM, then KILL, and raises `ProcessError` ("did not exit within 5s of closing stdout", negative-signal `exit_code`). (#73)
- **A truncated final stdout frame is reported** as `CLIJSONDecodeError` (`line` holds the partial frame) instead of the stream silently ending without its `ResultMessage`. Whitespace-only tails and reads cut short by `close` stay silent. (#89)
- **`Client#disconnect` called from inside an inline control-request callback, or from a streaming-input enumerator, now finishes the teardown before the caller unwinds.** The callback's task belongs to the tree the close stops, and the cascading `Async::Stop` used to interrupt `Query#close` before the transport and the close watcher were closed (a bare `Query#close` leaked the CLI process). The stop is now deferred through the teardown; the caller then unwinds with `Async::Stop` (use `ensure`, not `rescue StandardError`). A teardown error superseded by that Stop is warned on stderr. `:thread` mode, message blocks and observers are unchanged: `disconnect` returns normally there. (#81)
- **An outer `Async` timeout during `close` no longer makes the transport forget a still-live CLI process**: the timeout propagates and the TERM/KILL fallback keeps ownership. A cancelled close's background fallback releases the process from the at-exit registry only once it has actually been reaped.
- **Control requests fail promptly when the stream ends**: a clean read EOF broadcasts a terminal error to every waiting control request (they used to sit out the 1200 s timeout), and requests issued after EOF are rejected before writing. A control request's serialization, write and wait now share one deadline and one cleanup scope, so a failed or cancelled send never leaks its waiter and backpressure can't block past the configured timeout.
- **CLI stderr is scrubbed to valid UTF-8** for the `stderr` callback, `debug_stderr` and `ProcessError#stderr`, like stdout frames. (#90)
- **CLI discovery no longer accepts a non-executable file at a well-known install location** — a stray 0644 `~/.claude/local/claude` now ends in `CLINotFoundError` with install instructions instead of a raw `Errno::EACCES` at spawn. (#72)
- **Store-backed resume and CLI discovery work on hosts without a usable home directory** (`HOME` unset with no passwd entry, e.g. `docker --user` in a minimal image, or an empty/relative `HOME`): home-relative auth seeds and install locations are skipped instead of raising `ArgumentError`. `Sessions.config_dir` / `projects_dir` are tracked in #120. (#82)
- **Sandbox settings merging resolves a relative settings file against the CLI's `cwd`**, not the Ruby process's working directory.
- **`FiberBoundary` worker threads disable `report_on_exception` before the callback runs**, so a fast-failing callback is no longer also dumped to stderr. (#93)

**Options and configuration**
- **Typed option values are no longer shared by reference between sessions.** `SandboxSettings` (and its network/filesystem configs), `SystemPromptPreset` / `Custom` / `File`, `ToolsPreset`, `AgentDefinition`, `HookMatcher`, thinking configs, `TaskBudget`, `Mcp*ServerConfig` and `SdkPluginConfig` placed in `ClaudeAgentSDK.configure` defaults, or copied by `ClaudeAgentOptions#dup_with` (including values nested in `agents`, `hooks`, `mcp_servers`, `plugins`), are copied per instance via the new `Type#dup_for_options` hook — a per-session change to sandbox rules or a system prompt can no longer silently change what every other session sends to the CLI. Unfrozen Strings are copied too. Procs, observers and factories, SDK MCP server instances, session-store adapters and `callback_wrapper` keep their identity; CLI arguments are unchanged. (#69, #70)
- **`Configuration#default_options` is no longer a live Hash read without synchronization**: request-time merges read a private frozen snapshot, so a concurrent in-place write can no longer raise `can't add a new key into hash during iteration` or tear a merge. (#92)
- **String-keyed SDK MCP server configs are recognized** (`{ 'tools' => { 'type' => 'sdk', 'instance' => server } }`, and `type: :sdk`): the instance is registered in-process, stdin stays open for its tool calls, and it is never serialized into `--mcp-config`. (#68)
- **`Client` normalizes input like `query()`**: a bare Hash prompt is rejected before anything is spawned (it used to stream Ruby inspection strings), and `nil` / empty hook lists are accepted instead of crashing `connect`.
- **Class-valued shorthand tool schemas work**: the documented `{ id: Integer }` advertises and accepts an integer (it advertised a string and rejected integers); `Float`, `TrueClass` and `FalseClass` likewise.
- **`ResultError`'s message and `#api_error_status` share one Integer narrowing**, so a non-Integer status (e.g. `"500"`) no longer appears as `API error (HTTP 500)` while the accessor returns `nil`. (#76)

**Sessions and SessionStore**
- **A single unserializable store entry no longer aborts a store-backed resume.** Entries (and subagent metadata sidecars) that JSON can't encode — NaN/Infinity, invalid UTF-8, circular or over-deep nesting — are skipped with a warning naming the entry's `uuid`; well-formed entries are written byte-for-byte as before. A session with no usable entries behaves like an empty one, and `--continue` classifies sidechains from the first surviving entry. (#83)
- **Non-String subkeys from a `SessionStore` are rejected** like any other unsafe subkey instead of raising `NoMethodError` and aborting the resume. (#91)
- **Store-backed listings coerce adapter `mtime` values** (ISO-8601 or numeric strings, e.g. SQL timestamps through JSON): they list newest first — they came back oldest first, so `limit:` cut off the newest sessions — and mixed Integer/String mtimes no longer raise. (#66)
- **Session listings break equal-mtime ties by `session_id`**, so `offset:` / `limit:` pages are stable across calls and never skip or repeat sessions, and disk and store listings order identical input identically. (#78)
- **Disk and store paths agree on sidechain classification and blank summaries**: a corrupt, blank, non-object or invalidly encoded first transcript line no longer makes one path list a session the other hides (the disk reader now classifies from the first parseable entry, as the store path did), and whitespace-only (or invalidly encoded) summaries/titles are blank on both. (#67, #75)
- **Session read APIs validate ids at the boundary**: a non-String or invalidly encoded `session_id` / `agent_id` gets the same `nil` / `[]` as a malformed id (and `import_session_to_store` raises `ArgumentError`) instead of a deep `NoMethodError` / `ArgumentError`. (#74)
- **The transcript mirror no longer piles up background tasks when the `SessionStore` is slower than the CLI's frame rate**: at most one drain task runs, and later frames are buffered and coalesced in order, without ever slowing the read loop. (#84)
- **Rename and tag no longer corrupt a transcript whose last record lacks a trailing newline**: the metadata record is written on its own line.
- **Forked sessions are published atomically**: the fork is written to a private temporary file and hard-linked into place, so a failed fork never leaves a partial session under its final id (filesystems without hard links fail safely).
- **An explicitly cleared custom or AI title at the end of a long transcript stays cleared** on the disk path (it resurrected an older title from the file head).
- **`InMemorySessionStore` deep-copies entries and summaries** across `append` / `load` / summary boundaries, so callers can no longer mutate stored transcripts through the objects they passed in or got back.
- **The SessionStore conformance kit checks summary content** (latest title, first timestamp, first prompt, sidechain classification across appends and refolds), so an adapter returning empty or stale summaries now fails it.
- Docs and the bundled skill describe what store-backed resume really seeds (`settings.json` / `cowork_settings.json` included since 0.31). (#86)

**Observability**
- **`OTelObserver` records per-turn cost increments** for `gen_ai.usage.cost` / `llm.cost.total`; the CLI reports cumulative `total_cost_usd`, so summing spans used to double-count earlier turns.
- **OpenTelemetry parent context is preserved across the SDK's fibers and threads** (`query()` / `Client.open` reactors, Query's background tasks, FiberBoundary worker dispatch), so observer and callback spans attach to the caller's trace instead of starting detached.

**Examples and tooling**
- `examples/error_handling_example.rb`'s retry helper now retries what the SDK raises: `ResultError` only for transient API statuses (429, 529, other 5xx), then bare `ProcessError` with bounded backoff. (#88)
- CI runs the suite against the newest allowed majors (json 3.x, mcp 1.x) and the declared dependency floors. The git-less gemspec fallback packages the same files git would; `docs/errors.md` lists `ResultError`; flaky ordering sleeps in specs are gone. (#87, #93)

## [0.33.1] - 2026-09-21

Compatibility with `json` 3.x and `mcp` 1.x. Upgrade if your bundle resolves `json` 3.x — `rename_session` / `tag_session` raise on 0.33.0.

### Changed
- `mcp` dependency is now `>= 0.20, < 2` (was `>= 0.6, < 1`). The floor moves to 0.20 because `mcp` 0.19 and older validate through the `json-schema` gem, which breaks under `json` 3.x and fails every SDK MCP `tools/call`; with `json` 2.x those versions still pass, so this only forces an `mcp` upgrade on bundles pinned below 0.20. The suite passes against every 1.x release through 1.6.0, and `initialize` / `tools/list` / `tools/call` / `resources/*` / `prompts/*` wire output is byte-identical to 0.2x.
- SDK MCP tool handler exceptions now reach the model as the bare exception message (matching Python's `str(e)` and `SdkMcpServer#call_tool`) instead of the gem's `Internal error calling tool X: msg`. The exception is rescued inside the SDK's tool class, so the text no longer depends on the `mcp` gem version — `mcp` 1.2+ redacts the message from its own wrapper, which would otherwise have left the model with no error text to self-correct from. Still in-band `isError: true`.

### Fixed
- `rename_session` / `tag_session` raised `ArgumentError: unknown keyword: space_size` under `json` 3.x, which takes generator options as strict keywords. The option was a no-op on `json` 2.x (output unchanged), so it is simply gone. A fresh end-user bundle resolves `json` 3.x through `async → console → json`; CI missed it only because the dev-only RuboCop pin holds `json` at 2.x.

## [0.33.0] - 2026-09-21

Subagent capabilities for UI builders: metadata reads, background snapshots, cooperative callback cancellation, and the task/background/permission signals the CLI already emits — all raw data and controls, no status model. Ruby-ahead of the Python SDK (0.2.153).

### Added
- `get_subagent_metadata` / `get_subagent_metadata_from_store`: read optional subagent metadata with original string keys, including type, spawning tool ID, parent agent, depth, and future CLI fields. Disk reads reuse transcript scoping without parsing the transcript; store reads select the latest metadata entry even before messages arrive. These are historical reads, not live-status queries.
- `background_tasks` and `session_crons` on `StopHookInput` / `SubagentStopHookInput`. Raw snapshots preserve unavailable (`nil`) versus explicitly empty (`[]`) and describe the parent session, not all foreground/background agents.
- Cooperative permission cancellation through `ToolPermissionContext#signal` (`CancellationSignal#cancelled?` / `#wait`) and the associated `request_id`. CLI cancellation, disconnect, EOF, and failed dispatch invalidate pending requests, including callbacks running on worker threads; normal decisions do not. User threads are not forcibly stopped, and late decisions after observed cancellation cannot become allow responses.
- `HookContext#signal` / `#request_id` use the same per-invocation cancellation contract, including hook timeouts. Thread callbacks can cooperate with cancellation; late hook output is discarded.
- A minimal subagent event subscription example and capability reference covering lifecycle events, metadata, background snapshots, and permission cancellation. UI and application status aggregation remain outside the SDK.
- Opt-in real-CLI subagent contract tests for ID/metadata/text correlation, permission cancellation on interrupt, and background completion/stop after a parent result. They self-skip without CLI credentials.
- Subagent UI signals the CLI already emits, read from the schema embedded in Claude Code CLI 2.1.278 (the Python SDK has none of these as of Python SDK 0.2.153; only partly verified live — a smoke run against CLI 2.1.278 confirmed the `task_started` fields and the targeted-miss `background_tasks` response; the rest is schema-derived). The SDK exposes raw data and controls only — no status aggregation.
  - `TaskStartedMessage#subagent_type` / `#is_backgrounded` / `#spawn_depth`, `TaskProgressMessage#subagent_type`, `TaskNotificationMessage#reason` / `#resource_links` (raw Array, symbol keys with the wire spelling), the `#skip_transcript` / `#ambient` display flags on both `TaskStartedMessage` and `TaskNotificationMessage` (hints for the host — the SDK never filters frames or computes activity), and `TaskUpdatedMessage#is_backgrounded` / `#error` / `#end_time` / `#total_paused_ms` / `#description` derived from `patch` like `status`. `is_backgrounded` keeps `nil` (not reported) distinct from an explicit `false` (foreground, spawning tool call blocking). `TaskUpdatedMessage` now also reads a string-keyed `patch` on hand-built messages.
  - `BackgroundTasksChangedMessage` (`background_tasks_changed`): the full set of live background tasks, a level signal with REPLACE semantics. The SDK's own stdin-close bookkeeping still deliberately ignores this frame.
  - `PermissionDeniedMessage` (`permission_denied`): a tool call auto-denied without an interactive prompt, with `agent_id` for subagent routing (not a permission `request_id`). A best-effort advisory, not a complete denial feed — `ResultMessage#permission_denials` stays authoritative.
  - `Client#background_tasks(tool_use_id: nil)` / `Query#background_tasks`: send in-flight foreground tasks to the background (Ctrl+B). Keyed by the spawning `tool_use_id`, not `task_id` / `agent_id`. The targeted form returns `{ backgrounded: true }` or `{ backgrounded: false }` — a definitive miss, after which no event is coming; `nil` is the explicit all-tasks form and returns `{}`. Because the CLI treats `''` as "all tasks", anything other than `nil` or a non-empty String raises `ArgumentError` before a request is written. `TaskUpdatedMessage#is_backgrounded` / `BackgroundTasksChangedMessage` report the lifecycle state that follows.
  - `ClaudeAgentOptions#agent_progress_summaries`: request model-generated progress summaries for subagents; `TaskProgressMessage#summary` may then be present, and stays optional. Tri-state; `nil` omits `agentProgressSummaries` from the `initialize` request and `true` / `false` are forwarded verbatim. An enable switch, not a live toggle: CLI 2.1.278 only acts on a truthy value, so `false` is equivalent to unset.
  - **Compatibility:** `background_tasks_changed` and `permission_denied` frames previously parsed as a generic `SystemMessage`. Both new classes subclass it, so `when SystemMessage` and `#data` consumers are unaffected; code matching on `message.class == SystemMessage` will no longer see them.

### Fixed
- Best-effort control error/cancellation replies no longer leak a secondary connection error when the CLI has already exited. Original transport read errors still propagate to the consumer.
- Control-request tracking is identity-guarded: if the CLI ever reused an in-flight request ID, the first handler finishing no longer untracks the later request's cancellation signal or task, so EOF, disconnect, and `control_cancel_request` still invalidate it and its late decision cannot be sent as a success.
- `ClaudeAgentSDK.configure` defaults now merge by option, not by literal key spelling. `ClaudeAgentOptions` accepts symbol/string and snake_case/camelCase names, but the defaults merge compared raw keys, so a differently spelled per-call key rode along as a second entry: `'permissionMode' => nil` wiped a configured `permission_mode:` instead of inheriting it, and a Hash option such as `'env' => {...}` replaced the configured `env:` instead of merging into it. Unknown option names are still reported with the caller's own spelling.

## [0.32.0] - 2026-09-17

Syncs the gem with Python SDK **0.2.153** (previously 0.2.147). The intervening Python releases 0.2.148–0.2.152 only bump the CLI binary Python bundles; this gem does not vendor a CLI, so they carry no Ruby-side change.

### Added
- **`snapshot` on `SystemPromptPreset`, and a new `SystemPromptCustom` type** (port of Python [#1268](https://github.com/anthropics/claude-agent-sdk-python/pull/1268), v0.2.153). By default the CLI records the system prompt on a session's first request and reuses it on every later request, including after resume, so a changed `append` or custom prompt has no effect until the session is compacted or a new one starts. `snapshot: false` makes the CLI rebuild the prompt on every request instead — useful while iterating on prompt text across calls that resume the same session. `SystemPromptCustom` (`prompt:`, `snapshot:`) is the object form of a String prompt, so `snapshot` can travel with it; the `{ type: 'custom', prompt: '...', snapshot: false }` and `{ type: 'preset', ..., snapshot: false }` Hash forms are accepted too. The value rides on the control-protocol `initialize` request as `systemPromptSnapshot` (never as a CLI flag), so it applies to both `query()` and `Client`; `false` is sent explicitly and only an unset value is omitted. `SystemPromptFile` has no `snapshot`, and one given on a file Hash is ignored, as in Python. Requires Claude Code CLI 2.1.257 or later; before 2.1.265 a session with an `append` or custom prompt recorded it only when `snapshot` was `true`. Older CLIs silently ignore the field.
  - **Compatibility:** a `{ type: 'custom', ... }` Hash previously fell through the command builder unrecognised — pushing no flag at all — and so silently activated the *default* Claude Code system prompt. It now forwards `--system-prompt <prompt>` exactly like a String, and a custom prompt without a String `prompt` raises `ArgumentError` at command-build time rather than falling through (Python raises `KeyError` on the same input).

## [0.31.0] - 2026-08-28

Syncs the gem with Python SDK **0.2.147** (previously 0.2.134). The intervening Python releases 0.2.135/136/138/139/141–147 only bump the CLI binary Python bundles; this gem does not vendor a CLI, so they carry no Ruby-side change.

### Added
- **`ConversationResetMessage`** (port of Python [#1196](https://github.com/anthropics/claude-agent-sdk-python/pull/1196), v0.2.137). The CLI announces a mid-session transcript discard (`/clear`, and any other flow that replaces the conversation without ending the connection) with a top-level `conversation_reset` frame. It was previously dropped by the parser's forward-compatibility fallthrough, so applications never saw resets — including ones they did not initiate. Carries `new_conversation_id`, `uuid` and `session_id`. A reset also **zeroes the running totals** on subsequent `ResultMessage`s (`total_cost_usd` and friends), so snapshot them when this arrives. `new_conversation_id` is not the next `session_id`; read that from the following message.
  - **Compatibility:** this widens the `Message` union with a frame that was previously dropped silently. Code that raises on an unrecognized message class (`case msg ... else raise`) will now see it — on the first `/clear` of a long-lived session.
- **`origin` on `UserMessage` and `ResultMessage`** (port of Python [#1199](https://github.com/anthropics/claude-agent-sdk-python/pull/1199), v0.2.137). In streaming/`Client` mode one connection interleaves the turns the application sends with turns the session injects on its own — background-task notifications, fired scheduled-task prompts, MCP channel messages, messages relayed from peer sessions. `origin` distinguishes them, so a consumer can tell "this result answers my prompt" from a task-notification follow-up. The CLI's object is passed through **verbatim** — including keys this version does not model, so newer origin kinds stay visible — and anything that is not an object with a String `kind` reads as `nil`. **Keys are Symbols and non-`kind` keys keep the CLI's camelCase spelling** (`origin[:fromSession]`), unlike the Python SDK's string-keyed equivalent. Prompts sent through `query()` / `Client#query` arrive unattributed unless the host stamps `origin: { kind: 'human' }` itself.
- **`ClaudeAgentOptions#forward_subagent_text`** (port of Python [#1206](https://github.com/anthropics/claude-agent-sdk-python/pull/1206), v0.2.140). Forwards a subagent's text and thinking blocks as messages in the stream, not just its `tool_use` / `tool_result` blocks, so consumers can render the full nested transcript. Negotiated on the control-protocol handshake, so it applies to both `query()` and `Client`. Matches the TypeScript SDK's `forwardSubagentText`.
- **`ClaudeAgentOptions#resume_drops_turn`** (port of Python [#1198](https://github.com/anthropics/claude-agent-sdk-python/pull/1198), v0.2.137). Completes the truncating-resume pair alongside the existing `resume_session_at`: names the user prompt whose turn a truncating resume intends to discard, and the CLI refuses the resume if anything past the fork point is not attributable to that turn — so a caller can rewind to "before my last prompt" without silently dropping a queued message or task notification the session absorbed mid-turn and the caller never observed. A refusal surfaces as a `ResultError` whose message contains `Resume rejected by --resume-drops-turn:`; treat it as deterministic rather than retrying. Forwarded in equals form, and an empty string is forwarded rather than dropped so the CLI rejects it as malformed instead of the SDK silently disarming a guard the caller believes is armed. As in the TypeScript and Python SDKs, no SDK-side validation of the option combination is applied.
- **`ClaudeAgentSDK::ResultError`** (port of Python [#1205](https://github.com/anthropics/claude-agent-sdk-python/pull/1205), v0.2.140). When a run fails, the CLI emits a `result` with `is_error: true` and then exits non-zero on purpose, for shell-script consumers; the trailing failure carried nothing beyond "exit code 1". The SDK now raises a typed `ResultError` carrying `subtype`, `errors`, `result`, `api_error_status`, `terminal_reason`, `session_id`, the raw `data`, and `original_error` (the bare exit failure it replaced), so callers can branch on *why* a run failed without string matching. It **subclasses `ProcessError`**, so existing `rescue ProcessError` handlers keep working — rescue `ResultError` first to reach the structured fields.
- **`SessionMessage#parent_agent_id`**, and `parent_tool_use_id` is now populated for subagent transcripts (port of Python [#1207](https://github.com/anthropics/claude-agent-sdk-python/pull/1207), v0.2.140). `get_subagent_messages` and `get_subagent_messages_from_store` previously returned `parent_tool_use_id: nil` for every message, losing the link to the Agent `tool_use` block in the parent session that spawned the subagent. Both are now recovered from the `agent-<id>.meta.json` sidecar (or the `agent_metadata` entry in a `SessionStore`), and stay `nil` when it is missing or unusable.

### Fixed
- **A refused or failed resume no longer reports a bare "exit code 1" to in-flight control requests** (port of Python [#1198](https://github.com/anthropics/claude-agent-sdk-python/pull/1198)). The CLI reports a rejected resume as an error result on stdout and then exits **before** answering the SDK's `initialize`. The read loop already replaced the generic process failure with the CLI's own error text for the message stream, but pending control requests — including that in-flight handshake — were signalled with the raw exception first, so callers saw `Command failed with exit code 1` with the actual reason discarded. Pending requests now receive the same enriched `ResultError`. This also improves resuming a nonexistent session, which takes the same path.
- **`can_use_tool` no longer has its permission requests cut off when it is the only bidirectional feature in use.** The check deciding whether the CLI may still send control requests needing a reply considered only SDK MCP servers and hooks, so an `Enumerator` prompt using `can_use_tool` with neither of those closed stdin as soon as the input ended; any later permission `control_request` then failed CLI-side with "Stream closed". This was a live defect on an already-supported path, independent of the string-prompt change below.
- **Store-backed resume now seeds the caller's `settings.json` and `cowork_settings.json`** into the temporary config directory (port of Python [#1197](https://github.com/anthropics/claude-agent-sdk-python/pull/1197), v0.2.137). Only `.credentials.json` and `.claude.json` were copied, leaving behind `apiKeyHelper` — a fourth authentication mechanism alongside the credentials file, the macOS Keychain and environment variables — plus the user's `env`, `hooks` and `permissions`. A host authenticating solely via `apiKeyHelper` therefore failed with **"Not logged in"** the moment it resumed from a store, with nothing in the error pointing at why. Both files pass through a transform dropping `enabledPlugins` / `extraKnownMarketplaces` (which would reconcile against the always-empty temporary plugin cache and network-install every declared marketplace on each resume) and `env.CLAUDE_CONFIG_DIR` (which would point the subprocess's config reads back out of the temporary directory). A UTF-8 BOM is tolerated, content that is not a JSON object is copied through byte-for-byte, and the result is written `0600`.
- **A seed file that cannot be read no longer aborts an otherwise-valid resume.** These files are best-effort enrichment of the temporary config directory: a failure other than "not found" is now logged and skipped (removing any partial destination) rather than propagating. Readers also check for a regular file before opening, so a directory or a FIFO in place of a config file is skipped instead of raising — or, for a FIFO, hanging the resume forever.
- **An unusable subagent metadata sidecar no longer breaks every later resume.** `JSON.parse` is lenient about illegal bytes inside an otherwise well-formed UTF-8-tagged document, returning a Hash holding invalidly-encoded values that only fail later, at generate time. Session import persisted such a Hash as an `agent_metadata` entry, and every subsequent resume through that store then died re-serializing it with an opaque `JSON::GeneratorError` — permanently, until the store entry was repaired externally. Unusable bytes are now treated as an absent sidecar, matching the helper's documented contract. The same regular-file guard prevents a FIFO sidecar from hanging `get_subagent_messages`.
- **`settings.json` containing a lone surrogate escape is no longer copied through unstripped.** Ruby's `JSON.parse` rejects lone surrogates outright, which fell back to the byte-for-byte passthrough — so `enabledPlugins` survived and the resumed CLI went on network-installing marketplaces on every resume, the exact misbehavior the seeding transform exists to prevent.
- **Redacting `.credentials.json` no longer aborts a resume on a serialization failure**, and its comment now describes what the code actually does; the rescue covered only parse failures, so a generate failure propagated and took down a resume that every other seed-file path is designed to survive.

### Changed
- **`can_use_tool` now works with a String prompt** (port of Python [#1204](https://github.com/anthropics/claude-agent-sdk-python/pull/1204), v0.2.140). The callback previously required an `Enumerator` prompt and raised `ArgumentError` otherwise. The SDK is always streaming internally, so the restriction was unnecessary once stdin is held open for the permission round-trip. Validation of the `can_use_tool` / `permission_prompt_tool_name` conflict and the shadowing advisory are now shared by `query()` and `Client#connect` instead of duplicated.


## [0.30.0] - 2026-08-09

### Added
- **`ClaudeAgentSDK::CLIInstaller`** — downloads a pinned `claude` CLI binary into a project-local directory (`vendor/claude` by default) for hermetic deploys, so a Docker image or CI job runs a known CLI version instead of whatever `npm install -g` last put on `PATH`. `CLIInstaller.install(version: '2.1.220', dir: nil)` resolves `stable`/`latest` dist-tags through the official release endpoint, verifies the platform's SHA-256 from the release manifest, streams the ~280MB binary to an unpredictable sibling temp file (opened `O_EXCL`, so a pre-planted path or symlink is never written through) and renames it into place atomically (`0755`), then records the version **and** the verified checksum in a sibling `VERSION` file. `CLIInstaller.installed_path` returns the vendored binary or `nil`. Stdlib only — no new runtime dependency, and no binary shipped inside the gem. Supports macOS and Linux (glibc + musl, x86_64 + arm64, with a Rosetta 2 override so an x86_64 Ruby on Apple Silicon gets the native build); every failure raises the new `ClaudeAgentSDK::CLIInstallError`, filesystem errors included (wrapped, with `cause` preserved).
  - **Idempotent without trusting the recorded version alone**: the shortcut re-hashes the vendored binary and skips the download only when version *and* checksum match, so a truncated or swapped binary is reinstalled rather than used. It makes no network request — repeat boots work offline.
  - **Concurrency-safe**: an exclusive `flock` on `<dir>/.install.lock` covers dist-tag resolution and the whole check → download → record → publish sequence (last resolver wins, so a slow installer cannot downgrade a newer version published while it waited), and the `VERSION` file is written atomically (temp + rename), so parallel installs into one directory can never observe or produce a half-installed state. Temp files abandoned by an install that was killed before it could clean up are swept on the next run. Discovery (`installed_path`, `find_cli`) stays lock-free: the binary only ever changes by an atomic rename of a fully verified file, so a reader sees the intact old binary or the intact new one.
  - **A failed install never breaks a working one**: the binary is downloaded, verified and *recorded* before the rename that publishes it, and nothing can fail after that rename. A failed upgrade therefore leaves the previously installed binary intact and runnable, with the next `install` redoing it cleanly; a failed first install leaves nothing behind.
  - Text responses are size-capped (1KB for the version endpoint, 5MB for the manifest), and the binary download is bounded by the manifest's declared `size` when present — an over-long stream is aborted instead of filling the disk. The binary streams to disk and is never buffered in memory.
- **CLI discovery now honors `CLAUDE_CLI_PATH` and the vendored binary.** `SubprocessCLITransport#find_cli` probes `CLAUDE_CLI_PATH` (when it points at an executable), then `CLIInstaller.installed_path`, then the existing `which claude` and common-location logic. The vendored copy deliberately outranks `PATH` — that is what makes a pinned install hermetic. `CLINotFoundError` now also mentions both escape hatches.

## [0.29.0] - 2026-08-09

### Fixed
- **Skill names in `ClaudeAgentOptions#skills` are now validated** (port of Python SDK [#1145](https://github.com/anthropics/claude-agent-sdk-python/pull/1145), v0.2.129). Names were formatted into the `--allowedTools` value unchecked; the CLI splits that value into permission rules on commas and spaces outside parentheses with no escape sequences, so a name carrying a delimiter could not be passed through reliably. The command builder now validates each name and fails closed with `ArgumentError` (`TypeError` for non-String entries). Rejected: parentheses, commas, control characters (C0, DEL, C1), U+FEFF, empty names; a literal `*` and wildcard suffixes (`:*`, ` *`); and shapes that parse but can never match the listed skill — surrounding whitespace (Unicode-aware, unlike `String#strip`), a leading `/`, consecutive backslashes, a trailing unpaired backslash, and byte sequences that cannot form valid UTF-8 (Ruby's analogue of Python's surrogate check). Ordinary names are unaffected, including plugin-qualified names, interior spaces, single backslashes, and non-ASCII; valid non-UTF-8 strings are converted so the argv join cannot raise `Encoding::CompatibilityError`.
  - **Breaking:** `skills: ['*']` and `skills: ['plugin:*']` now raise — use `skills: 'all'`, or a `Skill(...)` rule in `allowed_tools` for prefix matching. `skills: [' name']` and `skills: ['/name']` now raise as well; both previously built a rule that could never match, so the skill was silently unavailable.

## [0.28.0] - 2026-07-31

### Changed
- **`callback_wrapper` now composes around timeout-bounded SessionStore adapter dispatch** (mirror-batcher appends and every resume-materialization store call), inside the timeout bound — on the worker thread in the default thread-hop mode, inside the cooperative timeout for inline-declared adapters. A Rails `executor.wrap` wrapper therefore covers an ActiveRecord-backed store adapter too: connections check out and back in per call instead of stranding on the throwaway thread. The bound itself is unchanged (`JoinTimeout` semantics, no-retry-on-timeout); a wrapper-raised error is treated like a store error (retryable on the batcher path). Previously the timeout path silently ignored the wrapper.

### Fixed
- `SdkMcpServer#callback_scheduling=` / `#callback_wrapper=` now validate like their `ClaudeAgentOptions` counterparts: the String form (`"inline"`) is coerced to the Symbol, and invalid values raise `ArgumentError` at set time. Previously the bare accessors accepted anything, and because the dispatch layer special-cases only the exact Symbol `:inline`, a String or typo silently degraded to the thread hop — the opposite of what an inline host asked for.
- The once-per-process `:inline`-under-`isolation_level = :thread` warning is now emitted under a mutex, closing a benign race where two sessions connecting concurrently could both warn.

## [0.27.0] - 2026-07-31

### Added
- **Fiber-native SessionStore adapters** (#47 phase 3): an adapter whose IO is entirely Fiber-scheduler-aware can declare it by defining an optional `callback_scheduling` method returning `:inline`. Every timeout-bounded store call the SDK makes (mirror-batcher appends; resume-materialization loads **and** the listing methods `list_sessions` / `list_session_summaries` / `list_subkeys`) then runs in place on the reactor fiber under a **cooperative** timeout — interrupted at the next suspension point with `ensure` blocks running — instead of on a throwaway thread with a hard `Thread#join` bound. The outward exception contract is unchanged (`FiberBoundary::JoinTimeout`); undeclared adapters are byte-for-byte untouched, and outside a reactor the hard bound still applies even for declared adapters. Cancellation reaches only the adapter's own fiber (offloaded work may still land afterwards), so timed-out appends are not retried in either mode and may remain permanently half-applied in the store — the drop is surfaced (`MirrorErrorMessage`, `batches_dropped?`) and the local transcript remains the source of truth. An invalid declared value fails fast with `ArgumentError` at construction, and a declaration that itself raises propagates its own exception at the same construction point rather than mid-session (conformance contract 17 covers both). Apps can opt a third-party fiber-native adapter in via `def store.callback_scheduling = :inline`.

## [0.26.0] - 2026-07-31

### Added
- **`ClaudeAgentOptions#callback_wrapper`** (#47 phase 2): optional middleware wrapped around every user-callback dispatch (message blocks, observers, hooks, permission callbacks, SDK MCP handlers). A callable receiving a zero-arg invocation that it must call and return: `callback_wrapper: ->(inv) { Rails.application.executor.wrap { inv.call } }`. The wrapper runs on the same execution context as the callback — inside the worker thread in the default `:thread` mode (so `executor.wrap` checks ActiveRecord connections back in when the callback ends, retiring the stranded-connection workaround without adopting `:inline`), in place on the reactor fiber in `:inline` mode. Exceptions propagate through it unchanged. Also settable per SDK MCP server for direct calls (`server.callback_wrapper=`); session dispatches carry the session's wrapper via the same fiber-storage scope as `callback_scheduling`. See "Rails executor around callbacks" in docs/rails.md.

## [0.25.0] - 2026-07-31

### Added
- **Opt-in fiber-native callback execution: `callback_scheduling: :inline`** (#47). By default the SDK hops every user callback (message blocks, hooks, permission callbacks, SDK MCP handlers, observers) to a plain thread so thread-keyed libraries (ActiveRecord, pg, …) never see the async gem's Fiber scheduler. Hosts that are fiber-isolated end to end — e.g. solid_queue fiber workers (`fibers: N`) with `ActiveSupport::IsolatedExecutionState.isolation_level = :fiber` — can now pass `ClaudeAgentOptions.new(callback_scheduling: :inline)` (or set it globally via `ClaudeAgentSDK.configure`) to run callbacks in place on the reactor fiber: `Fiber.scheduler` is live inside callbacks, no per-call threads exist to strand AR connections, and the session can live directly on the job fiber. This matches the Python SDK's execution model (async callbacks run natively on the event loop). Default behavior is unchanged. In `:inline` mode hook timeouts become cooperative cancellations (the hook is interrupted at its next suspension point and its `ensure` blocks run) instead of hard thread abandonment; `SessionStore` adapter calls intentionally stay on threads so a wedged adapter can never stall the reactor. The SDK warns once when `:inline` is enabled under `isolation_level == :thread`. See "Fiber workers (solid_queue)" in docs/rails.md.
- `ClaudeAgentSDK.offload { }` — public escape hatch for `:inline` hosts: runs a heavy piece of a callback on a plain thread instead of the reactor fiber. Shields the reactor from scheduler-opaque blocking that releases the GVL (native DB drivers, file/socket I/O); turns pure-Ruby CPU work into GVL time-slicing instead of a hard stall. A C extension that holds the GVL for the whole computation still freezes the process — move such work to a subprocess. No-op outside a reactor.

## [0.24.0] - 2026-07-27

Parity batch with the Python SDK v0.2.111–v0.2.128 (everything substantive in that span; the rest is bundled-CLI version bumps, which don't apply to this gem).

### Fixed
- **argv flag injection via `resume` / `session_id` / `resume_session_at`** (Python #1123): these values are now passed as single `=`-joined argv tokens (`--resume=<value>`). The CLI declares `--resume [value]` with an *optional* value, so in the old two-token form a dash-leading untrusted value (e.g. a session id taken from a request) was not bound to the flag and parsed as an independent CLI flag — letting it inject e.g. `--dangerously-skip-permissions`. `extra_args` values starting with `-` are likewise emitted in `--flag=value` form (Python #1127); other `extra_args` values keep the two-token form.
- **Premature stdin close while background tasks are in flight** (Python #1103): a `result` frame ends one *turn*, not the run. The SDK no longer closes stdin on a result while `run_in_background` subagents (task types `local_agent`/`local_workflow`) are still running — previously their SDK-MCP tool calls failed with `"Stream closed"` and their PreToolUse hooks were silently bypassed (deny-gates stopped gating). In-flight tasks are tracked from `task_started` / `task_notification` / terminal `task_updated` lifecycle frames; stdin closes on the first result with none in flight. Background shells/teammates are deliberately not tracked (they may never reach a terminal status, which would withhold the close forever).
- **Leaked CLI child when a cancellation interrupts `close`** (Python #1082): the graceful TERM→KILL escalation in `SubprocessCLITransport#close` suspends (task sleep, thread join), so `Async::Stop` delivered mid-close abandoned it and left a live `claude` child running until interpreter exit. `close` now guarantees termination from an `ensure` with no suspension points: synchronous SIGTERM immediately, then a plain background thread escalates to SIGKILL after a 2s grace period; on that path the child also deliberately stays in the `at_exit` registry as a second safety net, and the stdin/stdout/stderr pipes are closed best-effort (references cleared first, so even a failed close leaves them collectable) instead of leaking descriptors for the life of the transport object.

### Added
- `ResultMessage#terminal_reason` (Python #1142): why the query loop ended (`"completed"`, `"max_turns"`, `"aborted_streaming"`, …). `"aborted_streaming"` / `"aborted_tools"` mean the turn was cancelled via `Client#interrupt`. `nil` when the CLI does not report one (older CLIs, or a result that bypassed the query loop such as a local slash command).
- **Advisory warning when `can_use_tool` is shadowed** (Python #1081): the callback is only consulted when the CLI's permission ladder lands on "ask", so `permission_mode: 'bypassPermissions'` or an `allowed_tools` entry that allows a whole tool (`'Read'`, `'Read()'`, `'Read(*)'` — including the bare `Skill` implied by `skills: 'all'`) silently turns a security callback into dead code. `query()` / `Client#connect` now warn to stderr, once per distinct message per process (`ClaudeAgentSDK::OptionWarnings.reset!` clears the dedupe for tests). Real specifiers (`'Bash(ls:*)'`) and malformed entries don't warn; never raises. The permission-callback docs/example no longer demonstrate the shadowed combination.
- Documented the `ResultMessage#model_usage` per-model value shape (verbatim CLI camelCase keys, matching the TS/Python `ModelUsage` type), including the new optional `canonicalModel` and `provider` keys (Python #1143 — type-only upstream, so a doc change here).

## [0.23.0] - 2026-07-14

### Added
- `ClaudeAgentOptions.advisor_model` enables Claude Code's experimental server-side [advisor tool](https://code.claude.com/docs/en/advisor) (`--advisor` CLI flag): the main model consults a stronger advisor model at key decision points. Accepts a model alias (`'opus'`) or full model ID. Anthropic API only; the CLI validates the main-model/advisor pairing, so invalid pairings surface as `ProcessError`. Consultations appear in `AssistantMessage` content as `ServerToolUseBlock` (name `'advisor'`) and `ServerToolResultBlock` blocks, which the SDK already parsed. See `examples/advisor_example.rb` and the new "Advisor Model" section in `docs/configuration.md`.

## [0.22.0] - 2026-07-03

Final batch (Batch D) from the 2026-07-03 full-codebase audit, closing it out: tests/docs/examples plus the three recorded split-verdict findings (P1-P3). Minor because the conformance suite gained a contract (an adapter that passed 0.21.0 can now fail contract 16) and new API surface (`check_uuid_dedupe:`).

### Fixed
- OTel observer: the next turn's prompt is no longer dropped from the new trace after an interrupted turn or `/clear` (a superseding init with no ResultMessage) — prompts arriving while the current trace already has its input are buffered for the next trace instead of being latched out; a prompt queued mid-turn now labels its own trace too.
- Disk session listings no longer misclassify a session as a sidechain from a nested `"isSidechain":true` inside a structured field: the first line is parsed and the top-level key checked (same as the store fold), with the substring heuristic kept only for window-truncated first lines.
- SDK MCP servers: propertyless object schemas (`{ type: 'object', additionalProperties: ... }`, `oneOf`, accept-anything forms) now pass through intact instead of being mangled into nonsense parameter lists ("additionalProperties" advertised as a required string param).
- `import_session_to_store` skips an unparseable trailing line with a warning (an ordinary interrupted-CLI artifact every read path already tolerates) instead of aborting mid-import with a raw `JSON::ParserError` and leaving a partial store import behind.
- Redis reference adapter: the delete cascade now WATCHes the subkey set, so a concurrent eager-mode append can no longer orphan a freshly-created subagent list forever; both the Redis and Postgres reference adapters stamp mtimes through a monotonic guard (like S3) so a backward clock step can't misdirect `--continue`.
- Redis example spec no longer FLUSHDBs whatever `SESSION_STORE_REDIS_URL` points at — it uses a random key prefix per run with prefix-scoped cleanup, like the Postgres spec.

### Added
- Conformance suite contract 16: `list_sessions` must return exactly one row per session under multiple appends (the naive one-row-per-append implementation previously passed every contract, then showed N duplicate sessions in pickers). Contract 4 now also asserts `append([])` cannot create a phantom key. New opt-in `check_uuid_dedupe:` flag asserts the advisory retried-batch uuid-dedupe recommendation.
- `--continue` with a store that implements `list_session_summaries` skips sidechain candidates via the summary sidecar instead of downloading every candidate's full transcript.

### Changed
- `RUN_INTEGRATION=1` now actually runs the real-CLI integration suite (the old tautological placeholder suite is gone; `RUN_REAL_INTEGRATION` remains as an alias). The real suite still self-skips without a `claude` CLI or `ANTHROPIC_API_KEY`.
- Packaged docs/README now link to examples and repo files via absolute GitHub URLs — the relative links were dead in installed gems and on rubydoc.info (examples/ and assets/ are not packaged).

## [0.21.0] - 2026-07-03

Design-decision fix batch (Batch C) from the 2026-07-03 full-codebase audit (`AUDIT-2026-07-03.md`, PR #43), plus three teardown-race hardenings from its adversarial review. Minor (not patch) because three fixes change observable behavior for previously-broken flows: a missing settings file with sandbox no longer raises, a raising initial prompt stream no longer notifies observers, and teardown can now preserve (instead of delete) the materialized resume dir.

### Fixed
- `Query#close` (and therefore `Client#disconnect`) is now safe to call from any thread. Calling it from a FiberBoundary worker — e.g. a tool handler, hook, or permission callback ending the session — crashed with `NoMethodError` (nil `Fiber.scheduler`) and left the read/child tasks running, hanging the enclosing reactor. A transient reactor-side watcher now serves closes marshaled from foreign threads with identical semantics; once the reactor is gone, close falls back to a direct (fiber-dead-safe) teardown. `close` is also idempotent now — concurrent or repeated closes no longer re-run teardown against half-torn-down state.
- Eager-mode mirror failures during the last flush of a stream are reported before the `'end'` sentinel: the `MirrorErrorMessage` for an in-flight dropped batch could previously be enqueued after `'end'` and never delivered, violating the documented "failures surface as MirrorErrorMessage" guarantee.
- Disk session listings no longer report tool-argument text as the session summary/title: the head/tail byte-scans for `summary`/`customTitle`/`aiTitle`/`lastPrompt` now verify each match against the top level of its containing JSONL line (the same keys the SessionStore fold reads), so keys nested inside tool_use inputs (subagent/teammate tool arguments) are ignored. Lines truncated at the 64KB window edge keep the raw-scan value.
- Resume-from-store teardown no longer deletes the only copy of turns the mirror failed to persist: when the batcher dropped batches (tracked via `TranscriptMirrorBatcher#batches_dropped?` / `Query#mirror_batches_dropped?`, including drains cancelled mid-flight), the materialized temp `CLAUDE_CONFIG_DIR` is preserved — credential copies scrubbed, transcripts kept, warning with the path — instead of removed.
- A missing settings file with `sandbox` set now warns and continues with sandbox-only settings (Python parity) instead of raising `CLIConnectionError`.
- `Client#connect` no longer fires observer `on_error` for a raising initial Enumerator prompt: input-stream errors are swallowed-with-warn (documented `Observer#on_error` contract, `query()` and Python parity). Notifying them also marked still-live OTel traces as failed.
- Postgres reference adapter (`examples/session_stores/postgres_session_store.rb`): all DB round-trips now serialize through an internal mutex — mirror appends run on fresh worker threads and can overlap after a send-timeout abandon, which pg's single-connection thread rules forbid. The "a single PG::Connection suffices" concurrency guidance was wrong and has been rewritten.

## [0.20.0] - 2026-07-03

Behavioral fix batch (Batch B) from the 2026-07-03 full-codebase audit (`AUDIT-2026-07-03.md`, PR #42). Every fix aligns code with a documented contract or Python SDK behavior and changes behavior only for inputs that previously produced wrong results, hangs, or crashes. Minor (not patch) because two fixes raise where the SDK previously reported success: a signal-killed CLI now raises `ProcessError`, and assistant messages without `message.model` now raise `MessageParseError`.

### Fixed
- A CLI process killed by a signal (OOM-kill SIGKILL, SIGSEGV, ...) now raises `ProcessError` ("Command terminated by signal N", `exit_code: -N` — Python returncode parity) instead of reporting a **truncated** response as clean end-of-stream success.
- A trailing title-clearing entry (`{"customTitle":""}`, or whitespace-only) no longer silently drops the whole session from `list_sessions`/`get_session_info` disk listings: blank values now fall through the summary/title fallback chains exactly like the SessionStore path and Python (`or` semantics).
- `continue_conversation: true` with a SessionStore adapter that reports mtimes as Strings (the natural SQL-timestamp-through-JSON shape) no longer silently resumes the **oldest** session: String mtimes (ISO-8601 or numeric) are coerced and ordered chronologically, and mixed Integer/String lists no longer raise a bare `ArgumentError`. The conformance suite already pins the epoch-ms Numeric contract.
- One malformed line in a transcript head (non-Hash entry, string `message`, non-string `text`) no longer drops the whole session from disk listings — the guards ported from Python skip just the bad line. An assistant line whose tool_use input embeds `"type":"user"` can no longer donate its text as the session's first prompt.
- A user message block that leaks `StopIteration` (e.g. `.next` on an exhausted Enumerator) no longer silently ends message reception mid-turn — previously the `ResultMessage` was dropped and `receive_response`/`query()` returned as if the turn had completed; the error now propagates.
- Top-level `query()` now validates the prompt like `Client#query` and fails fast at the call site: a bare Hash (which would stream `[key, value]` garbage to the CLI) and non-String/non-`#each` prompts (which hung forever) raise `ArgumentError`.
- One-shot `query()` now sends `exclude_dynamic_sections` from a preset system prompt in the initialize request (it was silently dropped; `Client` and Python both send it).
- `ClaudeAgentOptions#dup_with` now deep-duplicates nested containers: mutating a derived variant (`variant.allowed_tools << 'Bash'`) no longer bleeds into the base options and every sibling variant — including the security-relevant allow/deny lists. Leaf objects (callbacks, SDK MCP server instances, store adapters) keep identity, mirroring `Configuration#default_options`. Container deep-dup (both here and in `Configuration#default_options` merging) now also preserves Hash/Array subclasses — a Rails `HashWithIndifferentAccess` config no longer flattens into a plain Hash whose symbol lookups silently return nil.
- Sandbox gating in command building now matches Python's `sandbox is not None`: `sandbox: true` (the boolean toggle) no longer crashes with `NoMethodError: undefined method 'empty?' for true`, and an explicit `sandbox: false` / `{}` is forwarded to the CLI instead of silently dropped — so `sandbox: false` can actually override a sandbox enabled in the settings JSON.
- `output_format: { type: 'json_schema' }` with a nil/absent schema no longer emits `--json-schema null` (which the CLI rejects at spawn); the flag is skipped, matching Python's `schema is not None` guard.
- A non-Hash `message` field in a user/assistant CLI message now raises the documented `MessageParseError` instead of a raw `TypeError`.
- Assistant messages missing `message.model` now raise `MessageParseError` (Python parity) instead of silently constructing `AssistantMessage(model: nil)`.

## [0.19.1] - 2026-07-03

Zero-risk fix batch from the 2026-07-03 full-codebase audit (`AUDIT-2026-07-03.md`, PR #41).

### Added
- `lib/claude-agent-sdk.rb` require shim: `Bundler.require` now loads the SDK in default Rails/Bundler apps. Previously Bundler tried `claude-agent-sdk` and `claude/agent/sdk`, silently swallowed both LoadErrors, and left `ClaudeAgentSDK` undefined until a confusing `NameError` at first use.

### Fixed
- `require 'claude_agent_sdk/instrumentation'` now loads the SDK core, so the documented Rails observability initializer (and `OTelObserver`'s own `@example`) works as the only require.
- Typed `McpStdioServerConfig` / `McpSSEServerConfig` / `McpHttpServerConfig` / `McpSdkServerConfig` objects passed directly in `mcp_servers` (without `.to_h`) now serialize to their wire hash instead of a `#<...>` string the CLI cannot parse — and `McpSdkServerConfig` instances now actually register their in-process server, so its tools connect.
- `create_tool` with a Symbol name produced a tool that was advertised in `tools/list` but failed every invocation with 'Tool not found'; names are now coerced to String.
- One stdout line carrying invalid UTF-8 bytes no longer aborts the whole message stream (which dropped all buffered valid frames, including a trailing `result`); the bad line is scrubbed, matching the version-probe path.
- `fork_session` no longer hangs forever on a transcript with a `parentUuid` cycle among progress entries.
- `fork_session` / `delete_session` no longer stop at a 0-byte transcript stub: they fall through to the worktree project dir holding the real transcript, mirroring the read path. A session whose *only* copy is a 0-byte stub now raises `Errno::ENOENT`, consistent with the read paths that already hide it.
- Long-lived `Client`s using SDK MCP servers no longer leak one finished internal task per synchronously-handled control request (MCP metadata requests, unsupported subtypes).
- An observer implementing none of the observer interface — most commonly a Class passed instead of an instance (`observers: [OTelObserver]`) — is now warned about and skipped instead of producing silent zero instrumentation.

### Changed
- The gem packages git-tracked files only (previously a working-tree glob, which shipped stray untracked files under `lib/`/`docs/` in locally built gems). `gem build` from a tree with tracked-but-deleted files now fails fast instead of silently packaging whatever was on disk.

## [0.19.0] - 2026-06-29

### Added
- `TaskUpdatedMessage` — typed `system`/`task_updated` lifecycle events (Python SDK 0.2.101 / #1016 parity). A background task's terminal state can arrive *only* as a `task_updated` patch with no accompanying `TaskNotificationMessage` (e.g. a `TaskStop`-killed task reports `status: 'killed'` here), so consumers tracking active task IDs no longer hang waiting for a notification that never comes. `status` is derived from `patch['status']` (parsed defensively — a non-Hash/absent patch falls back to `{}`, `task_id` defaults to `''` so it is never nil, and parsing never raises). New `TASK_UPDATED_STATUSES` and `TERMINAL_TASK_STATUSES` constants; the latter spans both lifecycle vocabularies (`task_notification` reports `stopped`, `task_updated` reports the raw `killed`) so a terminal status from *either* message clears active-task tracking.

### Fixed
- Malformed CLI message content now raises a descriptive `MessageParseError` instead of an opaque `TypeError`/`NoMethodError` (Python SDK #1058 parity): a non-Hash content block (e.g. a bare String) and an assistant `content` that is not an Array are both caught with a clear message carrying the full payload, rather than crashing deep inside block parsing on `block[:type]`.

## [0.18.0] - 2026-06-12

### Added
- `query(transport:)` — inject a pre-constructed custom transport instance (Python parity): CLI discovery, version check, and resume materialization are skipped; the SDK calls `#connect`/`#close` on the instance (including after a failed connect — a documented safety deviation from Python).
- `Client#query` now accepts an Enumerable of message Hashes / JSONL Strings in addition to a String (Python parity): items stream inline on the caller, `session_id` is stamped onto Hashes that lack one (explicit values, even nil, preserved), and non-Hash/String items raise instead of being silently serialized. Note: JSONL String items pass through verbatim and carry their own `session_id` — generate them with the matching `session_id:` argument (`Streaming.user_message` defaults to `'default'`).
- `Client.open(prompt = nil, options:, ...) { |client| }` — block-scoped lifecycle mirroring Python's `async with ClaudeSDKClient()`: connects, yields, always disconnects; works standalone (creates a reactor via `Sync`) and inside `Async` blocks; returns the block's value.
- `ClaudeAgentOptions#user` is now applied — the CLI subprocess is spawned as that OS user via spawn's `:uid` (String username or Integer uid, Unix; previously accepted but silently ignored). On unsupported platforms the failure is loud (`CLIConnectionError`), not silent.
- `HookMatcher#timeout` is now sent to the CLI in the initialize request (per matcher, seconds — Python wire parity); the SDK-side enforcement remains as defense-in-depth.
- `ClaudeAgentSDK.list_subagents` / `ClaudeAgentSDK.get_subagent_messages` — local-disk subagent transcript readers (disk counterparts to the existing `*_from_store` variants; Python SDK parity, upstream #825). Scans `<projectDir>/<sessionId>/subagents/**/agent-<id>.jsonl` including nested `workflows/<runId>/` paths. Note: `limit: 0` returns `[]` per the Ruby read-API family convention (Python returns all).
- W3C trace-context propagation to the CLI subprocess (Python SDK #821 parity): when `opentelemetry` is loaded and a span is active at connect, `TRACEPARENT`/`TRACESTATE` (and any other propagator carrier keys such as `BAGGAGE`, uppercased) are injected into the CLI env so CLI-side OTel spans join the caller's distributed trace. Explicit `ClaudeAgentOptions#env` keys win; stale inherited W3C env is scrubbed only when an active span replaces it. No new dependency — no-op without the opentelemetry gem.
- `CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK` env var skips the CLI version check (any non-empty value, Python parity), and the check itself now has a 2-second deadline — a hung `claude -v` (NFS-mounted binary, wedged Node bootstrap) no longer hangs `connect` forever. The unsupported-version warning now includes the CLI path.
- `ClaudeAgentOptions#skills` (Python parity): enable skills for the main session with `'all'` or an Array of names. Injects `Skill`/`Skill(name)` into `--allowedTools`, defaults `setting_sources` to `['user', 'project']` when unset, and sends explicit lists via the `initialize` control request so the CLI filters which skills load. `[]` hides all skills; this is a context filter, not a sandbox.
- OTel spans now report prompt-cache usage: `gen_ai.usage.cache_creation_input_tokens` / `gen_ai.usage.cache_read_input_tokens` on generation and session spans, plus OpenInference `llm.token_count.prompt_details.cache_read`/`.cache_write` on the session span. Anthropic's `input_tokens` excludes cached tokens, so heavily cached sessions previously under-reported prompt volume by orders of magnitude. Strictly additive — existing keys unchanged.
- `on_user_prompt` observers now fire for Enumerator/streaming-input prompts (once per `type: 'user'` message with extractable text). OTel traces for streaming sessions now get an `input.value` for the first trace; later turns' capture depends on prompt timing relative to each init (`OTelObserver` keeps one prompt per trace).

### Fixed
- `SubprocessCLITransport#end_input` now takes the stdin mutex like write/close (its lock-free close could race a concurrent writer into a misleading "undefined method ... for nil" error that also poisoned `@exit_error`).
- `CLAUDE_CODE_ENTRYPOINT` now defaults to `sdk-rb` regardless of inherited process env (an ambient `cli` value from running inside a Claude Code terminal previously won via `||=`, mis-attributing telemetry); `options.env` can still override it. `CLAUDE_AGENT_SDK_VERSION` is now always SDK-set, never overridable (Python merge-order parity).
- Unknown hook events now arrive as `UnknownHookInput` carrying the wire `hook_event_name` and the complete raw payload (previously all event-specific fields were dropped and the name was nil; Python passes the raw dict through, losing nothing).
- Oversized CLI stdout lines no longer allocate unbounded memory: the read loop's 1MB buffer cap previously fired only AFTER `each_line` had read the whole line into memory; reads are now chunk-bounded at `max_buffer_size + 1` bytes (Python's TextReceiveStream reads ≤64KB chunks — same incremental-cap semantics). The same bound applies to the stderr drain loops.
- `advisor_tool_result` content blocks now parse into `ServerToolResultBlock` (they previously fell through to `UnknownBlock`); the `server_tool_result` wire type was dead code — no CLI version emits it — and now takes the forward-compat `UnknownBlock` path.
- README's Client quick-start example used `receive_messages` with no termination and hung forever when pasted; it now uses `receive_response`.
- `Configuration#default_options` containers are now deep-duplicated when constructing `ClaudeAgentOptions`: `options.allowed_tools << 'Bash'` in one session no longer mutates the global default (cross-session permission widening) and nested default hashes/arrays no longer leak mutations. Leaf objects (callbacks, observer factories, SDK MCP server instances) keep identity.
- Hash-form `thinking` config (`{ type: 'adaptive'|'enabled'|'disabled', budget_tokens:, display: }`) is now serialized to the CLI; it was previously dropped silently and also suppressed the `max_thinking_tokens` fallback. Invalid shapes raise a clear `ArgumentError`.
- Control-protocol client methods (`interrupt`, `set_model`, …) can now be called from inside hook/`can_use_tool`/SDK-MCP callbacks (Python reentrancy parity): the call previously wrote the request to the CLI and then crashed with an opaque `RuntimeError: No async task available!`, silently dropping the response. Worker-thread callers now wait on a level-triggered queue with the same timeout semantics.
- Closed a lost-wakeup race in control-request waiting: `Async::Condition` is edge-triggered, so a `control_response` arriving while the sender was still suspended in a transport write was dropped and the caller waited the full 1200s timeout (reachable with custom transports whose `#write` suspends after delivery, and via the read-loop error broadcast). Senders now check the result slot before and between waits (anyio.Event level-trigger semantics, like Python).
- `SdkMcpServer#handle_json` now actually serves resources and prompts: `resources/list` crashed inside the mcp gem (`Class#to_h`), `resources/read` silently returned `{contents: []}` for every URI (the read path referenced `MCP::ResourceContents`, a constant that has never existed in any mcp gem version), `prompts/list` mangled names (`codeReview` → `code_review`) and dropped descriptions/arguments, and `prompts/get` could not find any prompt. Resources are now served as `MCP::Resource` instances with the gem's registered read handler; prompts via `MCP::Prompt.define`. Both delegate to the SDK's own readers, preserving the FiberBoundary hop and result validation.
- Pre-built JSON Schemas with symbol values (`type: :object`) are no longer silently mangled into garbage (schema meta-keys leaked as parameters, every valid `tools/call` was then rejected with "Missing required arguments: type, properties, required"). Schema normalization is now a single source of truth; `additionalProperties`/`enum`/`description` survive, and a malformed pre-built schema raises a clear error lazily instead of producing silent garbage.
- `list_sessions`, `get_session_info`, and `get_session_messages` no longer raise `Errno::ENOENT` for a `directory:` that does not exist — they return `[]`/`nil`, matching the Python SDK (a fresh checkout or a deleted project directory previously crashed; sessions recorded for a since-deleted directory are now found again).
- `get_session_messages` and `import_session_to_store` no longer stop at a 0-byte transcript stub: the session-file search skips empty files and continues to worktree project dirs, matching Python's `st_size > 0` resolver (a stub in the canonical project dir previously hid the real worktree transcript).
- An empty `CLAUDE_CONFIG_DIR` is now treated as unset (falling back to `~/.claude`, NFC-normalized) across all session read/mutation paths and SessionStore mirroring, matching the Node CLI and Python SDK — previously the projects dir resolved to `/projects` and transcript mirroring was silently disabled.
- `list_sessions` / `get_session_info` no longer return `created_at: nil` when a transcript's first JSONL record is a metadata-only entry (e.g. `permission-mode`) with no `timestamp` field — the whole 64 KiB head window is now scanned for the first timestamp (Python #907 parity). The store-backed readers already folded every entry, so the disk and store paths now agree on `created_at`.
- `Observer#on_error` is now actually invoked — once per error surfacing from `query()` or `Client#query`/`#receive_messages`/`#receive_response`/`#connect`, before `on_close` where both fire. Crashed sessions now produce OTel traces with error status and a recorded exception.
- `OTelObserver` no longer mislabels traces when one instance is reused: the buffered prompt/output are reset at every trace boundary (previously every trace after the first showed the first query's prompt as its `input.value`, and a nil-result trace could leak the previous query's output).
- `OTelObserver` no longer leaks unfinished (never-exported) spans: a new `InitMessage` without an intervening `ResultMessage` finishes the superseded root span, and tool spans still pending at a `ResultMessage` or superseded init are finished at that boundary instead of waiting for `on_close`.
- OTel tool spans now serialize Array tool-result content as JSON with `output.mime_type: application/json` (previously Ruby `inspect` format); String results gain `output.mime_type: text/plain`; nil results omit `output.value` (previously empty string).
- `break` inside the user block of `query()`, `Client#receive_messages` and `Client#receive_response` now stops iteration (returning the break value) instead of raising `LocalJumpError` — the FiberBoundary thread hop translates the break back to the calling fiber (new internal `FiberBoundary.invoke_iteration`).
- CLI stdout/stderr are now always decoded as UTF-8: under `LANG=C`/`LC_ALL=C` (minimal Docker images, systemd, CI) the pipes inherited US-ASCII and the first non-ASCII byte from the CLI killed the read loop with `Encoding::CompatibilityError`. Mirrors the Python SDK's UTF-8 `TextReceiveStream`.
- The unsupported-CLI-version warning now actually fires: `Array#<` does not exist, so the version comparison raised `NoMethodError` into the version check's blanket rescue and the warning had never been emitted; the `-v` output is also UTF-8-scrubbed so a stray invalid byte cannot suppress it.
- `query()` can no longer hang forever when the CLI dies while a streaming-input Enumerator is blocked: the input stream task is tracked on the `Query` (new `Query#spawn_task`, mirroring the Python SDK's `_child_tasks`) and stopped by `close`, so the real error now propagates to the caller instead of decaying to an async console warning.
- A CLI crash now always unblocks in-flight control requests (`interrupt`, `set_model`, …) immediately instead of leaving them to the 1200s control-request timeout, and a real crash in a multi-turn session is reported to consumers instead of being silently swallowed after the first result.
- Hooks and SDK MCP servers no longer silently stop working when a one-shot `query()`'s first turn runs past 60 seconds: stdin stays open (without timeout) until the first result, mirroring Python SDK commit c3d96cb. String-prompt queries also now stream messages to the block while that wait is pending instead of deferring delivery.

### Changed
- `Client#connect(enumerable)` now streams the initial prompt in the **background** (Python parity): connect returns immediately instead of blocking until the stream is exhausted (interactive streams that wait for a response before yielding no longer deadlock), Hash messages are serialized as JSON (previously Ruby `inspect` via `to_s` — never valid wire format), stdin closes when the stream is exhausted, and stream errors fire `Observer#on_error` and are logged instead of raising out of `connect`.
- SDK MCP `tools/call` now routes through the official `MCP::Server`: arguments are JSON-Schema-validated (draft4) against the tool's `inputSchema` **before** the handler runs (Python parity — its mcp lowlevel server does the same), and validation failures return in-band `isError` results ("Missing required arguments: …"/"Invalid arguments: …") without invoking the handler. The `mcp` dependency floor rises to `>= 0.6, < 1` (0.4 turned these into protocol errors; 0.5 serializes empty icons arrays into list responses). The SDK normalizes tools/call error envelopes itself, so the gem's per-version error-behavior swings (0.7.1+/0.18 raise protocol errors again) never leak through. Error texts on this path now come from the gem (e.g. "Tool not found: X", "Internal error calling tool X: msg"). Validation can be disabled globally via `MCP.configure { |c| c.validate_tool_call_arguments = false }`. Schemas the draft4 metaschema rejects (numeric `exclusiveMinimum`, `$ref` — valid modern JSON Schema that Python accepts) fall back to validation-disabled with a one-time warning instead of bricking the tool.
- SDK MCP tool failures are now reported **in-band** (`isError: true` with the error text in `content`) instead of as JSON-RPC `-32603` protocol errors — matching the MCP spec, the Python SDK, and the official mcp gem. The model can now read the error text and self-correct. This covers handler exceptions, unknown tools, and malformed handler results; `SdkMcpServer#call_tool` no longer raises for these cases.
- `SdkMcpServer#call_tool`/`#read_resource`/`#get_prompt` now accept string-keyed handler results (Python handlers return string-keyed dicts naturally); previously they rejected them with an error the model saw as a protocol failure.
- When an explicit `directory:` is given, `get_session_messages` and `import_session_to_store` no longer fall back to scanning all project directories: a session that only exists in an unrelated project now returns `[]` / raises `Errno::ENOENT` instead of silently returning/importing another project's data under the wrong project key (Python parity; `directory: nil` still searches all projects). A 0-byte-stub-only session now raises `Errno::ENOENT` from import instead of silently importing zero entries.
- `can_use_tool` callbacks now receive fully populated `ToolPermissionContext`s: the CLI display fields (`title`, `display_name`, `description`, `blocked_path`, `decision_reason`) are forwarded (previously always nil), and `suggestions` are typed `PermissionUpdate` objects instead of raw wire hashes (Python #920 parity) — `PermissionUpdate.new` also hydrates wire-format rule hashes into `PermissionRuleValue`. Code treating suggestion entries as plain Hashes (`dig`, `fetch`) must use the typed accessors; echoing `context.suggestions` into `updated_permissions` keeps working.
- A `ProcessError` that directly follows a result with `is_error: true` (the CLI exits non-zero on purpose, e.g. structured-output errors) is now raised with the structured error text the CLI reported (`Claude Code returned an error result: …`, preserving `exit_code`/`stderr`) instead of ending the stream silently — matching the Python SDK.
- `CLAUDE_CODE_STREAM_CLOSE_TIMEOUT` is now a no-op (the internal `Query::STREAM_CLOSE_TIMEOUT_*` constants were removed with the stdin-close timeout).

### Removed
- **Breaking**: `ClaudeAgentOptions#append_allowed_tools`. It emitted `--append-allowed-tools`, which no Claude Code CLI version accepts (`error: unknown option`), so any use failed at connect. The option never existed in the Python SDK (mis-port in v0.4.0). Use `allowed_tools` instead — the CLI's `--allowedTools` already appends to settings-derived permission rules. Passing `append_allowed_tools:` now raises `ArgumentError` at construction.

## [0.17.0] - 2026-06-10

### Added
- **Pluggable `SessionStore` adapter subsystem** — mirror Claude Code session transcripts to external storage (S3/Redis/Postgres/…) and resume from it, at parity with the Python SDK (#837 and follow-ups) and TypeScript SDK. The subprocess still writes to local disk; the adapter receives a secondary copy.
  - **`SessionStore`** base class (6-method contract: `append`/`load` required; `list_sessions`/`list_session_summaries`/`delete`/`list_subkeys` optional, probed via `SessionStore.implements?` so duck-typed adapters need not subclass) and **`InMemorySessionStore`** reference implementation. All keys/entries cross the boundary as Hashes with **string keys** (JSON-round-trip safe for JSONB/Redis backends).
  - **`ClaudeAgentSDK::Testing.run_session_store_conformance(make_store)`** — a 15-contract behavioral test suite for adapter authors (shipped in the gem, framework-agnostic; raises `ConformanceError` on violation).
  - **Live mirroring** (on both `ClaudeAgentSDK.query` and `ClaudeAgentSDK::Client`): setting `ClaudeAgentOptions#session_store` emits `--session-mirror`; a `TranscriptMirrorBatcher` coalesces the CLI's `transcript_mirror` frames per file and flushes to `SessionStore#append` on each `result` (or 500-entry / 1 MiB overflow). `session_store_flush: "eager"` flushes after every frame. Append ordering is preserved across concurrent flushes (fiber-aware `Async::Semaphore`); the user store call runs on a `FiberBoundary` thread bounded by a fixed 60 s send timeout (`TranscriptMirrorBatcher::SEND_TIMEOUT_SECONDS`; `load_timeout_ms` bounds resume-materialization store calls instead); failures retry (3 attempts, 0.2/0.8 s backoff) then surface as a **`MirrorErrorMessage`** on the message stream. A failing store never disrupts the session (the local transcript is already durable).
  - **Resume from store** (both entry points): pairing `session_store` with `resume`/`continue_conversation` materializes the session (and its subagent transcripts) from the store into a temp `CLAUDE_CONFIG_DIR` before spawn, repoints the subprocess at it, and cleans it up after the subprocess exits (on disconnect, one-shot teardown, **and** reactor cancellation). Store-supplied subagent subpaths are validated against path traversal; copied `.credentials.json` has its single-use `refreshToken` redacted; macOS Keychain credentials are bridged when needed.
  - **Store-backed reads** (counterparts to the local readers): `ClaudeAgentSDK.list_sessions_from_store` (summary fast-path + gap-fill + pagination; a single failing row degrades to an empty summary rather than aborting the listing), `.get_session_info_from_store`, `.get_session_messages_from_store`, `.list_subagents_from_store`, `.get_subagent_messages_from_store`.
  - **Store-backed mutations** (counterparts to the local mutators): `ClaudeAgentSDK.rename_session_via_store`, `.tag_session_via_store`, `.delete_session_via_store` (a no-op on WORM/append-only stores that don't implement `#delete`), and `.fork_session_via_store` (the UUID-remap fork transform run directly over the loaded entries — no JSONL round-trip; the fallback title is derived from the source's `customTitle`/`aiTitle`/first prompt).
  - **Reference adapters** under `examples/session_stores/` (S3, Redis, Postgres) — copy-in implementations, each validated against `run_session_store_conformance`. Backend client gems live in the optional `:examples` Bundler group so a default install stays dependency-free.
  - **`ClaudeAgentSDK.import_session_to_store`** — replay a local on-disk session (and subagents) into a store for migration / mirror-gap backfill.
  - **`ClaudeAgentSDK.project_key_for_directory`** and **`.fold_session_summary`** helpers; `ClaudeAgentOptions` gains `session_store`, `session_store_flush` (`"batched"`/`"eager"`), and `load_timeout_ms`. `SessionStore` + `enable_file_checkpointing`, or `continue_conversation` without `list_sessions`, are rejected at connect with a clear error.

### Changed
- `Client#connect` now fully tears the client down (subprocess reaped, temp resume dir removed) when any part of connect fails — previously a failure while sending the initial prompt could leave a half-connected client behind. Matches the Python/TypeScript SDKs.
- A negative `limit:` now returns `[]` consistently across every session reader (`list_sessions`, `get_session_messages`, and all store-backed counterparts) instead of raising `ArgumentError` from an internal `Array#first` on some paths.

### Fixed
- `fork_session` / `fork_session_via_store` now fall back to the documented `"Forked session (fork)"` title for sessions with no title and no extractable first prompt (previously wrote a literal `" (fork)"`).

## [0.16.10] - 2026-06-04

### Added
- `ClaudeAgentOptions#strict_mcp_config` — forwarded as `--strict-mcp-config`. When `true`, the CLI uses **only** the MCP servers passed via `mcp_servers`, ignoring project `.mcp.json`, user/global settings, and plugin-provided servers, for a fully deterministic server set. Defaults to `false`. (Parity with [Python SDK #915](https://github.com/anthropics/claude-agent-sdk-python/pull/915))
- `ClaudeAgentOptions#include_hook_events` — forwarded as `--include-hook-events`. When `true`, the CLI emits hook lifecycle events (PreToolUse, PostToolUse, Stop, etc.) into the message stream. The parser already maps these to `HookStartedMessage` / `HookProgressMessage` / `HookResponseMessage` (the CLI simply never emitted them without this flag). Defaults to `false`. (Parity with [Python SDK #917](https://github.com/anthropics/claude-agent-sdk-python/pull/917))
- `SandboxNetworkConfig#denied_domains` (`deniedDomains`) and `#allow_mach_lookup` (`allowMachLookup`) — completes the sandbox network allowlist field set. `denied_domains` blocks domains even when matched by `allowed_domains`; `allow_mach_lookup` is a macOS-only list of XPC/Mach service names to allow (supports a trailing wildcard). Completes [Python SDK #893](https://github.com/anthropics/claude-agent-sdk-python/pull/893) — `denied_domains` and `allow_mach_lookup` were the last two fields the Ruby port had not yet landed.
- **Orphaned-subprocess cleanup**: `SubprocessCLITransport` now tracks live CLI subprocesses in a class-level, mutex-guarded `Set` and registers an `at_exit` handler that sends `SIGTERM` to any still running when the parent Ruby process exits. This prevents leaked `claude` processes when callers crash or exit before reaching `#close`. The handler skips already-exited processes (`Process::Waiter#alive?`) and swallows errors so it never interrupts interpreter shutdown. (Parity with [Python SDK #916](https://github.com/anthropics/claude-agent-sdk-python/pull/916))

## [0.16.9] - 2026-05-25

### Fixed
- `Types.normalize_name` no longer mutates the frozen string returned by `Symbol#to_s` under Ruby 3.4+. The previous `name.dup.to_s` order dup'd the Symbol (a no-op) and then took `.to_s`, which Ruby 3.4 stages to return a frozen string in 4.0 — emitting a deprecation warning on every `gsub!`/`tr!`/`downcase!`. Swapped to `name.to_s.dup`. (#35, @chagel)

## [0.16.8] - 2026-05-15

### Added
- `ServerToolUseBlock` + `ServerToolResultBlock` content blocks for the CLI's built-in server-side tools (web_search, advisor, code_execution). The message parser now recognises `server_tool_use` / `server_tool_result` content types.
- `DeferredToolUse` class and `ResultMessage#deferred_tool_use` field — populated when a PreToolUse hook returns `permissionDecision: "defer"` so the session can be resumed later to execute the deferred call.
- `ResultMessage#api_error_status` — integer HTTP status (429, 500, 529) on the `api_error` subtype, from CLI 2.1.110+.
- `ToolPermissionContext` gains five pre-formatted display fields (`title`, `display_name`, `description`, `blocked_path`, `decision_reason`) populated by CLI 2.1.110+ so `can_use_tool` callbacks can render the same prompt UI the CLI would.
- `PostToolUseHookSpecificOutput#updated_tool_output` — unified tool-output replacement that works for any tool, MCP or built-in (the legacy `updated_mcp_tool_output` field remains for backwards compatibility).

### Changed
- README restructured: the 1857-line single-file reference was slimmed to ~285 lines covering intro, comparison table, install, Quick Start, and minimal `query()`/`Client`/MCP/Hooks examples. Detailed sections moved into a new `docs/` directory with nine topic subpages (`client.md`, `mcp-servers.md`, `hooks-and-permissions.md`, `configuration.md`, `sessions.md`, `observability.md`, `rails.md`, `types.md`, `errors.md`). The README now links to each subpage from a single "Advanced Topics" table.
- `claude-agent-sdk.gemspec` now ships `docs/**/*` so `gem install` includes the topic subpages — the Agentic Coding Skill (and humans browsing `<gem_path>` after `bundle show claude-agent-sdk`) can read the full documentation set without a repo clone.
- `Query#start` now raises `CLIConnectionError` if invoked outside an `Async{}` block. The previous implementation appeared to support synchronous callers but silently hung forever because the outer `Async{}` root task it spawned waited for `read_messages` to finish, which never happens for a live Client. All documented usage (`query()` and the `Client#connect` pattern) already wraps in `Async{}` so this only surfaces a previously hidden failure mode.
- `CommandBuilder` raises `ArgumentError` synchronously when both `continue_conversation` and `resume` are set, instead of producing an opaque non-zero CLI exit at runtime.
- `sdk_mcp_server`'s `read_resource`, `get_prompt`, and the dynamic `Resource#read` / `Prompt#get` callbacks now hop through `FiberBoundary.invoke` (`call_tool` already did). User reader/generator blocks that touch `Thread.current`-keyed libraries (ActiveRecord, pg) no longer see the async-gem fiber scheduler.

### Fixed
- **Transport `@stdin` race**: `write`/`close` are now serialised by a mutex. User callbacks running on `FiberBoundary` threads can no longer race `close()` and hit `NoMethodError` on a nilled `@stdin`. The mutex only guards the reference snapshot — the blocking IO call happens outside the lock so `close` is never blocked by a full pipe buffer.
- **Transport stdout poisoning**: stdout lines that do not start with `{` are skipped when `json_buffer` is empty. Previously the CLI's occasional debug prefixes (e.g. `[SandboxDebug]`) accumulated in the buffer until the 1 MB cap raised `CLIJSONDecodeError` and killed the session. Matches the Python SDK's guard.
- **Transport stderr resilience**: each `stderr` callback invocation is wrapped in `rescue StandardError`, so a transiently failing user logger no longer terminates the read loop and silently stops stderr capture for the lifetime of the process. Matches Python SDK v0.2.82 (PR #932).
- **Transport process reaping**: `@process.value` is now `&.`-safe and rescues `Errno::ECHILD`, so a concurrent `close()` that already reaped the subprocess cannot crash the message loop.
- **Query read-loop cancellation**: `@task` now holds the actual `read_messages` child task. The previous outer-`Async`-wrapper assignment completed almost immediately after spawning, so `close`'s `@task.stop` never reached the actual read fiber and the loop only ended when the transport raised.
- **Query control-request leak**: `send_control_request` now cleans `@pending_control_*` entries in an `ensure` block and uses `Async::Task.current.with_timeout` instead of a nested `Async do ... end.wait`. An `Async::Stop` propagating through `.wait`, or a late `control_response` arriving after timeout, can no longer leak pending state.
- **Session forks dropped metadata**: `parse_fork_transcript` now filters transcript body by `TRANSCRIPT_TYPES` (`user`/`assistant`/`attachment`/`system`/`progress`). `custom-title`, `tag`, `aiTitle`, `permission-mode` and other metadata entries with the old sessionId no longer bleed into the forked transcript.
- **Session forks lost content-replacement history**: `content-replacement` entries are now accumulated across compaction rounds (concatenated) rather than overwritten, gated on matching `sessionId`. Forks emit `content-replacement` and `custom-title` entries with `uuid`+`timestamp` so a fork-of-a-fork can re-ingest them.
- **`delete_session` orphans**: also `FileUtils.rm_rf`s the sibling `<session-id>/` subagent transcript directory. Without this the CLI would later pick up stale subagent state if the same session ID happened to be reused.
- **`detect_worktrees` hang on stale git lock**: enforces a 5-second hard cap with `SIGKILL` fallback. `Timeout.timeout` is unsafe under the Async fiber scheduler (it raises across threads via `Thread#raise`), so the new implementation drains stdout/stderr on side threads and kills the child process if the deadline passes. A pipe-buffer-overrun edge case (enough worktrees to overrun the 64 KB pipe buffer) that previously silently lost every worktree path is also fixed.

## [0.16.7] - 2026-05-15

### Added
- `ClaudeAgentOptions#resume_session_at` — forwarded as `--resume-session-at <message-uuid>` to the CLI. When resuming a session, the conversation is truncated to include only messages up to and including the assistant message with the given UUID, enabling history rewriting / branched continuations from a specific turn. Raises `ArgumentError` from `CommandBuilder` if set without `resume` (matches the CLI's own validation but surfaces it synchronously in the caller's stack).
- `examples/e2b_transport_example.rb` — working ~320-line custom transport that runs the Claude Code CLI inside an E2B Firecracker microVM via the `e2b` gem. Reuses `CommandBuilder` for argv parity with `SubprocessCLITransport` and demonstrates the 6-method `Transport` interface against a remote backend. README's Custom Transport section now includes an interface table, data-flow diagram, code sketch, and production-hardening checklist that link to the example.

## [0.16.6] - 2026-04-29

### Added
- Type classes now accept hash construction with mixed key shapes — symbols or strings, snake_case or camelCase — and support bracket access (`obj[:field]`, `obj['field']`). `UserMessage.new({"sessionId" => "abc"})` works the same as `UserMessage.new(session_id: "abc")`. `Type.from_hash(nil)` and `Type.wrap(nil)` are nil-safe.
- `ClaudeAgentOptions.new(nil)` is accepted and yields an options object populated with configured defaults.

### Changed
- Discriminator fields on type classes (`type` on `SystemPromptFile`/`McpStdioServerConfig`/etc., `behavior` on `PermissionResultAllow`/`Deny`, `hook_event_name` on every hook input/output) are now `attr_reader`-only, set authoritatively in `initialize`. They cannot be overwritten externally.
- `ClaudeAgentOptions` continues to raise `ArgumentError` on unknown keys (constructor, `dup_with`, and `[]=`); other type subclasses silently drop unknown keys for forward-compatibility with newer CLI output.

### Internal
- Unified ~50 type classes (messages, hook inputs/outputs, MCP configs, system prompt configs, sandbox settings) under a shared `Type` base class. `lib/claude_agent_sdk/types.rb` shrank from 1510 to 588 lines; `MessageParser`'s system-message dispatch went from 215 lines to a 14-entry lookup table.

## [0.16.5] - 2026-04-24

### Added
- `display:` option on `ThinkingConfigAdaptive` and `ThinkingConfigEnabled`, forwarded to the CLI as `--thinking-display <summarized|omitted>`. Opus 4.7 defaults thinking display to `"omitted"` (empty `thinking` field, signature only), so pass `ThinkingConfigAdaptive.new(display: "summarized")` to receive plaintext summarized thinking text. Invalid values raise `ArgumentError` at construction. See [adaptive thinking docs](https://docs.claude.com/en/docs/build-with-claude/adaptive-thinking).

### Internal
- Extracted private `writeln`/`write` helpers in `Client` and `Query` to consolidate the `@transport.write(json + "\n")` pattern across five call sites. Pure refactor; same bytes on the wire.

## [0.16.4] - 2026-04-23

### Fixed
- `Client#receive_response` no longer hangs in interactive Client mode. The 0.16.1 flag-based fix relied on the loop draining via the transport's `:end` sentinel, which only arrives when the CLI subprocess exits — true for one-shot `query()` but never for a `Client` whose CLI stays alive between turns. `receive_response` now drives `QueryHandler#receive_messages` directly so its `break` runs on the same fiber as the underlying `Async::Queue#dequeue` loop and unwinds it. The 0.16.1 regression spec passed only because its stub iterated a finite array; replaced with a real `Async::Queue` driven from a sibling task so a hang now fails the test.

### Internal
- `FiberBoundary` doc-comment now warns that `break`/`return`/`next` cannot cross the thread hop, so SDK-internal loops yielding user callbacks must keep loop control on the outer side of the boundary.

## [0.16.3] - 2026-04-23

### Changed
- Internal: extracted `SubprocessCLITransport#record_bounded_stderr` helper to deduplicate the recent-stderr ring-buffer append/trim logic shared by `handle_stderr` and `drain_stderr_with_accumulation`, and replaced the inlined `20` cap with a named `RECENT_STDERR_LINES_LIMIT` constant. No public behavior change.

## [0.16.2] - 2026-04-23

### Changed
- Extracted `ClaudeAgentSDK::CommandBuilder` from `SubprocessCLITransport`. CLI argv assembly now lives in its own class and can be exercised in isolation — `CommandBuilder.new(cli_path, options).build` returns the argv array without booting a transport. No public behavior change; `SubprocessCLITransport#build_command` still works and now delegates to `CommandBuilder`.

## [0.16.1] - 2026-04-21

### Fixed
- `Client#receive_response` no longer raises `LocalJumpError: break from proc-closure` when called inside `Async { }`. The 0.15.1 thread-hop severed `break`'s unwind target; replaced with a flag so the loop exits via the natural `end` marker after `ResultMessage`.

## [0.16.0] - 2026-04-22

### Added
- **`#text` on every message type that carries content.** No more hand-rolling a `select { TextBlock }.map(&:text).join` in every consumer.
  - `AssistantMessage#text` — joins text across `TextBlock`s in the content array.
  - `UserMessage#text` — handles both String content (plain prompt) and Array-of-blocks content.
  - `SessionMessage#text` — joins text across parsed content blocks from a historical transcript.
  - `#to_s` on each message type is aliased to `#text`, so `puts message` and string interpolation just work.
  - Non-text blocks (`ToolUseBlock`, `ThinkingBlock`, `ToolResultBlock`, `UnknownBlock`) intentionally do **not** answer `#text` — only `TextBlock` is textual. The message helpers use `Array#grep(TextBlock)` to select text blocks.
- **`SessionMessage#content_blocks`** returns typed block objects (`TextBlock`, `ThinkingBlock`, `ToolUseBlock`, `ToolResultBlock`, `UnknownBlock`) instead of the raw hash blocks from the JSONL transcript. Unknown block types become `UnknownBlock` for forward compatibility with newer CLI versions.

### Changed
- Rails Integration / Quick Start / Observability / File Checkpointing README examples dropped the `content.select { is_a?(TextBlock) }.map(&:text).join` dance in favor of `message.text`.

## [0.15.1] - 2026-04-22

### Fixed
- **Thread-keyed libraries are now safe inside SDK callbacks.** The SDK internally hops to a plain thread at every user-callback boundary — blocks passed to `ClaudeAgentSDK.query` / `Client#receive_messages`, SDK MCP tool handlers, hooks, permission callbacks, and observer methods — so the `async` gem's Fiber scheduler is no longer visible to user code. Previously, any library that keys state on `Thread.current` (ActiveRecord and every DB driver keyed by thread — `pg`, `mysql2`, `sqlite3` — plus per-thread HTTP/cache pools, request stores, etc.) could be corrupted by the scheduler interleaving two fibers onto one checked-out connection. Rails/Sidekiq/Kamal consumers no longer need a caller-side wrapper to avoid this. See the "Thread-keyed libraries are safe inside SDK callbacks" subsection under Rails Integration in the README.

### Changed
- **Callbacks run on a plain thread, not inside `Async::Task`.** Fiber-specific primitives (e.g. `Async::Task.current.sleep`, `Async::Task.current.async { ... }`) are no longer available inside tool handlers, hooks, permission callbacks, message blocks, or observers. Callbacks that want cooperative concurrency can open their own `Async { }` block. In practice callbacks do ordinary Ruby work and return a value, so this rarely affects real code.

## [0.15.0] - 2026-04-17

### Fixed

#### Protocol & CLI
- `--setting-sources` is now only emitted when the option is explicitly configured. Previously every invocation sent `--setting-sources ""`, which the CLI can interpret as "no setting sources" rather than "use defaults", overriding the CLI's own source resolution.
- `extra_args` flag names are validated against a lowercase kebab-case pattern and raise `ArgumentError` otherwise. Prevents option injection from multi-tenant configs (e.g. an attacker-controlled hash injecting `--permission-mode bypassPermissions` and relying on CLI last-wins to defeat SDK-chosen safety).

#### Concurrency
- `SubprocessCLITransport#close` replaced `Timeout.timeout` with Async-safe polling on `@process.alive?`. Stdlib `Timeout.timeout` raises via `Thread#raise`, which can corrupt fiber-scheduler state when `close` runs inside the Async reactor. Still raises `Timeout::Error` so existing rescue clauses keep working.
- Inbound `control_request` handlers are now spawned as children of the current read task via `Async::Task.current.async`. Bare `Async do` had ambiguous parent linkage; `@task.stop` could leave handler tasks writing to a closed transport.

#### Sessions
- `list_sessions` and `get_session_messages` coerce `offset: nil` to 0. Previously callers splatting from an options hash crashed on `nil.positive?` / `messages[nil..]`.
- `fork_session` streams the source JSONL via `File.foreach` instead of `File.read`, and scrubs non-UTF-8 bytes on each line. Fixes `Encoding::InvalidByteSequenceError` on stray bytes in tool output and avoids slurping sessions that can reach hundreds of MB.
- `simple_hash` (used for project-dir hashing) now iterates UTF-16 code units to match JavaScript's `charCodeAt`. Previously `each_char` + `ord` diverged from the official tools for supplementary characters (emoji, CJK extensions), so paths containing them hashed to different project directories and silently returned no sessions.

#### Security
- Replaced shell backticks with `Open3.capture3` (array args) in worktree detection. The path argument was already `Shellwords.escape`d, but running via `/bin/sh` leaves a latent shell-injection surface — any future interpolation without escaping would be exploitable.

### Changed
- `derive_fork_title` helper is now `private_class_method`, matching its siblings on `SessionMutations`.



### Added
- **`EFFORT_LEVELS` constant** exposing `%w[low medium high xhigh max]`. Consumers can reference `ClaudeAgentSDK::EFFORT_LEVELS` for validation instead of hard-coding the list.
- **`xhigh` effort level**: documented in the SDK to match the Claude Code CLI (2.1.111+). Supported on Opus 4.7; the CLI auto-falls-back to the highest supported level on older models (e.g. `xhigh` → `high` on Opus 4.6).

### Changed
- Inline comments and README updated to reference `ClaudeAgentSDK::EFFORT_LEVELS` rather than a stale hard-coded level list.

## [0.14.1] - 2026-04-09

### Fixed
- **Thinking configuration**: Use `--thinking adaptive` / `--thinking disabled` CLI flags instead of mapping to `--max-thinking-tokens`. Previously, `ThinkingConfigAdaptive` was mapped to `--max-thinking-tokens 32000` (fixed budget) and `ThinkingConfigDisabled` to `--max-thinking-tokens 0`, which put the CLI into the wrong mode. Only `ThinkingConfigEnabled` now uses `--max-thinking-tokens`. (Parity with [Python SDK #796](https://github.com/anthropics/claude-agent-sdk-python/pull/796))

### Added
- **`exclude_dynamic_sections`** on `SystemPromptPreset`: When set to `true`, the CLI strips per-user dynamic sections (working directory, auto-memory, git status) from the preset system prompt and re-injects them into the first user message. This makes the system prompt byte-identical across users, enabling cross-user prompt-caching hits. Sent via `excludeDynamicSections` in the initialize control message; older CLIs silently ignore it. (Parity with [Python SDK #797](https://github.com/anthropics/claude-agent-sdk-python/pull/797))

## [0.14.0] - 2026-04-08 — Python SDK v0.1.51–0.1.56 Parity

### Added

#### Type Completeness
- `AssistantMessage`: `message_id`, `stop_reason`, `session_id`, `uuid` fields (populated from CLI message data)
- `AgentDefinition`: `disallowed_tools`, `max_turns`, `initial_prompt`, `background`, `effort`, `permission_mode` fields (serialized to CLI via initialize request)
- `ToolPermissionContext`: `tool_use_id`, `agent_id` fields for distinguishing parallel permission requests and sub-agent context
- `PERMISSION_MODES`: added `dontAsk` and `auto` values

#### New Types and Options
- `SystemPromptFile` class — loads system prompt from a file path via `--system-prompt-file` CLI flag
- `TaskBudget` class — API-side token budget, passed as `--task-budget` CLI flag
- `ForkSessionResult` class — returned by `fork_session()` with the new session ID
- `session_id` option on `ClaudeAgentOptions` — specify a custom session ID via `--session-id` CLI flag
- `task_budget` option on `ClaudeAgentOptions`

#### Session Management
- `ClaudeAgentSDK.delete_session(session_id:, directory:)` — hard-deletes a session JSONL file
- `ClaudeAgentSDK.fork_session(session_id:, directory:, up_to_message_id:, title:)` — filesystem-level fork with UUID remapping, sidechain filtering, content-replacement forwarding, and auto-generated titles
- `offset` parameter on `ClaudeAgentSDK.list_sessions` for cursor-based pagination

#### Client Introspection
- `Client#get_context_usage` / `Query#get_context_usage` — sends `get_context_usage` control request for context window breakdown (tokens by category, model, MCP tools, memory files, etc.)

#### MCP Robustness
- `SdkMcpTool#meta` field and `_meta` forwarding in `tools/list` responses — prevents silent truncation of large tool results (>50K chars) by forwarding `anthropic/maxResultSizeChars` through the MCP `_meta` field
- `create_tool` auto-populates `_meta` from `annotations[:maxResultSizeChars]` when present

## [0.13.1] - 2026-04-05

### Fixed
- Handle `ProcessError` when CLI exits non-zero after delivering a valid result (e.g., StructuredOutput `tool_use` triggers exit code 1). Previously this propagated as a fatal error; now it is suppressed when a result was already received.

## [0.13.0] - 2026-04-03

### Added

#### Observer Interface
- `Observer` module with `on_user_prompt`, `on_message`, `on_error`, `on_close` — all with no-op defaults
- `observers` option on `ClaudeAgentOptions` (default `[]`) — register observers for both `query()` and `Client`
- `resolve_observers` supports callable factories (lambdas) for thread-safe global defaults in Rails/Puma/Sidekiq
- `notify_observers` rescues per-observer errors so observers never crash the main pipeline

#### OpenTelemetry Instrumentation
- `ClaudeAgentSDK::Instrumentation::OTelObserver` — emits spans using `gen_ai.*` and OpenInference semantic conventions
- Span tree: `claude_agent.session` (root) → `claude_agent.generation` + `claude_agent.tool.*` (children)
- `langfuse.observation.type` set on all spans (`agent`/`generation`/`tool`) to enable Langfuse trace flow diagram
- `input.value`/`output.value` (OpenInference) for Langfuse Preview Input/Output fields
- `llm.token_count.*`, `llm.cost.total`, `llm.model_name` for full Langfuse cost/usage tracking
- `openinference.span.kind` (`AGENT`/`LLM`/`TOOL`) on all spans
- Events: `api_retry`, `rate_limit`, `tool_progress` recorded on root span
- Lazy `require 'opentelemetry'` — zero cost for users who don't use it

#### Examples
- `otel_langfuse_example.rb` — Langfuse-via-OTel setup with OTLP exporter
- `test_langfuse_otel.rb` — multi-tool integration test (Bash tool calls)

### Changed
- README: added Observability section with Langfuse setup guide, span attribute reference, custom observer example, Rails initializer patterns
- README: split sandbox into CLI settings vs sandbox-runtime rows in comparison table
- README: updated recommended gem version to `~> 0.13.0`
- CLAUDE.md: documented observer/instrumentation architecture

## [0.12.0] - 2026-04-01

Full Claude Code parity release — cross-referenced against the Claude Code source (`coreSchemas.ts`) and TypeScript SDK to bring every message type, hook event, and sandbox setting into the Ruby SDK.

### Added

#### All 24 Message Types (full CLI parity)
- `InitMessage` — session start / `/clear` with uuid, session_id, agents, api_key_source, betas, claude_code_version, cwd, tools, mcp_servers, model, permission_mode, slash_commands, output_style, skills, plugins, fast_mode_state
- `CompactBoundaryMessage` — context compaction with uuid, session_id, compact_metadata (pre_tokens, trigger, preserved_segment)
- `StatusMessage` — compacting status, permission mode changes
- `APIRetryMessage` — attempt, max_retries, retry_delay_ms, error_status, error
- `LocalCommandOutputMessage` — local command output content
- `HookStartedMessage`, `HookProgressMessage`, `HookResponseMessage` — hook lifecycle with hook_id, hook_name, hook_event, stdout, stderr, output, exit_code, outcome
- `SessionStateChangedMessage` — idle/running/requires_action state
- `FilesPersistedMessage` — files, failed, processed_at
- `ElicitationCompleteMessage` — MCP elicitation completion
- `ToolProgressMessage` — per-tool elapsed time tracking (type: `tool_progress`)
- `AuthStatusMessage` — authentication status (type: `auth_status`)
- `ToolUseSummaryMessage` — tool use summaries (type: `tool_use_summary`)
- `PromptSuggestionMessage` — predicted next prompts (type: `prompt_suggestion`)

#### All 27 Hook Events (full CLI parity)
- New hook input types: `SessionStartHookInput`, `SessionEndHookInput`, `StopFailureHookInput`, `PostCompactHookInput`, `PermissionDeniedHookInput`, `SetupHookInput`, `TeammateIdleHookInput`, `TaskCreatedHookInput`, `TaskCompletedHookInput`, `ElicitationHookInput`, `ElicitationResultHookInput`, `ConfigChangeHookInput`, `InstructionsLoadedHookInput`, `CwdChangedHookInput`, `FileChangedHookInput`, `WorktreeCreateHookInput`, `WorktreeRemoveHookInput`
- New hook specific output types: `SetupHookSpecificOutput`, `PermissionDeniedHookSpecificOutput`, `CwdChangedHookSpecificOutput`, `FileChangedHookSpecificOutput`
- `StopHookInput` and `SubagentStopHookInput` now include `last_assistant_message`

#### Bare Mode
- `bare: true` option on `ClaudeAgentOptions` — sugar for `--bare` CLI flag (skips hooks, LSP, plugin sync, CLAUDE.md auto-discovery, auto-memory, keychain reads)

#### Full Sandbox Settings (CC parity)
- `SandboxFilesystemConfig` — new class with allow_write, deny_write, deny_read, allow_read, allow_managed_read_paths_only
- `SandboxNetworkConfig` — added allowed_domains, allow_managed_domains_only
- `SandboxSettings` — added fail_if_unavailable, filesystem, enable_weaker_network_isolation, ripgrep
- `ignore_violations` now accepts a plain Hash (matching CC's `Record<string, string[]>`)
- Removed `SandboxIgnoreViolations` class (CC uses generic hash, not typed struct)

#### Expanded Existing Types
- `ResultMessage` — added uuid, fast_mode_state, model_usage, permission_denials, errors
- `TaskStartedMessage` — added workflow_name, prompt
- `TaskProgressMessage` — added summary
- `CompactMetadata` — added preserved_segment
- `ASSISTANT_MESSAGE_ERRORS` — added max_output_tokens

#### Session Browsing
- `get_session_info(session_id:, directory:)` — single-session metadata lookup without scanning full directory
- `SDKSessionInfo` — added tag, created_at fields; improved title/summary extraction

#### Examples
- `message_types_example.rb` — comprehensive handler for all 24 message types
- `lifecycle_hooks_example.rb` — all 27 hook events with typed inputs/outputs
- `bare_mode_example.rb` — minimal startup patterns
- `sandbox_example.rb` — full sandbox config (network, filesystem, violations)

### Fixed
- Graceful subprocess shutdown: wait before SIGTERM to avoid race conditions
- `CLAUDE_CODE_ENTRYPOINT` uses default-if-absent semantics (doesn't override caller env)
- Pre-existing `Time.zone` spec failures in sessions_spec.rb
- Pre-existing `File.open` without block in session_mutations.rb

### Changed
- README restructured: positioned as community Ruby SDK (not Python mirror), 3-way comparison table (TS/Python/Ruby), links to official SDKs
- Skill updated to cover all new types and hook events

## [0.11.0] - 2026-03-20

### Added

#### Custom Transport Support
- `Client.new` accepts `transport_class:` and `transport_args:` keyword arguments, allowing consumers to plug in custom transports (e.g., E2B sandbox, remote SSH) without duplicating `Client#connect` internals
- Default remains `SubprocessCLITransport` — zero behavior change for existing callers
- Custom transport class must implement the `Transport` interface (`connect`, `write`, `read_messages`, `end_input`, `close`, `ready?`)
- `transport_args` are passed as keyword arguments to `transport_class.new(options, **transport_args)`
- All option transformations, MCP extraction, hook conversion, and Query lifecycle stay in `Client#connect` — the transport only handles I/O

## [0.10.0] - 2026-03-20

Port of Python SDK v0.1.48 features for feature parity.

### Added

#### Session Mutations
- `ClaudeAgentSDK.rename_session(session_id:, title:, directory:)` — rename a session by appending a custom-title JSONL entry
- `ClaudeAgentSDK.tag_session(session_id:, tag:, directory:)` — tag a session (pass `nil` to clear); tags are Unicode-sanitized
- `SessionMutations` module with `rename_session`, `tag_session`, and internal Unicode sanitization helpers
- Ported from Python SDK's `_internal/session_mutations.py` with TOCTOU-safe `O_WRONLY | O_APPEND` file operations

#### AssistantMessage Usage
- `usage` attribute on `AssistantMessage` — token usage data from the API response
- `MessageParser` populates `usage` from `data.dig(:message, :usage)`

#### AgentDefinition Fields
- `skills`, `memory`, `mcp_servers` attributes on `AgentDefinition`
- Serialized as `skills`, `memory`, `mcpServers` (camelCase) in the CLI wire protocol initialize request

#### TaskUsage Typed Class
- `TaskUsage` class with `total_tokens`, `tool_uses`, `duration_ms` attributes
- `TaskUsage.from_hash` factory supporting symbol, string, camelCase, and snake_case keys

### Removed

#### FGTS Environment Variable
- Removed auto-setting of `CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING` environment variable when `include_partial_messages` is enabled — Python SDK v0.1.48 reverted this because it causes HTTP 400 errors on LiteLLM proxies, Bedrock, and Vertex with Claude 4.5 models. The `--include-partial-messages` CLI flag remains the correct mechanism.

## [0.9.0] - 2026-03-12

Port of Python SDK v0.1.48 parity improvements.

### Added

#### Typed Rate Limit Events
- `RateLimitInfo` class with `status`, `resets_at`, `rate_limit_type`, `utilization`, `overage_status`, `overage_resets_at`, `overage_disabled_reason`, `raw` attributes
- `RATE_LIMIT_STATUSES` constant (`allowed`, `allowed_warning`, `rejected`)
- `RATE_LIMIT_TYPES` constant (`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `overage`)
- `RateLimitEvent` now has typed `rate_limit_info`, `uuid`, `session_id` attributes (previously raw `data` hash)
- Backward-compatible `data` accessor on `RateLimitEvent` returns raw hash from `rate_limit_info.raw`

#### MCP Status Output Types
- `McpClaudeAIProxyServerConfig` type for `claudeai-proxy` servers in MCP status responses
- `McpSdkServerConfigStatus` type for serializable SDK server config in status responses
- `McpServerStatus.parse` handles `claudeai-proxy` config type

#### Effort Level
- `effort` option now supports `"max"` value in addition to `"low"`, `"medium"`, `"high"`

## [0.8.1] - 2026-03-08

Python SDK parity fixes for one-shot `query()` control protocol and CLI transport.

### Fixed

#### One-Shot Query Control Protocol
- **Hooks and `can_use_tool` in `query()`:** One-shot `query()` now passes `hooks`, `can_use_tool`, and SDK MCP servers through to the `Query` handler, matching the Python SDK (previously these were Client-only)
- **`can_use_tool` validation:** String prompts with `can_use_tool` now raise `ArgumentError` (streaming mode required); conflicting `permission_prompt_tool_name` also raises early
- **`session_id` parity:** One-shot queries now send `session_id: ''` (was `'default'`), matching Python SDK behavior
- **Premature stdin close:** Added `wait_for_result_and_end_input` that holds stdin open until the first result when hooks or SDK MCP servers need control message exchange
- **`stream_input` stdin leak:** Moved `end_input` to `ensure` block so stdin is always closed even when the stream enumerator raises
- **`Async::Condition` race:** Added `@first_result_received` flag guard to prevent lost signals when result arrives before `wait` is called

#### CLI Transport Parity
- **File checkpointing:** Moved from deprecated `--enable-file-checkpointing` CLI flag to `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING` environment variable
- **Partial messages:** Now also sets `CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING=1` environment variable when `include_partial_messages` is enabled
- **Tools preset:** `ToolsPreset` objects and preset hashes now map to `--tools default` (was `--tools <json>`)
- **Plugins:** Changed from `--plugins <json>` to `--plugin-dir <path>` per-plugin, matching current CLI interface
- **Plugin type:** `SdkPluginConfig` now defaults to `type: 'local'` (was `'plugin'`), normalizes legacy `'plugin'` type
- **Rewind control request:** Changed key from `userMessageUuid` to `user_message_id` for Python SDK parity
- **Settings file with sandbox:** When sandbox is enabled and settings is a file path, now reads and parses the file to merge sandbox settings (raises on missing/invalid files instead of silently dropping settings)

#### Hook Input Parsing
- **Falsy value preservation:** `parse_hook_input` now uses `key?`-based lookup instead of `||`, correctly preserving `false` and `nil` values (e.g., `stop_hook_active: false`)
- **Empty hooks normalization:** `query()` now skips empty matcher lists and normalizes hooks to `nil` when no matchers survive, preventing unnecessary 60s close-wait timeout

### Changed
- **`build_command` refactored:** Extracted `build_settings_args`, `build_tools_args`, `build_output_format_args`, `build_mcp_servers_args`, `build_plugins_args` private helpers to reduce method complexity

## [0.8.0] - 2026-03-05

Port of Python SDK v0.1.46 features.

### Added

#### Task Message Types
- `TaskStartedMessage`, `TaskProgressMessage`, `TaskNotificationMessage` — typed `SystemMessage` subclasses for background task lifecycle events
- `TASK_NOTIFICATION_STATUSES` constant (`completed`, `failed`, `stopped`)
- `MessageParser` dispatches on `subtype` within `system` messages, falling back to generic `SystemMessage` for unknown subtypes

#### MCP Server Control
- `reconnect_mcp_server(server_name)` on `Query` and `Client` — retry failed MCP server connections
- `toggle_mcp_server(server_name, enabled)` on `Query` and `Client` — enable/disable MCP servers live
- `stop_task(task_id)` on `Query` and `Client` — stop a running background task

#### Subagent Context on Hook Inputs
- `agent_id` and `agent_type` attributes on `PreToolUseHookInput`, `PostToolUseHookInput`, `PostToolUseFailureHookInput`, `PermissionRequestHookInput`
- Populated when hooks fire inside subagents, allowing attribution of tool calls to specific agents

#### Result Message
- `stop_reason` attribute on `ResultMessage` (e.g., `'end_turn'`, `'max_tokens'`, `'stop_sequence'`)

#### Typed MCP Status Response
- `McpServerInfo`, `McpToolAnnotations`, `McpToolInfo`, `McpServerStatus`, `McpStatusResponse` types
- `.parse` class methods for hydrating from raw CLI response hashes
- `MCP_SERVER_CONNECTION_STATUSES` constant (`connected`, `failed`, `needs-auth`, `pending`, `disabled`)

#### Session Browsing
- `ClaudeAgentSDK.list_sessions(directory:, limit:, include_worktrees:)` — list sessions from `~/.claude/projects/` JSONL files
- `ClaudeAgentSDK.get_session_messages(session_id:, directory:, limit:, offset:)` — reconstruct conversation chain from session transcript
- `SDKSessionInfo` type with `session_id`, `summary`, `last_modified`, `file_size`, `custom_title`, `first_prompt`, `git_branch`, `cwd`
- `SessionMessage` type with `type`, `uuid`, `session_id`, `message`
- Pure filesystem operations — no CLI subprocess required
- Git worktree-aware session scanning
- `parentUuid` chain walking with cycle detection for robust conversation reconstruction

### Fixed
- **`McpToolAnnotations.parse` losing `false` values:** `readOnly: false` was evaluated as `false || nil → nil` due to `||` short-circuiting. Now uses `.key?` to check presence before falling back to snake_case keys.

## [0.7.3] - 2026-02-26

### Fixed
- **String-keyed JSON schema crash:** Libraries like [RubyLLM](https://github.com/crmne/ruby_llm) that deep-stringify schema keys (e.g., `{ 'type' => 'object', 'properties' => { ... } }`) were misidentified as simple type-mapping schemas, causing each top-level key to be treated as a parameter name instead of passing the schema through. Now both symbol-keyed and string-keyed schemas are detected and normalized correctly. (PR #9 by [@iuhoay](https://github.com/iuhoay))
- **Shallow key symbolization:** `convert_schema` used `transform_keys` (shallow) which left nested property keys as strings, breaking downstream `MCP::Tool::InputSchema` construction. Now uses deep symbolization recursively.
- **Guard ordering crash:** `convert_schema` and `convert_input_schema` accessed `schema[:type]` before the `schema.is_a?(Hash)` guard, which would raise `NoMethodError` on `nil` input.
- **Schema detection tightened:** Pre-built schema detection now requires `type == 'object'` and `properties.is_a?(Hash)`, preventing false positives when a simple schema happens to have parameters named `type` and `properties`.

### Added
- `ClaudeAgentSDK.deep_symbolize_keys` utility method for recursive hash key symbolization

## [0.7.2] - 2026-02-21

### Fixed
- **Unknown content block crash:** Unrecognized content block types (e.g., `document` blocks from PDF reading) now return `UnknownBlock` instead of raising `MessageParseError`, aligning with the Python SDK's forward-compatible design
- **Unknown message type crash:** Unrecognized message types now return `nil` (skipped by callers) instead of raising
- **Empty input schema crash:** Tools with no parameters (`input_schema: {}`) caused `MCP::Tool::InputSchema` validation failure (`required` array must have at least 1 item per JSON Schema draft-04). Now omits `required` when empty.

### Added
- `UnknownBlock` type that preserves raw data for unrecognized content block types

### Changed
- **Breaking (minor):** `MessageParser.parse` no longer raises `MessageParseError` for unknown message types — returns `nil` instead. If you were rescuing `MessageParseError` to handle unknown types, check for `nil` return values instead.
- **Breaking (minor):** `MessageParser.parse_content_block` no longer raises `MessageParseError` for unknown content block types — returns `UnknownBlock` instead. Content block iteration using `is_a?` filtering (e.g., `block.is_a?(TextBlock)`) is unaffected.

## [0.7.1] - 2026-02-21

### Fixed
- **Transport initialization crash:** `SubprocessCLITransport#initialize` used raw `options` parameter instead of resolved `@options` on lines 19, 20, 27 — caused `NoMethodError: undefined method 'cli_path' for nil` when using single-arg form (how `Client.new` calls it)

## [0.7.0] - 2026-02-20

### Added

#### Thinking Configuration
- `ThinkingConfigAdaptive`, `ThinkingConfigEnabled`, `ThinkingConfigDisabled` classes for structured thinking control
- `thinking` option on `ClaudeAgentOptions` — takes precedence over deprecated `max_thinking_tokens`
  - `ThinkingConfigAdaptive` → 32,000 token default budget
  - `ThinkingConfigEnabled(budget_tokens:)` → explicit budget
  - `ThinkingConfigDisabled` → 0 tokens (thinking off)
- `effort` option on `ClaudeAgentOptions` — maps to `--effort` CLI flag (`'low'`, `'medium'`, `'high'`)

#### Tool Annotations
- `annotations` attribute on `SdkMcpTool` for MCP tool annotations (e.g., `readOnlyHint`, `title`)
- `annotations:` keyword on `ClaudeAgentSDK.create_tool`
- Annotations included in `SdkMcpServer#list_tools` responses

#### Hook Enhancements
- `tool_use_id` attribute on `PreToolUseHookInput` and `PostToolUseHookInput`
- `additional_context` attribute on `PreToolUseHookSpecificOutput`

#### Message Enhancements
- `tool_use_result` attribute on `UserMessage` for tool response data
- `MessageParser` populates `tool_use_result` from CLI output

### Changed

#### Architecture: Always Streaming Mode (BREAKING for internal API)
- **`SubprocessCLITransport`** now always uses `--input-format stream-json` — removed `--print` mode and `--agents` CLI flag
- **`SubprocessCLITransport.new`** still accepts `(prompt, options)` for compatibility but ignores the prompt argument (always uses streaming mode)
- **`query()`** now uses the full control protocol internally (Query handler + initialize handshake), matching the Python SDK
- **Agents** are sent via the `initialize` control request over stdin instead of CLI `--agents` flag, avoiding OS ARG_MAX limits
- **`query()`** now supports SDK MCP servers and `can_use_tool` callbacks (previously Client-only)

#### Empty System Prompt
- When `system_prompt` is `nil`, passes `--system-prompt ""` to CLI for predictable behavior without the default Claude Code system prompt

## [0.6.3] - 2026-02-18

### Fixed
- **ProcessError stderr:** Real stderr output is now included in `ProcessError` exceptions (was always "No stderr output captured")
- **Rate limit events:** Added `RateLimitEvent` type and `rate_limit_event` message parsing support

## [0.6.2] - 2026-02-17

### Fixed
- **Large prompt `Errno::E2BIG` crash:** Prompts exceeding 200KB are now piped via stdin instead of passed as CLI arguments, avoiding the OS `ARG_MAX` limit (typically 1MB on macOS/Linux). This fixes `CLIConnectionError: Failed to start Claude Code: Argument list too long` when using `query()` with large prompts.
- **Stderr pipe deadlock (`Errno::EPIPE`):** Always drain stderr in a background thread, even when `stderr` option is not set. Without this, `--verbose` output fills the 64KB OS pipe buffer, the subprocess blocks on write, and all pipes stall. Previously only manifested with long-running Opus sessions.

## [0.6.0] - 2026-02-13

### Added
- **Configurable control request timeout:** New `CLAUDE_AGENT_SDK_CONTROL_REQUEST_TIMEOUT_SECONDS` environment variable (default 1200s) for tuning the control protocol timeout — essential for long-running agent sessions and agent teams
- **`ControlRequestTimeoutError`:** Dedicated error class (`< CLIConnectionError`) raised on control request timeouts, enabling typed exception handling instead of string matching

### Fixed
- **camelCase `requestId` fallback:** All control message routing (`read_messages`, `handle_control_response`, `handle_control_request`) now tolerates both `request_id` and `requestId` keys from the CLI
- **Outbound `requestId` parity:** Control requests and responses now include both `request_id` and `requestId` for maximum CLI compatibility
- **Pending request unblocking:** Transport errors now signal all pending control request conditions, preventing callers from hanging until timeout
- **Error object in message queue:** `read_messages` rescue now enqueues the exception object (not just `e.message`), preserving error class for typed handling
- **Thread-safe CLI discovery:** `find_cli` uses `Open3.capture2` instead of backtick shell for thread safety
- **Robust process cleanup:** `close` now uses SIGTERM → 2s grace period → SIGKILL escalation (was immediate SIGTERM with no fallback), handles `Errno::ESRCH` for already-dead processes, and logs cleanup warnings instead of silently swallowing errors

## [0.5.0] - 2026-02-07

### Added
- **Default configuration:** `ClaudeAgentSDK.configure` block for setting default options that merge with every `ClaudeAgentOptions` instance, ideal for Rails initializers (PR #8)
- `ClaudeAgentSDK.reset_configuration` for resetting defaults (useful in tests)
- Deep merge for `env` and `mcp_servers` hashes; provided values override configured defaults
- `OPTION_DEFAULTS` constant on `ClaudeAgentOptions` for introspectable non-nil defaults

### Changed
- `ClaudeAgentOptions#initialize` now uses `**kwargs` internally to correctly distinguish caller-provided values from method signature defaults

## [0.4.2] - 2026-02-07

### Fixed
- **MCP response fidelity:** Non-text content (images, binary data) is now preserved in SDK MCP tool responses instead of being silently dropped
- **MCP error key:** Tool error flag is now sent as `isError` (camelCase) matching the JSON-RPC spec, instead of `is_error` which the CLI ignored
- **MCP structured content:** `structuredContent` is now passed through in tool responses
- **ENV pollution:** `query()` and `Client.connect` no longer mutate the global `ENV`; entrypoint is passed via transport options
- **Symbol key env:** Fixed symbol keys in `env` option causing spawn failures (PR #7)

### Added
- `ClaudeAgentSDK.flexible_fetch` helper for tolerant hash key lookup (symbol/string, camelCase/snake_case)
- Gated real CLI integration tests (`RUN_REAL_INTEGRATION=1`) with budget cap
- `CLAUDE.md` architecture guide for contributors

## [0.4.1] - 2026-02-05

### Added

#### Hook Parity
- Added hook event support for `PostToolUseFailure`, `Notification`, `SubagentStart`, and `PermissionRequest`
- Expanded `SubagentStop` hook inputs with `agent_id`, `agent_transcript_path`, and `agent_type`
- Added hook-specific outputs for new hook events
- Added `updatedMCPToolOutput` support to `PostToolUse` hook outputs

#### MCP Status APIs
- `get_mcp_status` on `Query` and `Client` for live MCP connection status (streaming mode)
- `get_server_info` on `Client` as a parity alias for server initialization info

### Fixed
- Hook input parsing now supports both symbol and string keys
- Hook callback timeouts are enforced and control request cancellation is handled cleanly

## [0.4.0] - 2026-01-06

### Added

#### File Checkpointing & Rewind
- `enable_file_checkpointing` option in `ClaudeAgentOptions` for enabling file state checkpointing
- `rewind_files(user_message_uuid)` method on `Query` and `Client` classes
- `uuid` field on `UserMessage` for tracking message identifiers for rewind support

#### Beta Features Support
- `SDK_BETAS` constant with available beta features (e.g., `"context-1m-2025-08-07"`)
- `betas` option in `ClaudeAgentOptions` for enabling beta features

#### Tools Configuration
- `tools` option for base tools selection (separate from `allowed_tools`)
- Supports array of tool names, empty array `[]`, or `ToolsPreset` object
- `ToolsPreset` class for preset-based tool configuration
- `append_allowed_tools` option to append tools to the allowed list

#### Sandbox Settings
- `SandboxSettings` class for isolated command execution configuration
- `SandboxNetworkConfig` class for network isolation settings
- `SandboxIgnoreViolations` class for configuring violation handling
- `sandbox` option in `ClaudeAgentOptions` for sandbox configuration
- Automatic merging of sandbox settings into the main settings JSON

#### Additional Types
- `SystemPromptPreset` class for preset-based system prompts

### Technical Details
- All new CLI flags properly passed to Claude Code subprocess
- Sandbox settings merged into `--settings` JSON for CLI compatibility
- UserMessage UUID parsed from CLI output for rewind support

## [0.2.0] - 2025-10-17

### Changed
- **BREAKING:** Updated minimum Ruby version from 3.0+ to 3.2+ (required by official MCP SDK)
- **Major refactoring:** SDK MCP server now uses official Ruby MCP SDK (`mcp` gem v0.4) internally
- Internal implementation migrated from custom MCP to wrapping official `MCP::Server`

### Added
- Official Ruby MCP SDK (`mcp` gem) as runtime dependency
- Full MCP protocol compliance via official SDK
- `handle_json` method for protocol-compliant JSON-RPC handling

### Improved
- Better long-term maintenance by leveraging official SDK updates
- Aligned with Python SDK implementation pattern (using official MCP library)
- All tests passing with full backward compatibility maintained

### Technical Details
- Creates dynamic `MCP::Tool`, `MCP::Resource`, and `MCP::Prompt` classes from block-based definitions
- User-facing API remains unchanged - no breaking changes for Ruby 3.2+ users
- Maintains backward-compatible methods (`list_tools`, `call_tool`, etc.)

## [0.1.3] - 2025-10-15

### Added
- **MCP resource support:** Full support for MCP resources (list, read, subscribe operations)
- **MCP prompt support:** Support for MCP prompts (list, get operations)
- **Streaming input support:** Added streaming capabilities for input handling
- Feature complete MCP implementation matching Python SDK functionality

## [0.1.2] - 2025-10-14

### Fixed
- **Critical:** Replaced `Async::Process` with Ruby's built-in `Open3` for subprocess management
- Fixed "uninitialized constant Async::Process" error that prevented the gem from working
- Process management now uses standard Ruby threads instead of async tasks
- All tests passing

## [0.1.1] - 2025-10-14

### Fixed
- Added `~/.claude/local/claude` to CLI search paths to detect Claude Code in its default installation location
- Fixed issue where SDK couldn't find Claude Code when accessed via shell alias

### Added
- Comprehensive test suite (RSpec)
- Test documentation in spec/README.md

### Changed
- Marked as unofficial SDK in README and gemspec
- Updated repository URLs to reflect community-maintained status

## [0.1.0] - 2025-10-14

### Added
- Initial release of Claude Agent SDK for Ruby
- Support for `query()` function for simple one-shot interactions
- `ClaudeSDKClient` class for bidirectional, stateful conversations
- Custom tool support via SDK MCP servers
- Hook support for all major hook events
- Comprehensive error handling
- Full async/await support using the `async` gem
- Examples demonstrating common use cases
