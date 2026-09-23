# Session Browsing & Mutations

Browse, read, mutate, fork, and resume Claude Code sessions directly from Ruby — no CLI subprocess required. These APIs read and write `~/.claude/projects/` JSONL files directly, respecting the `CLAUDE_CONFIG_DIR` environment variable (an empty value is treated as unset, falling back to `~/.claude`) and auto-detecting git worktrees.

Not-found semantics: the read APIs return `[]`/`nil` for unknown sessions and for directories that do not exist or have no recorded sessions. An explicit `directory:` strictly scopes the search to that project and its git worktrees — there is no cross-project fallback (pass `directory: nil` to search all projects). 0-byte transcript stubs are skipped during session-file resolution. Ids are validated at the boundary: a `session_id` that is not a UUID String, or an `agent_id` that is not a String of `[A-Za-z0-9._-]` characters (or is `.`/`..`), gets the same `[]`/`nil` as an unknown session (`import_session_to_store` raises `ArgumentError`), on the disk and store readers alike.

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

Listings are newest first; sessions with the same `last_modified` are ordered by `session_id`, so `offset:`/`limit:` pages are stable across calls and the disk and store listings order identically. Blank (empty or whitespace-only) custom/AI titles, last-prompt and summary entries, `git_branch`, `cwd`, and `tag` values read as absent on both paths (a blank `cwd` falls back to the project path).

## Reading Session Messages

```ruby
# Full conversation
messages = ClaudeAgentSDK.get_session_messages(session_id: 'abc-123-...')
messages.each { |msg| puts "[#{msg.type}] #{msg.message}" }

# Paginate
ClaudeAgentSDK.get_session_messages(session_id: 'abc-123-...', offset: 10, limit: 20)
```

Each `SessionMessage` includes `type` (`"user"` or `"assistant"`), `uuid`, `session_id`, and `message` (raw API hash).

## Reading Subagent Transcripts

Subagent transcripts live at `<projectDir>/<sessionId>/subagents/agent-<id>.jsonl` and may nest under `workflows/<runId>/`:

```ruby
ids = ClaudeAgentSDK.list_subagents(session_id: "uuid-here", directory: "/path/to/project")
messages = ClaudeAgentSDK.get_subagent_messages(session_id: "uuid-here", agent_id: ids.first, limit: 50)
```

With `directory:` given, only that project and its git worktrees are searched (no global fallback). Store-backed counterparts: `list_subagents_from_store` / `get_subagent_messages_from_store`.

> Each returned `SessionMessage` carries `parent_tool_use_id` — the id of the Agent `tool_use` block in the parent session that spawned this subagent — and `parent_agent_id`, the spawning subagent's id for nested subagents. Both are read from the `agent-<id>.meta.json` sidecar beside the transcript (or the `agent_metadata` entry in a `SessionStore`), and are `nil` when it is missing or unusable.

### Reading Subagent Metadata

```ruby
meta = ClaudeAgentSDK.get_subagent_metadata(session_id: session_id, agent_id: agent_id, directory: project)
meta = ClaudeAgentSDK.get_subagent_metadata_from_store(
  session_store: store, session_id: session_id, agent_id: agent_id, directory: project
)
meta&.dig('toolUseId')    # spawning Agent tool call; not task_id
meta&.dig('parentAgentId')
meta&.dig('agentType')
meta&.dig('spawnDepth')
```

Returns a **string-keyed Hash with the original CLI field spelling**, preserving
unknown fields. All fields are optional. `nil` means unavailable; `{}` is a valid
empty sidecar. The disk reader uses the same project/worktree scope and sorted
first-match rule as `get_subagent_messages`, but does not parse the transcript.
It locates the sidecar beside `agent-<id>.jsonl`, so it returns `nil` until that
transcript file exists, even if the sidecar has already been written.
Missing, unreadable, non-regular, corrupt, or invalid-UTF-8 sidecars return `nil`.

The store reader resolves nested subpaths with `list_subkeys` when available,
otherwise tries the direct path. It returns the **last** `agent_metadata` entry
without the synthetic `type` marker, even before any conversation messages have
arrived. Adapter errors propagate, like other store reads. These APIs do not
return live status, and reading metadata does not resume an agent. See
[subagent capabilities](subagents.md) for correlating metadata with events.

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

