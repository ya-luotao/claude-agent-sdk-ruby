# Subagent capabilities

This repository provides SDK capabilities and minimal usage examples. UI,
application status aggregation, event persistence, and recovery policy belong
to the consuming application, not this SDK.

## Available data and controls

| Capability | SDK surface | Contract |
|---|---|---|
| Define subagents | `ClaudeAgentOptions#agents`, `AgentDefinition` | Configure description, prompt, tools, model, and other agent options |
| Task lifecycle | `TaskStartedMessage`, `TaskProgressMessage`, `TaskUpdatedMessage`, `TaskNotificationMessage` | Task IDs identify tasks, including non-agent tasks; `task_type: 'local_agent'` identifies subagents |
| Activity and usage | Task progress / notification fields | Usage is cumulative, not a delta; optional fields depend on the CLI |
| Card fields | `TaskStartedMessage#subagent_type` / `#is_backgrounded` / `#spawn_depth`, `TaskProgressMessage#subagent_type` | All optional. `is_backgrounded` is tri-state: `true` background, `false` foreground (spawning tool call blocking), `nil` not reported |
| Display flags | `#skip_transcript` / `#ambient` on `TaskStartedMessage` and `TaskNotificationMessage` | Optional booleans (`nil` absent, `false` preserved). Hints for the host; the SDK never filters frames or computes activity |
| Progress summaries | `agent_progress_summaries: true`, `TaskProgressMessage#summary` | `true` requests model-generated one-line statuses for `local_agent` tasks; `summary` may then be present but stays optional. An enable switch, not a live toggle. Unset omits the key from `initialize` |
| Patch fields | `TaskUpdatedMessage#is_backgrounded` / `#error` / `#end_time` / `#total_paused_ms` / `#description` | Derived from `patch`; `nil` means "not in this patch", not a value. `is_backgrounded == true` is a move to the background |
| Settle details | `TaskNotificationMessage#reason` / `#resource_links` | `reason` is `'worker_restart'` or `nil`; `resource_links` is a raw Array for completed `mcp_task` tasks |
| Live background set | `BackgroundTasksChangedMessage#tasks` | Level signal with REPLACE semantics: swap your set for each payload. Background tasks only |
| Auto-denied tool calls | `PermissionDeniedMessage` | Advisory; `agent_id` routes a denial to a subagent. `ResultMessage#permission_denials` stays authoritative |
| Child output | `forward_subagent_text: true`, `AssistantMessage#parent_tool_use_id` | Forward child text/thinking; the parent tool ID identifies the spawning tool call |
| Agent identity | `SubagentStartHookInput`, `SubagentStopHookInput`, `get_subagent_metadata[_from_store]` | Metadata can link `agent_id` to `toolUseId`, `agentType`, `parentAgentId`, and `spawnDepth` |
| Historical transcripts | `list_subagents[_from_store]`, `get_subagent_messages[_from_store]` | Historical reads, not proof that an agent is currently alive |
| Background snapshots | `StopHookInput` / `SubagentStopHookInput` | Optional `background_tasks` and `session_crons`; `nil` means absent, `[]` means explicitly empty |
| Permissions | `can_use_tool`, `ToolPermissionContext` | `request_id`, `agent_id`, `tool_use_id`, and cooperative cancellation via `signal.cancelled?` / `signal.wait` |
| Hook cancellation | `HookContext#signal`, `HookContext#request_id` | Per-invocation cancellation on CLI cancel, disconnect, failure, or hook timeout; successful completion does not cancel |
| Stop a task | `Client#stop_task(task_id)` | Acknowledgement is not completion; observe a terminal event |
| Send to background | `Client#background_tasks(tool_use_id: nil)` | Keyed by the spawning `tool_use_id`, not `task_id` / `agent_id`. Targeted: returns `{ backgrounded: true }` or `{ backgrounded: false }` (a definitive miss). `nil`: every foreground task, returns `{}`. `''` / non-String raises `ArgumentError` |

Task updates expose raw statuses such as `pending`, `running`, `paused`,
`completed`, `failed`, and `killed`. Notifications use `completed`, `failed`,
and `stopped`. A terminal state can arrive through **either** event type;
`TERMINAL_TASK_STATUSES` covers both vocabularies. Receiving `paused` does not
imply a public per-agent pause/resume control exists.

### Foreground, background, and the live set

