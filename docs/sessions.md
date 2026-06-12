# Session Browsing & Mutations

Browse, read, mutate, fork, and resume Claude Code sessions directly from Ruby — no CLI subprocess required. These APIs read and write `~/.claude/projects/` JSONL files directly, respecting the `CLAUDE_CONFIG_DIR` environment variable (an empty value is treated as unset, falling back to `~/.claude`) and auto-detecting git worktrees.

Not-found semantics: the read APIs return `[]`/`nil` for unknown sessions and for directories that do not exist or have no recorded sessions. An explicit `directory:` strictly scopes the search to that project and its git worktrees — there is no cross-project fallback (pass `directory: nil` to search all projects). 0-byte transcript stubs are skipped during session-file resolution.

## Listing Sessions

```ruby
# All sessions (sorted by most recent first)
sessions = ClaudeAgentSDK.list_sessions
sessions.each do |session|
  puts "#{session.session_id}: #{session.summary} (#{session.git_branch})"
end

# For a specific directory
ClaudeAgentSDK.list_sessions(directory: '/path/to/project', limit: 10)

# Paginate with offset
ClaudeAgentSDK.list_sessions(directory: '.', limit: 10, offset: 10)

# Include git worktree sessions
ClaudeAgentSDK.list_sessions(directory: '.', include_worktrees: true)
```

Each `SDKSessionInfo` includes: `session_id`, `summary`, `last_modified`, `file_size`, `custom_title`, `first_prompt`, `git_branch`, `cwd`, `tag`, `created_at`.

## Reading Session Messages

```ruby
# Full conversation
messages = ClaudeAgentSDK.get_session_messages(session_id: 'abc-123-...')
messages.each { |msg| puts "[#{msg.type}] #{msg.message}" }

# Paginate
ClaudeAgentSDK.get_session_messages(session_id: 'abc-123-...', offset: 10, limit: 20)
```

Each `SessionMessage` includes `type` (`"user"` or `"assistant"`), `uuid`, `session_id`, and `message` (raw API hash).

## Renaming a Session

```ruby
ClaudeAgentSDK.rename_session(
  session_id: '550e8400-e29b-41d4-a716-446655440000',
  title: 'My refactoring session',
  directory: '/path/to/project'  # optional
)
```

## Tagging a Session

```ruby
ClaudeAgentSDK.tag_session(session_id: '550e8400-...', tag: 'experiment')
ClaudeAgentSDK.tag_session(session_id: '550e8400-...', tag: nil)  # clear
```

Tags are Unicode-sanitized before storing.

## Deleting a Session

```ruby
# Hard-delete (removes the JSONL file permanently)
ClaudeAgentSDK.delete_session(
  session_id: '550e8400-...',
  directory: '/path/to/project'  # optional
)
```

## Forking a Session

```ruby
# Fork into a new branch with fresh UUIDs
result = ClaudeAgentSDK.fork_session(
  session_id: '550e8400-...',
  title: 'Experiment branch'  # optional, auto-generated if omitted
)
puts result.session_id  # UUID of the new forked session

# Partial fork — fork up to a specific message
ClaudeAgentSDK.fork_session(
  session_id: '550e8400-...',
  up_to_message_id: 'message-uuid-here'
)
```

> Session mutations use append-only JSONL writes with `O_WRONLY | O_APPEND` (no `O_CREAT`) for TOCTOU safety. They are safe to call while the session is open in a CLI process. `fork_session` uses `O_CREAT | O_EXCL` to prevent race conditions.

## Resuming at a Specific Message

`resume_session_at` truncates the resumed conversation to messages up to **and including** the assistant message with the given UUID — useful for rewriting history from a known point or branching exploration without forking the session file. The flag rides on top of `resume`, so the original session ID is preserved; only the in-memory history loaded for the new turn is shortened.

