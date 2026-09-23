# Upgrading from 0.37 to 1.0

1.0 is 0.37 plus three breaking changes. 0.37 already warns about each of the
first two at the exact call site, so **if your app runs on 0.37 without SDK
warnings, the first two changes will not affect it on 1.0**, with one silent
exception: `respond_to?` on a camelCase name that is not an attribute
(`msg.respond_to?(:toH)`) answered `true` on 0.37 without a warning and answers
`false` on 1.0. The third change is to which exception class you rescue.

| Area | 0.37 | 1.0 |
|------|------|-----|
| Unknown key on a type you build (`HookMatcher.new(matchr: ...)`) | warns once, key ignored | raises `ArgumentError` |
| `#[]` / `#[]=` / camelCase reaching a non-attribute (`msg[:to_h]`, `msg.toH`) | works, warns once | treated as undefined |
| Store-backed resume failure | bare `RuntimeError` | `ClaudeAgentSDK::SessionStoreError` |

## Checklist

1. Upgrade to 0.37 first: `gem 'claude-agent-sdk', '~> 0.37.0'`, then `bundle update claude-agent-sdk`.
2. Run your test suite, and exercise a staging boot, with warnings visible and
   stderr kept: no `-W0`, no `$VERBOSE = nil`, and no stderr filtering.
   For example, `bundle exec rspec 2> sdk-warnings.log`.
3. Find the SDK's warnings:
   ```sh
   grep -E 'unknown attribute|is not an attribute|is deprecated' sdk-warnings.log
   ```
   Each line starts with the `file:line` of your call. Every warning is
   printed once per process per class and key (or per method), so fix what
   you find and run again until the output is empty.
4. Fix each hit as described below.
5. Around code that resumes from a `session_store:` (`query`, `ask`,
   `Client#connect`, `Client.open`), search for `rescue RuntimeError` and for
   rescues of your adapter's own exception classes that inherit from
   `RuntimeError` (for example `Net::ReadTimeout`, a `Timeout::Error`, which is
   a `RuntimeError`). In 1.0 these arrive wrapped: rescue
   `ClaudeAgentSDK::SessionStoreError` and inspect `#cause` for the original.
6. Upgrade: `gem 'claude-agent-sdk', '~> 1.0'`.

## Unknown keys raise `ArgumentError`

The value types you build and pass *in* now reject a key they do not define,
as `ClaudeAgentOptions` always has. Before 0.37 the key was silently dropped,
so a typo such as `matchr:` built a matcher that matched every tool:

```ruby
ClaudeAgentSDK::HookMatcher.new(matchr: 'Bash', hooks: [check])
# 0.37: warning: ClaudeAgentSDK::HookMatcher: unknown attribute :matchr ignored; this will raise ArgumentError in 1.0 (known: hooks, matcher, timeout)
# 1.0:  ArgumentError: ClaudeAgentSDK::HookMatcher: unknown attribute :matchr (known: hooks, matcher, timeout)
```

This covers `.new` and `#[]=` on the option values (`AgentDefinition`,
`SandboxSettings` and its network and filesystem configs, the three thinking
configs, `TaskBudget`, the three system prompt types, `ToolsPreset`,
`SdkPluginConfig`, the four MCP server configs), `HookMatcher`, the hook
outputs (`SyncHookJSONOutput`, `AsyncHookJSONOutput`, every
`*HookSpecificOutput`), `PermissionResultAllow`, `PermissionResultDeny`,
`PermissionUpdate` and `PermissionRuleValue`. The full list is in
[docs/types.md](docs/types.md#unknown-keys).

**Fix:** correct the key, or remove it if the type never had it. Symbol and
String keys, snake_case and camelCase all still work, and so does a type's own
discriminator (`type`, `hook_event_name`, `behavior`), so on types that define
their own `#to_h` (the MCP server configs, `SandboxSettings`, the system prompt
types, the hook outputs, ...) `klass.new(value.to_h)` round-trips. For a Hash you did not write yourself (deserialized from the CLI,
a queue or a database), use `.from_hash` or `.wrap`: both stay lenient and
ignore unknown keys. Types the SDK parses from CLI output (messages, content
blocks, hook inputs) are not affected.

## `#[]`, `#[]=` and camelCase reach attributes only

These accessors are public API for a type's attributes: the fields it declares,
predicates such as `options.forkSession?`, and any method your own code adds to
a subclass, a mixin or an instance. Through 0.37 they reached *any* public
method. In 1.0 a name that is not an attribute behaves like an undefined one:

| Call | 0.37 | 1.0 |
|------|------|-----|
| `msg[:to_h]`, `msg['freeze']` | calls the method, warns | `nil` (method not called) |
| `msg[:some_method] = x` | calls `some_method=`, warns | ignored; `ArgumentError` on the strict types above |
| `msg.toH` | calls `to_h`, warns | `NoMethodError`; `respond_to?(:toH)` is `false` |

**Fix:** call the method directly (`msg.to_h`). `UserMessage#text` and
`AssistantMessage#text` are convenience methods, not attributes, so
`msg[:text]` is `nil`; use `msg.text`.

## `SessionStoreError` replaces `RuntimeError` on store-backed resume

When `query`, `ask` or `Client#connect` resume a session from
`session_store:` and a store call raises or exceeds `load_timeout_ms`, they now
raise `ClaudeAgentSDK::SessionStoreError < ClaudeSDKError`. In 0.37 this was a
bare `RuntimeError`, and a `RuntimeError` raised by your adapter escaped
unwrapped, so `rescue ClaudeAgentSDK::ClaudeSDKError` missed both. The message
names the store call and `#cause` holds your adapter's exception (or the
timeout):

```ruby
begin
  ClaudeAgentSDK.ask('Continue', options: options)
rescue ClaudeAgentSDK::SessionStoreError => e
  e.message # "SessionStore#load for session 3f2c… failed during resume materialization: IOError: …"
  e.cause   # the IOError your adapter raised
end
```

**Fix:** replace `rescue RuntimeError` on these paths with
`rescue ClaudeAgentSDK::SessionStoreError` (or `ClaudeSDKError`). Other store
paths are unchanged: the session functions called with `session_store:` behave
exactly as in 0.37, and mirroring failures still arrive as
`MirrorErrorMessage`, never as exceptions.

## What SemVer covers from 1.0

No breaking changes within 1.x to the public API: everything documented in
`docs/` and the README, and every class, module, method and constant in the
YARD docs that is not tagged `@api private`. `@api private` objects (`Query`,
`MessageParser`, `FiberBoundary`, the `Sessions*` modules, ...) stay callable
but can change in any release. See
[CONTRIBUTING.md](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/CONTRIBUTING.md#what-is-public-api).

A removal is first deprecated in a minor release with a one-time warning that
names the replacement, and happens in the next major.

## The Hash-key rule

Unchanged in 1.0, and now part of the SemVer contract: a plain Hash passed
through from the CLI's live stream (`usage`, `origin`, hook `tool_input`, the
`can_use_tool` input, SDK MCP tool `args`, `Client#mcp_status`) has **Symbol**
keys spelled as on the wire; a Hash read from a transcript or a `SessionStore`
(`SessionMessage#message`, `get_subagent_metadata`, store keys and entries) has
**String** keys. The wrong form reads `nil` rather than raising. See
[docs/types.md](docs/types.md#hash-keys).

## Deprecated, kept through 1.x

The ten store-specific session functions still work in 1.x and still print a
one-time warning. They will be removed in 2.0. Each is the same call as its
replacement:

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

`import_session_to_store` is not deprecated.