A subagent registered in the **foreground** reports `TaskStartedMessage#is_backgrounded`
as `false`: the spawning Agent tool call blocks the turn. Test `== false`, not
falsiness — `nil` means the CLI did not report the field (it is set only for
`local_agent` and `local_bash` tasks). A later move to the background does not
re-emit `task_started`; it arrives as a `TaskUpdatedMessage` whose
`is_backgrounded` is `true`. The patch readers (`is_backgrounded`, `error`,
`end_time`, `total_paused_ms`, `description`) mirror how `status` is derived: a
patch carries only what changed, so merge patches into your own task map instead
of reading one as the task's full state.

`Client#background_tasks` is the control-request equivalent of pressing Ctrl+B:
each targeted blocking tool call returns a "running in the background"
tool_result, the turn continues, and the task still emits a
`TaskNotificationMessage` when it settles.

```ruby
client.background_tasks                          # every foreground task => {}
client.background_tasks(tool_use_id: 'toolu_01') # one task => { backgrounded: true } or { backgrounded: false }
```

`tool_use_id` is the id of the `tool_use` block that **spawned** the task
(`TaskStartedMessage#tool_use_id`, or `AssistantMessage#parent_tool_use_id` on
forwarded child output) — not a `task_id` or `agent_id`.

- **Targeted** (`tool_use_id:` given): the reply is the outcome.
  `{ backgrounded: true }` means the matching foreground task was backgrounded.
  `{ backgrounded: false }` is a **definitive miss** — the CLI found no
  matching foreground task. Do not wait for an event after a miss.
- **All tasks** (`nil`, the explicit all-tasks form): the reply is `{}`, which
  says nothing about whether any foreground task existed.

Event observation — `TaskUpdatedMessage#is_backgrounded` and
`BackgroundTasksChangedMessage` — is for the lifecycle state that follows, not a
substitute for reading the targeted reply.

`tool_use_id` must be `nil` or a non-empty String; anything else raises
`ArgumentError` before a request is written. The CLI itself treats `''` as "all
tasks", so a selector built from a missing id (`started.tool_use_id.to_s`) would
release every blocking tool call — and `TaskStartedMessage#tool_use_id` is
optional on the wire. Never substitute `nil` or `''` for a per-card id you do
not have yet: disable the per-task control until a real id arrives.

`skip_transcript` and `ambient` (on `TaskStartedMessage` and
`TaskNotificationMessage`) are the CLI's display hints. `skip_transcript` marks
an ambient/housekeeping task: hide it from the inline transcript, though it may
still appear in a tasks panel. `ambient` marks tasks that are not activity —
every `skip_transcript` task plus every live-update watcher, requested or
auto-started — which hosts should exclude from activity indicators. Both are
`nil` when absent and keep an explicit `false`. The SDK surfaces every frame
regardless and computes no activity state from them.

`BackgroundTasksChangedMessage#tasks` is the full set of live **background**
tasks after a membership change, as raw symbol-keyed Hashes
(`{ task_id:, task_type:, description:, ambient: }`, `ambient` optional — `true`
marks housekeeping tasks to exclude from activity indicators). It is a level
signal with **REPLACE semantics**: replace your set with each payload rather
than pairing start/notification edges, so a missed edge cannot leave a stale
"running" badge. A frame is emitted on membership changes and also when an
entry's `ambient` flag flips. REPLACE alone does not prevent a stale badge; the
CLI's contract also says:

- Ordering relative to the edge frames is unspecified, so do not correlate the
  two streams.
- The level is per CLI process. Nothing is emitted at startup, so reset to the
  empty set whenever the process (re)starts — otherwise the previous process's
  last payload shows running work forever while the new one sits idle.
- `tasks: []` is an authoritative empty snapshot for that process.
- A repeated `initialize` on an already-running process is answered with a
  snapshot (even an empty one) right behind its success response; older CLIs
  may send nothing there. This SDK initializes once per connection.
- A foreground subagent is absent from the set until it is backgrounded.

The SDK does not consume this frame for its own bookkeeping, and does not
aggregate it into a status model.