> Session mutations use append-only JSONL writes with `O_WRONLY | O_APPEND` (no `O_CREAT`) for TOCTOU safety. They are safe to call while the session is open in a CLI process. `fork_session` writes and closes a private staging file before atomically publishing it with a hard link, so partial forks are not discoverable and existing sessions are never overwritten. The project filesystem must support hard links; publication failures leave the source and any existing destination untouched.

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

### Validating what the truncation discards

A bare `resume_session_at` silently drops everything after the fork point —
including a queued user message or a task notification the session absorbed
mid-turn that you never observed. `resume_drops_turn` names the user prompt
whose turn you *intend* to discard, and the CLI refuses the resume if anything
past the fork point is not attributable to that turn:

```ruby
ClaudeAgentSDK.query(
  prompt: 'try a different approach',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(
    resume: session_id,
    resume_session_at: last_kept_entry_uuid,
    resume_drops_turn: discarded_prompt_uuid
  )
) { |m| handle(m) }
```

Rule of thumb: set `resume_session_at` to the **last transcript entry of the
turn you are keeping** (whatever its type), and `resume_drops_turn` to the
prompt UUID of the turn immediately after it — the next `SessionMessage` with
`type == 'user'` from `get_session_messages`, or the `uuid` you supplied on a
streamed user message.

With structured output (`output_format`) or end-turn MCP tools, a kept turn
ends on entries *after* its last assistant message, so forking at the assistant
UUID is refused by design.

A refusal surfaces as a `ResultError` whose message contains
`Resume rejected by --resume-drops-turn:`. Treat it as **deterministic** —
clear the pending fork target and resume plainly; do not retry the same
request. Leave `resume_drops_turn` unset to keep the unvalidated behavior.

Unlike `resume_session_at`, the SDK applies no combination validation to
`resume_drops_turn` and defers entirely to the CLI. An empty string is
forwarded rather than dropped, so the CLI rejects it as a malformed
declaration instead of the SDK silently disarming a guard you believe is
armed.

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

> **Store-backed resume runs against a temp `CLAUDE_CONFIG_DIR`.** The SDK
> materializes the session transcript (plus subagent transcripts, when the
> store implements `#list_subkeys`) into it and seeds it from your real config
> dir (`CLAUDE_CONFIG_DIR` from `options.env`/`ENV`, else `~/.claude`):
>
> - `.credentials.json`, with the OAuth `refreshToken` removed so the resumed
>   subprocess can't consume it. On macOS with the default config dir and no
>   `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN`, the credentials come from
>   the Keychain entry when one exists (the redirected config dir would
>   otherwise miss it).
> - `.claude.json` (from `$CLAUDE_CONFIG_DIR/.claude.json` when set, else
>   `~/.claude.json`).
> - User `settings.json` and `cowork_settings.json` — so `apiKeyHelper`, `env`,
>   hooks and `permissions` still apply — minus `enabledPlugins`,
>   `extraKnownMarketplaces` and `env.CLAUDE_CONFIG_DIR`, which would misbehave
>   under the redirected config dir (plugin declarations would re-install every
>   declared marketplace on each resume).
>
> Everything else in your config dir is **not** visible to the subprocess —
> notably user `CLAUDE.md`, `agents/`, `skills/`, and `plugins/` (so, with the
> plugin keys stripped, user plugins are off) — so a store-backed resume can
> still behave differently from a plain `resume:` of the same session.
> Project-level `.claude/*` still applies (it resolves from `cwd`), and
> hooks/options passed programmatically via `ClaudeAgentOptions` are unaffected.
> Seeded files are written owner-only (`0600`); a missing source file is simply
> skipped.
>
> The temp dir is deleted at disconnect — **unless the mirror dropped batches**
> (terminal append failures — timeouts immediately, other failures after up to
> three attempts — surfaced as `MirrorErrorMessage`):
> the store copy is then incomplete and the temp dir holds the only copy of the
> dropped turns, so the SDK scrubs the credential copies, keeps the transcripts,
> and warns with the preserved path so you can import them into the store.

### Implementing an adapter