```ruby
ClaudeAgentSDK.query(
  prompt: 'Try a different approach',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(
    resume: '550e8400-...',
    resume_session_at: 'assistant-message-uuid-from-history'
  )
) { |message| }
```

`resume_session_at` requires `resume`; the SDK raises `ArgumentError` from `CommandBuilder` when this constraint is violated, matching the underlying CLI's validation but surfacing it synchronously in the caller's stack.

## Mirroring to a `SessionStore`

By default Claude Code writes session transcripts to local disk under
`CLAUDE_CONFIG_DIR`. A **`SessionStore`** adapter mirrors that transcript to
external storage (S3, Redis, Postgres, …) so sessions survive beyond the local
machine and can be resumed elsewhere. The subprocess still writes locally; the
adapter receives a secondary copy and resume can rehydrate from it.

Set `session_store:` on the options — it works on **both** `ClaudeAgentSDK.query`
and `ClaudeAgentSDK::Client`:

```ruby
store = ClaudeAgentSDK::InMemorySessionStore.new # or your own adapter

ClaudeAgentSDK.query(
  prompt: 'Hello!',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store)
) { |message| } # transcript_mirror frames are appended to the store as they stream

# Resume later from the store (no local JSONL needed):
ClaudeAgentSDK.query(
  prompt: 'Continue',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: 'previous-session-id')
) { |message| }
```

Relevant options: `session_store`, `session_store_flush` (`"batched"` default, or
`"eager"` to flush after every frame), and `load_timeout_ms` (per store call
during resume materialization, default `60_000`).

> **Store-backed resume runs against a bare temp `CLAUDE_CONFIG_DIR`.** Only the
> transcript plus `.credentials.json` (redacted) and `.claude.json` are
> materialized into it — user-scope `settings.json` (hooks, `permissions`),
> user `CLAUDE.md`, `agents/`, `skills/`, and `plugins/` from your real config
> dir are **not** visible to the subprocess, so a store-backed resume can
> behave differently from a plain `resume:` of the same session. Project-level
> `.claude/*` still applies (it resolves from `cwd`), and hooks/options passed
> programmatically via `ClaudeAgentOptions` are unaffected. This matches the
> Python and TypeScript SDKs.

### Implementing an adapter

Subclass `ClaudeAgentSDK::SessionStore` (or duck-type it). Only `#append` and
`#load` are required; `#list_sessions`, `#delete`, `#list_subkeys`, and
`#list_session_summaries` are optional and probed via `SessionStore.implements?`.
Validate your adapter with the shipped, framework-agnostic conformance harness:

```ruby
require 'claude_agent_sdk/testing/session_store_conformance'
ClaudeAgentSDK::Testing.run_session_store_conformance(-> { MyStore.new(...) })
```

Copy-in reference adapters for **S3, Redis, and Postgres** live in
[`examples/session_stores/`](../examples/session_stores/README.md), each with a
production checklist.

### Store-backed helpers

The browsing/mutation helpers above have store-backed counterparts that take a
`session_store:` and operate on the store instead of local disk:

- Reads: `list_sessions_from_store`, `get_session_info_from_store`,
  `get_session_messages_from_store`, `list_subagents_from_store`,
  `get_subagent_messages_from_store`. Unlike the disk readers (where a nil
  `directory:` searches every project directory), the store helpers key every
  read by `project_key` and a nil `directory:` defaults to the **current
  working directory** — the `SessionStore` interface has no way to enumerate
  project keys (parity with the Python SDK).
- Mutations: `rename_session_via_store`, `tag_session_via_store`,
  `delete_session_via_store` (a no-op on append-only stores without `#delete`),
  `fork_session_via_store`.
- Migration: `import_session_to_store` replays a local on-disk session (and its
  subagents) into a store.

```ruby
ClaudeAgentSDK.rename_session_via_store(session_store: store, session_id: '550e8400-...', title: 'Renamed')
forked = ClaudeAgentSDK.fork_session_via_store(session_store: store, session_id: '550e8400-...')
```
