# SessionStore reference adapters

> **Reference implementations for interface validation. Not packaged, not maintained as production code.**

Reference [`ClaudeAgentSDK::SessionStore`](../../lib/claude_agent_sdk/session_store.rb)
implementations — copy one into your project, install the backend client gem,
and validate it with `ClaudeAgentSDK::Testing.run_session_store_conformance`.

These adapters live in `examples/` (not `lib/`) so the gem stays free of
heavyweight optional dependencies. Each adapter here passes the full
SessionStore conformance suite.

| Adapter | File | Backend gem | Test backend |
|---|---|---|---|
| S3 | `s3_session_store.rb` | `aws-sdk-s3` | in-process fake (`S3SessionStore::RecordingClient`) |
| Redis | `redis_session_store.rb` | `redis` | live `redis-server` |
| Postgres | `postgres_session_store.rb` | `pg` | live PostgreSQL |

## Validating your own adapter

When you copy an adapter into your project (or write a new one), assert it
satisfies the contract's behavioral guarantees with the shipped conformance
harness — it's framework-agnostic (raises `ConformanceError`, no RSpec
dependency):

```ruby
require 'claude_agent_sdk/testing/session_store_conformance'

ClaudeAgentSDK::Testing.run_session_store_conformance(-> { MyStore.new(...) })
```

`make_store` is invoked once per contract so each runs against an isolated
store. Pass `skip_optional:` (e.g. `%w[delete list_subkeys]`) to skip contracts
for optional methods your adapter doesn't implement.

## Running the example tests

The backend client gems live in an optional `:examples` Bundler group, kept out
of the default groups so `bundle exec rspec` doesn't require them. Install them
to run the live specs:

```bash
bundle config set --local with examples
bundle install
```

- **S3** (`spec/examples/s3_session_store_spec.rb`) runs unconditionally — it
  uses the in-process `S3SessionStore::RecordingClient` fake, so no `aws-sdk-s3`
  gem or network is needed.
- **Redis** (`spec/examples/redis_session_store_spec.rb`) skips unless the
  `redis` gem is installed **and** `SESSION_STORE_REDIS_URL` points at a
  reachable server.
- **Postgres** (`spec/examples/postgres_session_store_spec.rb`) skips unless the
  `pg` gem is installed **and** `SESSION_STORE_POSTGRES_URL` is set.

```bash
docker run -d -p 6379:6379 redis:7-alpine
docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:16-alpine

SESSION_STORE_REDIS_URL=redis://localhost:6379/0 \
SESSION_STORE_POSTGRES_URL=postgresql://postgres:postgres@localhost:5432/postgres \
  bundle exec rspec spec/examples/
```

## Production checklist

These adapters are reference code. Before running one in production, work
through the relevant items below.

### All adapters

- `run_session_store_conformance` proves *correctness*, not *resilience* —
  load-test your adapter under your expected throughput.
- The Ruby SessionStore contract is **synchronous**: `#append` runs on the
  transcript-mirror batcher's flush thread (serialized, bounded by the batcher's
  send timeout) and `#load` runs inside resume/listing. Make each method
  thread-safe per key — a per-call connection (Postgres/Redis) or a thread-safe
  client (`aws-sdk-s3`) satisfies this.
- `#append` is retried by the batcher on adapter *errors* (up to 3 attempts);
  *timeouts* are not retried, but the timed-out call is abandoned still running,
  so a later append for the same key can overlap it. **Dedupe by
  `entry["uuid"]`** when present — some entry types (e.g.
  `file-history-snapshot`, `permission-mode`) carry no uuid; mirrored entries
  are opaque CLI pass-through, and only the SDK's `*_via_store` mutation
  helpers stamp fresh uuids. Don't make a uuid column `NOT NULL`/`UNIQUE`.
- `#append` failures are logged and surface a `MirrorErrorMessage` on the
  message stream; they never block the conversation. Monitor for these so
  silent mirror gaps don't go unnoticed.

### S3

- Required IAM actions on the bucket/prefix: `s3:PutObject`, `s3:GetObject`,
  `s3:ListBucket`, `s3:DeleteObject`.
- Part-file ordering uses the **client-side wall clock**. Multiple writer
  instances with clock skew >1s may produce out-of-order `#load` results. Use
  NTP or a single writer per session.
- `#load` fetches parts with a bounded 16-way thread pool, but every `#append`
  still creates a new part — compact periodically if sessions accumulate
  thousands of parts (eager flush mode writes one part per frame).
- Configure an S3 lifecycle policy for retention — the SDK never auto-deletes.

### Redis

- Set `maxmemory-policy noeviction` (or use a dedicated DB) — eviction will
  silently drop session data.
- Lists are unbounded; implement TTL via `EXPIRE` in a subclass if needed.
- Redis Cluster: keys sharing the same `{project_key}:{session_id}` prefix
  should hash to the same slot — wrap in `{...}` hash tags if using Cluster.
