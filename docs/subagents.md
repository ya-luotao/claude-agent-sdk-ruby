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
| Child output | `forward_subagent_text: true`, `AssistantMessage#parent_tool_use_id` | Forward child text/thinking; the parent tool ID identifies the spawning tool call |
| Agent identity | `SubagentStartHookInput`, `SubagentStopHookInput`, `get_subagent_metadata[_from_store]` | Metadata can link `agent_id` to `toolUseId`, `agentType`, `parentAgentId`, and `spawnDepth` |
| Historical transcripts | `list_subagents[_from_store]`, `get_subagent_messages[_from_store]` | Historical reads, not proof that an agent is currently alive |
| Background snapshots | `StopHookInput` / `SubagentStopHookInput` | Optional `background_tasks` and `session_crons`; `nil` means absent, `[]` means explicitly empty |
| Permissions | `can_use_tool`, `ToolPermissionContext` | `request_id`, `agent_id`, `tool_use_id`, and cooperative cancellation via `signal.cancelled?` / `signal.wait` |
| Hook cancellation | `HookContext#signal`, `HookContext#request_id` | Per-invocation cancellation on CLI cancel, disconnect, failure, or hook timeout; successful completion does not cancel |
| Stop a task | `Client#stop_task(task_id)` | Acknowledgement is not completion; observe a terminal event |

Task updates expose raw statuses such as `pending`, `running`, `paused`,
`completed`, `failed`, and `killed`. Notifications use `completed`, `failed`,
and `stopped`. A terminal state can arrive through **either** event type;
`TERMINAL_TASK_STATUSES` covers both vocabularies. Receiving `paused` does not
imply a public per-agent pause/resume control exists.

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
