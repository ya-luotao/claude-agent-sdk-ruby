# Rails Integration

The gem ships a Railtie, an install generator and a rake task for vendoring the CLI; the rest of this page covers how SDK callbacks interact with Rails' threading, executor and fiber workers, and the common job / ActionCable patterns.

## Getting started

1. Add the gem:

   ```bash
   bundle add claude-agent-sdk
   ```

2. Generate the initializer:

   ```bash
   bin/rails generate claude_agent_sdk:install
   ```

   This writes `config/initializers/claude_agent_sdk.rb` — a `ClaudeAgentSDK.configure` block with commented defaults (model, permission mode, CLI path, [per-user isolation](#per-user-isolation), OpenTelemetry) and the Rails callback wrapper [described below](#rails-executor-around-callbacks-callback_wrapper) switched on — and adds `/vendor/claude/` to `.gitignore`.

3. Vendor the Claude Code CLI:

   ```bash
   bin/rails claude_agent_sdk:install_cli                  # the version this gem release is tested with
   bin/rails claude_agent_sdk:install_cli CLAUDE_CLI_VERSION=x.y.z    # or a version of your own ('stable' / 'latest' float)
   ```

   The binary lands in `Rails.root/vendor/claude`, where the SDK finds it ahead of any `claude` on `PATH`. That holds whatever the process's working directory is (a daemonized worker, a job runner started elsewhere): the Railtie points `ClaudeAgentSDK::CLIInstaller.root` at `Rails.root` during boot, before `config/initializers` run, so an initializer can still set a different root, and a root already set in `config/application.rb` is kept. The task does not boot the app (no database or credentials needed), so the same line works as a cached Docker build step: `RUN bin/rails claude_agent_sdk:install_cli`. For the same reason the task never sees a root set in `config/initializers`; if you move the CLI elsewhere, set `CLIInstaller.root` in `config/application.rb`, which both the task and discovery honour. Installs are checksum-verified and idempotent — see [docs/cli-installer.md](cli-installer.md). The CLI authenticates from the environment, e.g. `ANTHROPIC_API_KEY`.

4. Run an agent from a job:

   ```ruby
   # app/jobs/summarize_ticket_job.rb
   class SummarizeTicketJob < ApplicationJob
     def perform(ticket)
       options = ClaudeAgentSDK::ClaudeAgentOptions.new(
         tools: [], max_turns: 1,                            # text only, no built-in tools
         env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }   # see "Per-user isolation"
       )
       prompt = "Summarize this support ticket in two sentences:\n\n#{ticket.body}"

       ClaudeAgentSDK.query(prompt: prompt, options: options) do |message|
         ticket.update!(summary: message.result) if message.is_a?(ClaudeAgentSDK::ResultMessage)
       end
     end
   end
   ```

   The block runs on a plain thread (see the next section), so ActiveRecord calls inside it are safe. It is a thread of its own, though: the job's `Current` attributes, time zone, log tags and database role or shard are not set there — see [Request state does not follow into callbacks](#request-state-does-not-follow-into-callbacks). For multi-turn sessions, hooks, custom tools and interrupts use `ClaudeAgentSDK::Client.open` — see [ActionCable streaming](#actioncable-streaming) below.

## Thread-keyed libraries are safe inside SDK callbacks

The SDK depends on [`async`](https://github.com/socketry/async), which installs a Fiber scheduler that multiplexes fibers onto a single OS thread and intercepts IO so blocking calls yield to siblings. Most mature Ruby libraries are thread-safe but not fiber-safe — they key state (checked-out DB connections, per-thread caches, request stores) on `Thread.current`. When the scheduler interleaves two fibers on one thread, those fibers share the same state slot, and interleaved IO on a shared connection silently corrupts wire protocols. This affects every DB driver keyed by thread (`pg`, `mysql2`, `sqlite3`), ActiveRecord's connection pool, and HTTP/cache clients pooled per thread.

The SDK keeps your callbacks out of this. By default (`callback_scheduling: :thread`; see the fiber-workers section below for the opt-in alternative) it hops to a plain thread at every user-callback boundary — message blocks given to `query` / `Client`, SDK MCP tool handlers, hooks, permission callbacks, and observer methods — so your code runs with no Fiber scheduler active, and thread-keyed libraries behave there as they do on any other thread:

```ruby
tool = ClaudeAgentSDK.create_tool('lookup_user', 'Look up a user', { id: Integer }) do |args|
  User.find(args[:id]).name                  # a connection of this thread's own: safe
end

ClaudeAgentSDK.query(prompt: '...') do |message|
  Message.create!(role: 'assistant', body: message.to_s)   # likewise
end
```

That thread is a new one, not the thread that called the SDK. The connection pool does not mind; everything Rails keeps for the current request or job does — `Current` attributes, `Time.zone`, log tags, the database role and shard are all back at their defaults inside a callback, and the callback is outside the caller's transaction. Read [Request state does not follow into callbacks](#request-state-does-not-follow-into-callbacks) and [Transactions and the connection pool](#transactions-and-the-connection-pool) before a callback touches anything scoped to the request.

The trade-off: because callbacks run on a plain thread rather than inside an `Async::Task`, fiber-specific primitives aren't available to them — `Async::Task.current` will raise "No async task available". If a callback wants cooperative concurrency it should open its own `Async { }` block. In practice, callbacks typically do some Ruby work, call external services, and return — so this rarely matters. If you wrap your own call site in an outer `Async { }` block, the scheduler is visible to your code again; you've opted in, and whatever fiber-safety rules your app uses apply there.

### Rails executor around callbacks: `callback_wrapper`

One consequence of the thread hop: an ActiveRecord connection implicitly checked out inside a callback belongs to that throwaway thread and stays stranded until the pool reaper reclaims it. Rails' own answer to "code running on a thread Rails didn't create" is the executor — and `callback_wrapper` lets you install it around every user-callback dispatch. Use the SDK's Rails-aware wrapper (the generated initializer already does):

```ruby
ClaudeAgentSDK.configure do |config|
  config.default_options = {
    callback_wrapper: ClaudeAgentSDK::Railtie.callback_wrapper
  }
end
```

It runs each callback inside the Rails executor — except where that would deadlock, which is why it replaces the bare `->(invocation) { Rails.application.executor.wrap { invocation.call } }` this guide used to recommend:

- **Development (code reloading enabled).** Every executor then holds a share of the code-reload interlock. The request or job calling the SDK is already inside the executor, and in `:thread` mode it waits for the callback's thread. If a reload is requested meanwhile (say, another request arrives after the agent edited an app file), the reloader queues for the exclusive unload lock, and a callback thread entering `executor.wrap` queues behind it for a fresh share — which the reloader can never let through while the waiting caller holds its own. Everything hangs. The helper instead runs the callback without entering the executor (the caller's share still keeps code from being unloaded under it) and returns the thread's ActiveRecord connections to the pool when the callback finishes. The executor's other per-run hooks (query cache, `CurrentAttributes` reset) do not run for callbacks in this case.
- **`config.allow_concurrency = false`.** The executor holds a process-wide monitor that the calling thread already owns, so a callback thread's `executor.wrap` would block every time; same treatment.
- **Already inside the executor** — a callback that runs on the caller's own fiber, which under `:inline` scheduling is a `Client`'s message block and observers: it runs straight through, leaving cleanup to the enclosing executor. The other `:inline` callbacks run on fibers of their own, where under fiber isolation the executor is not active; they take one of the other paths.

Everywhere else — production, with no reloading — the callback runs inside the executor: its run hooks before the callback and its complete hooks after it, also when the callback raises. The configuration is read per call, so one initializer is correct in every environment.

**Development: an agent run still holds the reload lock.** The helper removes the deadlock, not the wait. A request or in-process job that runs an agent stays inside the executor, with its share of the interlock, until the run returns. Once a file changes — an agent editing your app does that — the next request asks to reload, the reloader waits for that share, and every other request waits behind the reloader. Rails treats any long request this way; it is not specific to the SDK. In development, run agent jobs in a separate process (`bin/jobs`, Sidekiq) rather than in a controller action or the in-process `:async` adapter, and point an agent that edits code at a different checkout than the one the server runs from. To see who is waiting for whom, add `config.middleware.insert_before Rack::Sendfile, ActionDispatch::DebugLocks` and open `/rails/locks`.

**Errors and `Rails.error`.** The wrapper reports nothing to `Rails.error` itself, which is the one difference from `executor.wrap` (that reports whatever passes through it as an unhandled error). What your error tracker sees is therefore decided by where an exception ends up:

- An exception that escapes a callback — one raised in a message block, say — comes out of `query` / `receive_response` on the thread that called the SDK. It is reported there, once, with that thread's context, by whatever runs the code inside the executor: the request middleware for a controller action, ActiveJob for a job a queue worker runs (`perform_later`). A `perform_now` called outside any executor — from a script or a console — raises it to its caller and reports nothing by itself.
- A failure the SDK handles is not reported: an exception in a hook or `can_use_tool` is answered to the CLI as an error response, one in an SDK MCP tool handler becomes an error result the model sees, one in an observer is swallowed, and a timed-out or cancelled callback is cancellation, not an error. To track these, report them where they happen: `rescue` inside the callback, call `Rails.error.report(e, handled: true)`, and re-raise.

Writing your own wrapper: it is a callable receiving a zero-arg `invocation`; it must call it and return its value. It runs on the **same execution context as the callback** — inside the worker thread in `:thread` mode, which is the whole point: the executor runs on the thread that touches ActiveRecord, so connections check back in when the callback ends. Exceptions from the callback propagate through the wrapper unchanged (don't rescue them); `ensure`-based wrappers are safe, including around a `break` from a message block.

Beyond the executor, this is a generic hook: APM spans, logging context, per-request state. To combine a wrapper of your own with the Rails one, call the Rails one from yours — and mind which side of that call your code is on. In production `rails.call` enters the Rails executor, and the executor starts every execution from a clean slate: on the way in it resets `CurrentAttributes` and the error context (`Rails.error.set_context`).

```ruby
rails = ClaudeAgentSDK::Railtie.callback_wrapper

# What only has to surround the callback can stay outside:
->(invocation) { MyApm.trace('agent.callback') { rails.call(invocation) } }

# State that Rails resets per execution is set inside:
->(invocation) { rails.call(-> { Current.set(account: account) { invocation.call } }) }

# Not around it. This loses Current.account in every callback, in production only:
->(invocation) { Current.set(account: account) { rails.call(invocation) } }
```

The last form is a trap because it works in development, where the Rails wrapper stays out of the executor (see above), and because the loss looks selective: `Time.zone`, log tags and `connected_to` are not reset by the executor and survive on either side. `Current.set` does not carry the error context either; that needs `ActiveSupport::ExecutionContext.set`. The [recipe below](#carrying-the-callers-state-into-callbacks) puts all of it in the right place, and `spec/rails/callback_wrapper_composition_spec.rb` pins this rule against the executor hooks of both supported Rails versions.

The wrapper also composes around every timeout-bounded `SessionStore` adapter call (mirror-batcher appends, resume-materialization loads and listings), inside the timeout bound — so an ActiveRecord-backed store adapter gets the same connection hygiene as your callbacks.

When do you want this vs `callback_scheduling: :inline`? `callback_wrapper` + default `:thread` mode is the right choice for ordinary threaded hosts (Puma, threaded Sidekiq/solid_queue): it fixes connection hygiene without any fiber-isolation precondition. `:inline` is only for hosts that are fiber-isolated end to end (solid_queue fiber workers with `isolation_level = :fiber`); there the wrapper still applies — it simply runs in place on the reactor fiber.

## Request state does not follow into callbacks

A callback is written inside your controller action or job, a few lines below its `Current.set` or `connected_to` block — but it does not run there. It runs on a thread the SDK starts for it (the default `:thread` scheduling) or on a fiber of the SDK's reactor (`:inline`), and Rails keeps what belongs to the current request or job per thread or per fiber. A thread or fiber Rails never set up reads all of it as the default:

| Set on the caller | What a callback sees |
| --- | --- |
| `Current.user = alice` (any `ActiveSupport::CurrentAttributes`) | `nil` |
| `Time.zone = "Tokyo"`, `Time.use_zone` | the application's default zone (`UTC` unless configured) |
| log tags: `Rails.logger.tagged("req-123")`, the request id, ActiveJob's job id | none |
| `connected_to(role: :reading)` | `:writing` |
| `connected_to(shard: :tenant_b)` | `:default` |
| `connected_to(prevent_writes: true)` | writes allowed |
| the error context: `Rails.error.set_context`, the controller or job Rails records | empty |
| `I18n.locale = :de` | depends on the i18n version — see below |
| the OpenTelemetry context | kept — the SDK carries it across |

This is the same in a message block, an observer, a hook, `can_use_tool` and an SDK MCP tool handler; with and without `Railtie.callback_wrapper`; in development and in production. It is the same under `callback_scheduling: :inline` with fiber isolation, with one exception: there a `Client`'s message block and observers run on the fiber that called the SDK, and see its state. (`ClaudeAgentSDK.query` runs every callback on another fiber, and hooks, `can_use_tool` and tool handlers always do.)

What a callback gets of `I18n.locale` depends on where i18n keeps its configuration:

| i18n | Callback on a thread of its own (`:thread` scheduling) | Callback on another fiber of the caller's thread (`:inline`) |
| --- | --- | --- |
| 1.14.7 and earlier: a fiber-local | the default locale | the default locale |
| 1.14.8: a thread variable | the default locale | `:de` — every fiber of the thread shares one locale |
| 1.15 and later: fiber storage | `:de` — new threads and fibers inherit it | `:de` |

Nothing raises. The consequences are silent:

- A job inside `connected_to(shard: :tenant_b)` writes its own records to `tenant_b`; the same `create!` in a tool handler or in the message block writes to the **default** shard. Inside `connected_to(role: :reading)` the caller's own write raises `ActiveRecord::ReadOnlyError`; the same write in a callback succeeds, on the primary.
- A scope or policy that reads `Current.account` runs unscoped. Log lines written by callbacks carry no request id, errors reported from them no controller or job, and times are formatted in the default zone.

### Carrying the caller's state into callbacks

The SDK has no option for this yet. The supported way today is a wrapper of your own that captures the state **on the caller** and restores it **inside** the Rails wrapper, on the callback's thread or fiber:

<!-- spec/rails/request_state_spec.rb runs the next code block verbatim -->
```ruby
# app/lib/agent_context.rb
module AgentContext
  # A callback_wrapper that runs SDK callbacks under the state of whoever
  # calls this method. Call it from the request or job, once per SDK call.
  def self.callback_wrapper
    rails   = ClaudeAgentSDK::Railtie.callback_wrapper
    origin  = Fiber.current
    restore = capture

    lambda do |invocation|
      # The callback is running on the caller itself: the state is there.
      next rails.call(invocation) if Fiber.current.equal?(origin)

      # Restore inside the Rails wrapper: the executor it enters starts
      # every execution from a clean slate.
      rails.call(-> { restore.call(invocation) })
    end
  end

  # Snapshots the caller. Returns a lambda that runs an invocation under
  # that snapshot, on whatever thread or fiber it is called on.
  def self.capture
    attributes = Current.attributes.dup
    context    = ActiveSupport::ExecutionContext.to_h
    locale     = I18n.locale
    zone       = Time.zone
    tags       = log_tags

    lambda do |invocation|
      Current.set(attributes) do
        ActiveSupport::ExecutionContext.set(**context) do
          I18n.with_locale(locale) do
            Time.use_zone(zone) do
              with_log_tags(tags) { invocation.call }
            end
          end
        end
      end
    end
  end

  # The tags of the first tagged logger Rails.logger writes to. Not
  # Rails.logger.formatter: in a broadcast that can be a plain logger's.
  def self.log_tags
    loggers = Rails.logger.respond_to?(:broadcasts) ? Rails.logger.broadcasts : [Rails.logger]
    formatter = loggers.map { |logger| logger.formatter if logger.respond_to?(:formatter) }
                       .find { |candidate| candidate.respond_to?(:current_tags) }
    formatter ? formatter.current_tags.dup : []
  end

  # push / pop, not `Rails.logger.tagged(*tags) { ... }`: a BroadcastLogger
  # runs that block once for every tagged logger it broadcasts to.
  def self.with_log_tags(tags)
    logger = Rails.logger
    return yield if tags.empty? || !logger.respond_to?(:push_tags)

    logger.push_tags(*tags)
    begin
      yield
    ensure
      logger.pop_tags(tags.size)
    end
  end
end
```

Build the wrapper where the state is set, and pass it in that call's options:

```ruby
class SummarizeTicketJob < ApplicationJob
  def perform(ticket)
    Current.account = ticket.account
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      callback_wrapper: AgentContext.callback_wrapper,   # replaces the configured Rails wrapper, and calls it
      tools: [], max_turns: 1,
      env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }
    )

    ClaudeAgentSDK.query(prompt: "Summarize:\n\n#{ticket.body}", options: options) do |message|
      # Current.account, the locale, Time.zone, the job's log tags and error context are set here
      ticket.update!(summary: message.result) if message.is_a?(ClaudeAgentSDK::ResultMessage)
    end
  end
end
```

What the recipe depends on:

- **One wrapper per call, built on the caller.** `AgentContext.callback_wrapper` snapshots whoever calls it. Call it from the request or job, after its state is set and before `query` / `Client.open` — not inside their blocks, which may already run on another fiber. It cannot go into the initializer: a process-wide wrapper only ever runs at the destination and has no caller to look at. And it must not outlive the call: a wrapper is fixed for the lifetime of the session it was passed to, so one built when a long-lived `Client` connects makes every later turn run its callbacks as the **first** caller — another user's turn would read and write under the first user's account and shard. Open a session per request or job and resume it by id, as the examples below do, and the capture happens once per call.
- **The restore happens inside `rails.call`.** In production the Rails wrapper enters the executor, and the executor starts every execution from a clean slate: it resets `Current` and the error context. State set around `rails.call` is wiped on the way in; state set inside it survives.
- **No restore on the fiber that captured the state.** Under `:inline` scheduling a `Client`'s message block and observers run on the caller itself. The state is already there, and restoring it again would add the log tags a second time.
- **Log tags are pushed and popped.** `Rails.logger` is an `ActiveSupport::BroadcastLogger`, and `Rails.logger.tagged(*tags) { ... }` runs its block once for every tagged logger in the broadcast, returning an array: with two tagged loggers the callback would run twice. `push_tags` / `pop_tags` reach every tagged logger and run nothing. The tags are read from the first logger in the broadcast that keeps tags rather than from `Rails.logger.formatter`, which is the first logger's on Rails 8.1, tagged or not, and `nil` on 7.1 for a broadcast you built yourself. With no tagged logger at all the recipe carries no tags and still runs.
- **`ActiveSupport::ExecutionContext` is restored explicitly.** It is where `Rails.error.set_context` and Rails' own controller and job entries live; `Current.set` does not bring it back. Rails has no public reader for it, so recheck this line when you upgrade Rails.
- **The locale is restored rather than assumed**, because only i18n 1.15 and later hand it to every callback by themselves. The restore is safe wherever a callback has a thread of its own, which is `:thread` scheduling, with any i18n. With i18n 1.14.8 it is only safe there: under `:inline` all fibers of the reactor thread share one locale, so a callback's `I18n.with_locale` changes the locale of every job on that worker while the callback runs, and another job that sets its own locale meanwhile changes the callback's. On a fiber-isolated host, keeping jobs' locales apart takes i18n 1.15 or later: on 1.14.8 the jobs of one worker share a locale among themselves, with or without the SDK. `:thread` scheduling takes the recipe's restore off that shared thread; it does not separate the jobs.
- **Values travel, containers do not.** The recipe rebuilds the caller's state from values. The objects themselves — `Current.user`, say — are shared with the caller, so treat them as read-only in callbacks. Do not go further and copy thread-local variables wholesale, hand the caller's ActiveRecord connection to a callback, or pass `ActiveRecord::Base.connected_to_stack` across: those are mutable and belong to one thread.

An application with replicas or shards also carries the role, the shard and `prevent_writes`. Capture them in `capture`:

```ruby
    role, shard    = ApplicationRecord.current_role, ApplicationRecord.current_shard
    prevent_writes = ApplicationRecord.current_preventing_writes
```

and re-enter them innermost, in place of `with_log_tags(tags) { invocation.call }`:

```ruby
              with_log_tags(tags) do
                ApplicationRecord.connected_to(role: role, shard: shard, prevent_writes: prevent_writes) { invocation.call }
              end
```

`connected_to` on `ApplicationRecord` switches the models that inherit from it; an application with several connection classes captures and re-enters each of them.

What is checked: `spec/rails/request_state_spec.rb` boots a Rails application for each combination of production / development, `:thread` / `:inline` scheduling and `ClaudeAgentSDK.query` / `Client.open`. It pins the `Current`, `Time.zone`, log tag and error context rows of the table, the `I18n.locale` cases for whichever i18n the bundle resolves (CI's resolve 1.15 or later; the 1.14.7 and 1.14.8 rows were run against those releases), and runs the `AgentContext` block exactly as printed above through all five kinds of callback — also with two tagged loggers in the `Rails.logger` broadcast, and with a plain logger ahead of the tagged one. It does not cover the three `connected_to` rows or the role / shard lines — the gem's Rails test bundles carry no ActiveRecord; those were measured in a Rails 8.1 application with ActiveRecord and SQLite.

## Transactions and the connection pool

For the same reason — another thread — a callback is outside the caller's database transaction, on a connection of its own. Wrapping an SDK call in `transaction` or `with_lock` does not do what it looks like:

```ruby
ticket.with_lock do                                   # the job's connection holds the row lock
  ClaudeAgentSDK.query(prompt: prompt) do |message|
    next unless message.is_a?(ClaudeAgentSDK::ResultMessage)

    ticket.update!(summary: message.result)           # another connection: waits for that lock,
  end                                                 # while the job waits for this block
end
```

- A callback does not see rows the caller has not committed.
- What a callback writes is committed on its own connection. Rolling the caller's transaction back does not undo it.
- A callback that needs a lock the caller's transaction holds waits for the caller, which is waiting for the callback. SQLite gives up after its busy timeout (`database is locked`); a server database keeps the callback waiting for as long as its lock timeout allows, which for PostgreSQL is forever by default. No database can detect the cycle, because half of it is in your process.

So finish the transaction **before** you call the SDK, and hand the callbacks what they need explicitly — ids rather than records in an unsaved state:

```ruby
ticket.update!(state: 'summarizing')                  # committed before the agent starts
ticket_id = ticket.id

ClaudeAgentSDK.query(prompt: prompt) do |message|
  next unless message.is_a?(ClaudeAgentSDK::ResultMessage)

  Ticket.find(ticket_id).update!(summary: message.result, state: 'summarized')   # commits here, independently
end
```

**Pool size.** A callback that uses the database needs a connection while the caller may still be holding one: inside a transaction, under an explicit lease, and for the whole request or job on Rails 7.1, where a connection stays with its thread until the request ends. And one session can have several callbacks in the database at the same moment — the SDK answers the CLI's hook, permission and tool requests concurrently, so two parallel tool calls mean two hooks running at once. Size the pool for the caller's connection **plus the peak number of callback invocations that use the database at the same time**, summed over the sessions a process runs concurrently — not for one extra connection per session. With a pool of one and the caller inside a transaction, the first query in a callback raises `ActiveRecord::ConnectionTimeoutError`.

Under `callback_scheduling: :inline` with fiber isolation all of this applies to every callback that runs on a fiber other than the caller's: hooks, permission callbacks, tool handlers, and everything under `ClaudeAgentSDK.query`. Only a `Client`'s message block and observers share the caller's connection and transaction there.

(Measured with ActiveRecord 8.1 on SQLite; the PostgreSQL and MySQL lock waits follow from how those databases wait for row locks and were not measured.)

## Fiber workers (solid_queue) and `callback_scheduling: :inline`

[solid_queue 728](https://github.com/rails/solid_queue/pull/728) added a fiber-based worker mode: workers configured with `fibers: N` run claimed jobs as fibers on one async reactor thread — built for exactly the long-lived, I/O-bound "LLM streaming" jobs this SDK produces. It requires the app to be fiber-isolated end to end:

```ruby
# config/application.rb
ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
```

On Rails 7.2+, ActiveRecord releases connections between queries under fiber isolation, so fiber counts can far exceed the pool size (e.g. 50 fibers on 25 connections).

In such a host the default thread hop works *against* you: every callback is ejected from the reactor onto a fresh bare thread, where `Fiber.scheduler` is `nil` (reactor APIs like `Async::Task#stop` / `Async::Notification` are unusable), and an implicitly checked-out AR connection dies with the throwaway thread (stranded until the reaper reclaims it). For these hosts the SDK offers opt-in inline scheduling:

```ruby
# config/initializers/claude_agent_sdk.rb — process-wide, matching
# isolation_level's process-wide nature. Only set this in processes that run
# fiber workers; or pass it per-session via ClaudeAgentOptions instead.
ClaudeAgentSDK.configure do |config|
  config.default_options = { callback_scheduling: :inline }
end
```

With `:inline`, no user callback leaves the job's reactor: message blocks, hooks, permission callbacks, SDK MCP handlers and observers all run in place, on a fiber of that reactor. This is the same execution model as the Python SDK (async callbacks run natively on the event loop).

In place on the reactor is not the same as on the job's own fiber, and under fiber isolation the fiber is what Rails keys the job's state on. A `Client`'s message block and observers run on the fiber that called the SDK. Hooks, permission callbacks and SDK MCP handlers run on child fibers of the session's read task, and `ClaudeAgentSDK.query` runs its whole body, message block included, on a fiber of its own. On those fibers `Current`, `Time.zone`, the log tags and the database role and shard start from their defaults, exactly as on a callback thread — see [Request state does not follow into callbacks](#request-state-does-not-follow-into-callbacks).

Concretely:

- `Fiber.scheduler` is live inside callbacks; reactor primitives work directly. DB access goes through the Rails 7.2+ fiber-aware pool, as in the rest of your fiber-worker jobs.
- No per-call threads exist, so nothing can strand an AR connection.
- The whole SDK session can live directly on the job fiber — no bridge threads. `Client#connect` already requires an Async context, and the transport's pipe I/O is scheduler-aware.
- Hook timeouts become **cooperative**: a timed-out inline hook is cancelled at its next suspension point (its `ensure` blocks run), instead of being abandoned on a worker thread. A CPU-stuck hook cannot be timed out.
- A cooperative deadline bounds the cancellation *request*, not the callback's completion: the cancellation is delivered once, and whatever the callback's `ensure` does afterwards runs unbounded on the reactor fiber. Fiber-aware cleanup delays only that callback (and the CLI waiting on its reply); scheduler-opaque cleanup — a file `fsync`, a non-fiber-aware driver, a GVL-holding C extension — stalls every job on the reactor for as long as it takes, and no deadline can interrupt it. Keep inline cleanup fiber-aware, or stay on `:thread` scheduling when you need a hard bound on the whole invocation.
- The CLI's cancellation of an in-flight callback (e.g. permission prompt superseded) can now actually interrupt it at a suspension point.
- Calling `client.disconnect` from inside an inline **control-request callback** (a hook, `can_use_tool`, or an SDK MCP handler) works, with one difference from `:thread` mode: the callback's own task is a child of the read task that `disconnect` stops, so after the teardown has completed (transport closed, pending control waiters released) the deferred `Async::Stop` unwinds the callback — `disconnect` raises there instead of returning. Put cleanup in `ensure`; a `rescue StandardError` will not see it (it is not a `StandardError`). In `:thread` mode `disconnect` returns normally on the worker thread and the callback's return value is simply dropped. Either way the callback's response is never sent — the session is gone. Message blocks and observers run on the caller's task, not under the read task, so a `disconnect` from one of those returns normally in both modes; a streaming-input enumerator that calls `disconnect` unwinds with `Async::Stop` in both modes.

The one real risk: **scheduler-opaque blocking stalls the whole reactor.** CPU-bound work or a GVL-holding C extension inside an inline callback blocks every job on that worker, not just yours. Blocking that releases the GVL and pure-Ruby CPU work can be moved onto a thread explicitly:

```ruby
tool = ClaudeAgentSDK.create_tool('lookup', 'Query legacy DB', { id: String }) do |args|
  row = ClaudeAgentSDK.offload { legacy_client.fetch(args[:id]) }  # plain thread
  row.to_json
end
```

`ClaudeAgentSDK.offload` is a no-op outside a reactor, so it's safe to call unconditionally. Be precise about what it protects, though: it fully shields the reactor from blocking calls that *release* the GVL (native DB drivers, file/socket I/O the scheduler can't see), and it turns pure-Ruby CPU work from a hard stall into GVL time-slicing (added latency for sibling jobs, not starvation). A C extension that **holds** the GVL for the whole computation still freezes the process — `offload` cannot help there; run that work in a subprocess.

Preconditions, spelled out: `:inline` is only correct when the process satisfies the same requirements as solid_queue's fiber workers — `isolation_level = :fiber`, Rails 7.2+ for AR, and no thread-keyed libraries used inside callbacks without a fiber-aware wrapper. The SDK warns once if it detects `:inline` under `isolation_level == :thread`. Everything else (Puma request threads, threaded Sidekiq/solid_queue workers) should stay on the default `callback_scheduling: :thread`.

Note that `SessionStore` adapter calls (`#append` / `#load`) stay on threads by default even in `:inline` mode — their timeouts are hard bounds (`Thread#join`) so a wedged store adapter can never stall the reactor. The exception is an adapter that declares itself fiber-native via an optional `callback_scheduling` method returning `:inline` (see "Fiber-native adapters" in [docs/sessions.md](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/docs/sessions.md)); its calls then run on the reactor under a cooperative timeout. In both cases a configured `callback_wrapper` composes around the adapter call inside the bound.

## ActionCable Streaming

Stream Claude responses to the frontend in real-time:

```ruby
# app/jobs/chat_agent_job.rb
class ChatAgentJob < ApplicationJob
  queue_as :claude_agents

  def perform(chat_id, message_content)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: { type: 'preset', preset: 'claude_code' },
      permission_mode: 'bypassPermissions',
      env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }   # one job class serves every chat: see "Per-user isolation"
    )

    ClaudeAgentSDK::Client.open(options: options) do |client|
      client.query(message_content)

      client.receive_response do |message|
        case message
        when ClaudeAgentSDK::AssistantMessage
          ChatChannel.broadcast_to(chat_id, { type: 'chunk', content: message.text })
        when ClaudeAgentSDK::ResultMessage
          ChatChannel.broadcast_to(chat_id, {
            type: 'complete',
            content: message.result,
            cost: message.total_cost_usd
          })
        end
      end
    end
  end
end
```

`Client.open` connects, yields the client, and always disconnects — also when the block raises, so the job's error handling sees the original exception. It runs inside an existing reactor or starts its own, so a job needs no `Async { }.wait` wrapper. Its return value is the block's; to leave the block early use `next`, not `break` (outside an `Async` block, `break` raises `LocalJumpError`, though the session is still torn down). `break` inside `receive_response` itself is fine.

### Per-user isolation

One job class serves every chat here, from one working directory — and the CLI keeps an auto-memory per *project directory*, not per session or per user:

- Every SDK session reads that project's memory index. The CLI injects it next to the `CLAUDE.md` instructions, under the same "these instructions override default behavior" header.
- A session on the `claude_code` preset also **writes** it when a user asks it to remember something, and that write passes no permission check: no `permission_mode`, `can_use_tool` callback or hook is consulted.
- `setting_sources: []` isolates settings files. It does not turn this off.

So in a multi-user app one user's "remember that…" becomes part of every other user's context. `env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }` turns auto-memory off for the session. Every set of options built on this page carries it (`spec/rails/session_isolation_spec.rb` checks each one). Set it for every session a multi-user app runs — per call, as here, or once for the whole process by uncommenting the line the generated initializer carries; defaults merge per key, so a per-call `env:` keeps it, and the short snippets on this page that pass no options get it too. The value has to be `'1'`: the CLI reads `'0'` or `'false'` as "force auto-memory on", which overrides even `autoMemoryEnabled: false` in settings. To see what a session loaded, call `client.context_usage[:memoryFiles]` (an entry with `type: "AutoMem"` is the memory index); it costs no model call.

What else isolates sessions, and what only appears to, is covered in [Session isolation](configuration.md#session-isolation).

## Session Resumption

Persist Claude sessions for multi-turn conversations:

```ruby
# app/models/chat_session.rb
class ChatSession < ApplicationRecord
  # Columns: id, claude_session_id, user_id, created_at, updated_at

  def send_message(content)
    ClaudeAgentSDK::Client.open(options: build_options) do |client|
      client.query(content)

      client.receive_response do |message|
        update!(claude_session_id: message.session_id) if message.is_a?(ClaudeAgentSDK::ResultMessage)
      end
    end
  end

  private

  def build_options
    opts = {
      permission_mode: 'bypassPermissions',
      setting_sources: [],                                  # isolates settings files, not the CLI's auto-memory:
      env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }     # this does (see "Per-user isolation")
    }
    opts[:resume] = claude_session_id if claude_session_id.present?
    ClaudeAgentSDK::ClaudeAgentOptions.new(**opts)
  end
end
```

The first message starts a new session; every later one resumes it by the ID the previous `ResultMessage` reported.

## Background Jobs with Error Handling

```ruby
class ClaudeAgentJob < ApplicationJob
  queue_as :claude_agents
  retry_on ClaudeAgentSDK::ProcessError, wait: :polynomially_longer, attempts: 3

  def perform(task_id)
    task = Task.find(task_id)

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      max_turns: 10,
      env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }   # see "Per-user isolation"
    )

    ClaudeAgentSDK::Client.open(options: options) do |client|
      client.query(task.prompt)
      client.receive_response do |message|
        task.update!(status: 'done', result: message.result) if message.is_a?(ClaudeAgentSDK::ResultMessage)
      end
    end
  rescue ClaudeAgentSDK::CLINotFoundError
    task.update!(status: 'failed', error: 'Claude CLI not installed (bin/rails claude_agent_sdk:install_cli)')
    raise
  end
end
```

## HTTP MCP Servers

Connect to remote tool services:

```ruby
mcp_servers = {
  'api_tools' => ClaudeAgentSDK::McpHttpServerConfig.new(
    url: ENV['MCP_SERVER_URL'],
    headers: { 'Authorization' => "Bearer #{ENV['MCP_TOKEN']}" }
  ).to_h
}

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: mcp_servers,
  permission_mode: 'bypassPermissions',
  env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }   # see "Per-user isolation"
)
```

## Observability in Rails

Add OpenTelemetry tracing to your Rails app with a single initializer:

```ruby
# config/initializers/opentelemetry.rb
require 'base64'
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'

if ENV['LANGFUSE_PUBLIC_KEY'].present?
  auth = Base64.strict_encode64("#{ENV['LANGFUSE_PUBLIC_KEY']}:#{ENV['LANGFUSE_SECRET_KEY']}")
  langfuse_host = ENV.fetch('LANGFUSE_HOST', 'https://cloud.langfuse.com')

  OpenTelemetry::SDK.configure do |c|
    c.service_name = Rails.application.class.module_parent_name.underscore
    c.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
        OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: "#{langfuse_host}/api/public/otel/v1/traces",
          headers: {
            'Authorization' => "Basic #{auth}",
            'x-langfuse-ingestion-version' => '4'
          }
        )
      )
    )
  end
end
```

```ruby
# config/initializers/claude_agent_sdk.rb
require 'claude_agent_sdk/instrumentation'

ClaudeAgentSDK.configure do |config|
  config.default_options = {
    permission_mode: 'bypassPermissions',
    observers: ENV['LANGFUSE_PUBLIC_KEY'].present? ? [
      # Use a lambda so each query gets a fresh observer instance (thread-safe).
      # A single shared instance would have its span state clobbered by concurrent requests.
      -> { ClaudeAgentSDK::Instrumentation::OTelObserver.new }
    ] : [],
    callback_wrapper: ClaudeAgentSDK::Railtie.callback_wrapper
  }
end
```

Then every `ClaudeAgentSDK.query` and `Client` session automatically gets traced — no per-call wiring needed. The lambda factory ensures each request gets its own observer with isolated span state, safe for concurrent Puma/Sidekiq workers.

See:
- [examples/rails_actioncable_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/rails_actioncable_example.rb)
- [examples/rails_background_job_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/rails_background_job_example.rb)
- [examples/session_resumption_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/session_resumption_example.rb)
- [examples/http_mcp_server_example.rb](https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/examples/http_mcp_server_example.rb)