- If you derive `project_key`/`session_id` outside the SDK, ensure they cannot
  contain `:` (the key separator). The SDK's own `project_key_for_directory` and
  UUID session IDs are already safe.

### Postgres

- Pass a connection backed by a pool sized ≥ expected concurrent sessions for
  heavy use; don't share one connection with request-handler code that holds it.
- `jsonb` reorders keys — contract-safe, but don't byte-compare entries.
- Add a retention job (`DELETE WHERE mtime < ...`) — the table grows unbounded.

---

## S3 — `s3_session_store.rb`

Stores transcripts as JSONL part files:

```
s3://{bucket}/{prefix}{project_key}/{session_id}/part-{epochMs13}-{rand6}.jsonl
```

Each `#append` writes a new part; `#load` lists, sorts, and concatenates them.
The fixed-width 13-digit epoch-ms prefix makes lexical key order ==
chronological order.

```ruby
require 'aws-sdk-s3'
require 'claude_agent_sdk'
require_relative 's3_session_store'

store = S3SessionStore.new(
  bucket: 'my-claude-sessions',
  prefix: 'transcripts',
  client: Aws::S3::Client.new(region: 'us-east-1')
)

ClaudeAgentSDK.query(
  prompt: 'Hello!',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store)
) do |message|
  # Messages are mirrored to S3 automatically.
  puts message.result if message.is_a?(ClaudeAgentSDK::ResultMessage) && message.subtype == 'success'
end
```

Resume from S3 by pairing `session_store:` with `resume:`:

```ruby
ClaudeAgentSDK.query(
  prompt: 'Continue where we left off',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store, resume: 'previous-session-id')
) { |message| ... }
```

`#delete` removes all parts for a session but is only invoked when you call
`ClaudeAgentSDK.delete_session_via_store`.

---

## Redis — `redis_session_store.rb`

Backed by the [`redis`](https://rubygems.org/gems/redis) gem.

```ruby
require 'redis'
require 'claude_agent_sdk'
require_relative 'redis_session_store'

store = RedisSessionStore.new(
  client: Redis.new(url: 'redis://localhost:6379/0'),
  prefix: 'transcripts'
)

ClaudeAgentSDK.query(
  prompt: 'Hello!',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store)
) do |message|
  puts message.result if message.is_a?(ClaudeAgentSDK::ResultMessage) && message.subtype == 'success'
end
```

Key scheme (`:` separator):

```
{prefix}:{project_key}:{session_id}             list  — main transcript entries (one JSON string each)
{prefix}:{project_key}:{session_id}:{subpath}   list  — subagent transcript entries
{prefix}:{project_key}:{session_id}:__subkeys   set   — subpaths under this session
{prefix}:{project_key}:__sessions               zset  — session_id → mtime(ms)
```

Each `#append` is an `RPUSH` plus an index update in a single `MULTI`; `#load`
is `LRANGE 0 -1`. `#delete` cascades to subpath lists and index entries; it is
only invoked via `ClaudeAgentSDK.delete_session_via_store`.

---

## Postgres — `postgres_session_store.rb`

Backed by the [`pg`](https://rubygems.org/gems/pg) gem.

```ruby
require 'pg'
require 'claude_agent_sdk'
require_relative 'postgres_session_store'

conn  = PG.connect('postgresql://localhost/mydb')
store = PostgresSessionStore.new(conn: conn)
store.create_schema  # idempotent CREATE TABLE IF NOT EXISTS

ClaudeAgentSDK.query(
  prompt: 'Hello!',
  options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store)
) do |message|
  puts message.result if message.is_a?(ClaudeAgentSDK::ResultMessage) && message.subtype == 'success'
end
```

Schema (one row per transcript entry; `seq` orders entries within a
`(project_key, session_id, subpath)` key):

```sql
CREATE TABLE IF NOT EXISTS claude_session_store (
  project_key text   NOT NULL,
  session_id  text   NOT NULL,
  subpath     text   NOT NULL DEFAULT '',
  seq         bigserial,
  entry       jsonb  NOT NULL,
  mtime       bigint NOT NULL,
  PRIMARY KEY (project_key, session_id, subpath, seq)
);
CREATE INDEX IF NOT EXISTS claude_session_store_list_idx
  ON claude_session_store (project_key, session_id) WHERE subpath = '';
```

`#append` is a single multi-row `INSERT` (rows take `seq` in VALUES order);
`#load` is `SELECT entry ... ORDER BY seq`. The empty string is the `subpath`
sentinel for the main transcript so the composite primary key is total.

### JSONB key ordering

Entries are stored as `jsonb`, which **reorders object keys** on read-back. This
is explicitly allowed by the SessionStore contract — `#load` requires
*deep-equal*, not *byte-equal*, returns. The Ruby SDK reads entry fields by key
from the parsed Hash (it never does a byte/prefix scan over stored entries), so
reordering is transparent. Use a `json` or `text` column if you need byte-stable
storage.

`#delete` cascades to subpath rows; it is only invoked via
`ClaudeAgentSDK.delete_session_via_store`.
