# Session Browsing & Mutations

Browse, read, mutate, fork, and resume Claude Code sessions directly from Ruby — no CLI subprocess required. These APIs read and write `~/.claude/projects/` JSONL files directly, respecting the `CLAUDE_CONFIG_DIR` environment variable and auto-detecting git worktrees.

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

Each `SDKSessionInfo` includes: `session_id`, `summary`, `last_modified`, `file_size`, `custom_title`, `first_prompt`, `git_branch`, `cwd`.

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