`PermissionDeniedMessage` reports a tool call that was auto-denied without an
interactive prompt (`tool_name`, `tool_use_id`, `message`, and optionally
`agent_id`, `decision_reason_type`, `decision_reason`). It is a **best-effort
advisory, not a complete denial feed**: `ResultMessage#permission_denials` is
the authoritative record, and in rare races a booked denial has no frame or a
frame has no booked denial — do not derive badge counts or permission state
from it. Not covered at all: PreToolUse hook denies, deny-rule overrides of a
hook's allow/ask decision, Read/Edit/Write calls refused by a path-scoped deny
rule, and the MCP `--permission-prompt-tool` surface. `decision_reason_type` is
an open string (`'classifier'`, `'asyncAgent'`, `'mode'`, `'rule'` are
examples, not an enum), and `agent_id` is a subagent id for routing — not a
permission `request_id`. With a `can_use_tool` callback an "ask"
decision goes to the callback instead; without one nobody can answer it, so that
implicit denial is reported here too.

`TaskNotificationMessage#resource_links` passes the CLI's array through
untouched: symbol-keyed Hashes with the wire spelling preserved — `:uri` and
`:name` always, plus optional `:title`, `:description`, `:mimeType`, `:size` (a
number, not necessarily an integer) and `:annotations`. Elements carry no
`type: 'resource_link'` discriminator. The CLI describes its output as at most
50 links / 64 KiB; that is a producer-side note the SDK does not enforce.

Other frames the CLI marks internal (`agents_killed`, `task_summary`, and
`permission_denied`'s `decision_reason_code`) arrive as a generic
`SystemMessage` / through `#data` with no stability promise.

**Provenance.** The fields, messages, control request, and option in this
section were read from the schema embedded in Claude Code CLI 2.1.278. They are
covered by protocol unit tests, but only partly verified against a live CLI: a
smoke run against 2.1.278 confirmed `task_started`'s `subagent_type` /
`is_backgrounded` / `spawn_depth` and the `{ backgrounded: false }` answer to a
targeted miss. Actually backgrounding a task, `background_tasks_changed` and
`permission_denied` frames, and progress summaries are schema-derived only.
Every new reader is `nil` whenever the CLI does not send its field. The
Python SDK exposes none of them as of Python SDK 0.2.153.

`task_id`, `agent_id`, and `tool_use_id` are different identifiers. The metadata
field `toolUseId` links an agent to its spawning tool call, not to an inner tool
call awaiting permission. Metadata may be unavailable at the start hook; retry
on later events or history reads. See [metadata APIs](sessions.md#reading-subagent-metadata).

Both Stop snapshots describe the **parent session's background work**, even on
SubagentStop. They are not a complete agent registry, and absence from a snapshot
does not establish completion. A SubagentStop hook can itself prevent stopping.
See [hook fields and permission cancellation](hooks-and-permissions.md).

## Minimal example

[`examples/subagent_status_example.rb`](../examples/subagent_status_example.rb)
defines a tool-free reviewer, registers lifecycle hooks, reads metadata, and
prints task events and forwarded child text without building a status model:

```sh
bundle exec ruby examples/subagent_status_example.rb
```

It requires an authenticated Claude Code CLI and makes a real model request.
The example limits the parent to the Agent tool and gives the reviewer no tools.
Events and optional metadata depend on the CLI version and actual execution;
not every run emits every event type. Output can contain prompts and transcripts.

The example reads with `Client#receive_messages` for a bounded 60-second window,
then disconnects. `receive_response` stops at the next parent result, which is
not the end of background work. The demo deadline is not a task status. Use the
store-backed metadata API when the CLI filesystem is remote; see
[permission cancellation](hooks-and-permissions.md#permission-request-cancellation)
for a minimal cancellation-aware callback wait.

The SDK does not provide an authoritative live-agent registry, a UI status
machine, or direct per-agent pause/resume controls. Reading metadata or restoring
transcripts does not reconnect to a running subagent.

## CLI contract checks

The real-CLI suite includes subagent ID/metadata/text correlation, permission
cancellation on interrupt, and background completion/stop after a parent result:

```sh
RUN_INTEGRATION=1 bundle exec rspec spec/integration/real_cli_integration_spec.rb --example 'subagent contracts'
```

These checks use disposable settings/transcripts and cap each run at $0.50 and
120 seconds. They require `claude` on PATH and `ANTHROPIC_API_KEY`; without either
they are **skipped**, not verified. They exercise the installed CLI, not every
supported CLI version. Protocol unit tests cover both callback scheduling modes
and terminal event variants deterministically.