Subclass `ClaudeAgentSDK::SessionStore` (or duck-type it). Only `#append` and
`#load` are required; `#list_sessions`, `#delete`, `#list_subkeys`, and
`#list_session_summaries` are optional and probed via `SessionStore.implements?`.
Report `mtime` as epoch milliseconds; the SDK also orders numeric-string and
ISO-8601-string mtimes correctly, but anything else sorts as oldest. Subagent
transcripts arrive under a `subpath` key such as `subagents/agent-<agent_id>`
(or nested `subagents/workflows/<runId>/agent-<agent_id>`); on a store without
`#list_subkeys` the subagent readers build `subagents/agent-<agent_id>` from the
caller's `agent_id`, which the SDK first restricts to `[A-Za-z0-9._-]+`
(never `.`/`..`), so a path- or prefix-keyed adapter cannot be re-routed by it.
Validate your adapter with the shipped, framework-agnostic conformance harness:

```ruby
require 'claude_agent_sdk/testing/session_store_conformance'
ClaudeAgentSDK::Testing.run_session_store_conformance(-> { MyStore.new(...) })
```

Copy-in reference adapters for **S3, Redis, and Postgres** live in
[`examples/session_stores/`](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/session_stores/README.md), each with a
production checklist.

#### Fiber-native adapters

By default the SDK runs every timeout-bounded adapter call (`#append` from the
mirror batcher, `#load` and friends during resume materialization) on a
throwaway thread with a hard `Thread#join` timeout, so a wedged adapter can
never stall the reactor. An adapter whose IO is **entirely
Fiber-scheduler-aware** (e.g. built on `async`-native clients) can opt out of
the thread hop by declaring it:

```ruby
class MyAsyncStore
  def callback_scheduling = :inline
  # append/load ...
end
```

Declaring `:inline` means the calls run in place on the reactor fiber under a
**cooperative** timeout. Three consequences to understand before opting in:

- The declaration covers **every method the SDK invokes on the adapter** —
  `append`, `load`, `list_sessions`, `list_session_summaries`,
  `list_subkeys` — not just append/load: resume materialization runs the
  listing calls inline too. **All** blocking inside all of them must yield to
  the scheduler. Scheduler-opaque blocking (CPU-bound work, GVL-holding C
  extensions, native drivers the scheduler can't see) stalls every job on
  that worker **and** the cooperative timeout cannot fire while it blocks.
- Cancellation semantics change: a timed-out call is interrupted at its next
  suspension point and its `ensure` blocks run, instead of being abandoned on
  a thread. The cancellation reaches only the adapter's **own fiber** — work
  the adapter offloaded (descendant tasks, an already-issued remote write)
  may still land afterwards. Timed-out appends are therefore **not retried**
  (same as thread mode; a retry would race that still-landing work), and the
  interrupted append may remain permanently **half-applied** in the store.
  The drop is surfaced like every dropped batch — `MirrorErrorMessage` on
  the stream, `batches_dropped?` on the batcher — and the local transcript
  remains the source of truth, so nothing is lost from the session itself.
- The timeout bounds the cancellation **request**, not the call's
  completion: the cancellation is delivered once, at the next suspension
  point, and the adapter's `ensure` / rescue cleanup then runs unbounded on
  the reactor fiber before the timeout is reported. Fiber-aware cleanup
  (closing an async client, releasing an async lock) delays only that call;
  scheduler-opaque cleanup — an `fsync`, a non-fiber-aware driver's
  disconnect, a GVL-holding C extension — stalls the whole reactor for its
  duration, and no deadline can interrupt it. Keep inline cleanup
  fiber-aware, or leave the adapter on the default thread hop when a hard
  bound on the whole call matters more than fiber affinity.

Anything other than `:thread`/`:inline` raises `ArgumentError` when the
session is set up; without a reactor the hard thread-hop bound still applies
even for declared adapters. To opt in a third-party fiber-native adapter you
don't own: `def store.callback_scheduling = :inline` (singleton method).

A session-configured `callback_wrapper` (see docs/rails.md) composes around
every one of these adapter calls, inside the timeout bound — on the worker
thread for default adapters, inside the cooperative timeout for inline
declarers (the cancellation passes through the wrapper un-swallowed and the
wrapper's `ensure` runs at cancellation).

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
