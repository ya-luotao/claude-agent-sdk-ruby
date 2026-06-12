---
name: port-python-parity
description: Port features from the official Python claude-agent-sdk to this Ruby gem for parity. Use when syncing with a new Python SDK release, running a gap analysis, or batching parity fixes.
disable-model-invocation: true
---

Port Python SDK changes to this Ruby gem. Target version(s): $ARGUMENTS (if empty, find the latest unported Python version via gap analysis below).

## Source of truth

- Python SDK checkout: `../claude-agent-sdk-python` (relative to this repo). Pull latest before starting.
- Repo-local parity record (primary, always available): the README parity comparison table and CHANGELOG.md — update both whenever a feature lands.
- Auto-memory files `project_porting_pattern.md` and `project_parity_gaps.md` hold the last-checked version and history (supplementary — they may be absent in fresh environments; if missing, derive the last ported version from CHANGELOG.md instead).
- When citing a fact about this gem (dependency bounds, config defaults, API shape), verify it against the code (gemspec, lib/) — not against CLAUDE.md, README prose, or memory, which can lag the code.

## Workflow

1. **Gap analysis** — diff the Python SDK between the last ported version and the target: read its CHANGELOG.md and `git log` for the range. Verify the version tags actually exist first (`git tag -l`) — Python's versioning has jumped ranges before (v0.1.81 → v0.2.82). List each change as port / adapt / skip (Ruby-N/A), with the Python PR number.
   - **Don't classify a PR by its label — read its full diff.** A PR that looks Ruby-N/A on the surface (asyncio/anyio plumbing, CI changes, type annotations) often carries embedded behavioral changes that DO apply: e.g., Python #990 was "trio compatibility" but also simplified `flush()` semantics and narrowed exception swallowing. For each skip verdict, enumerate the semantic changes inside the diff and confirm each one is already matched (or genuinely N/A) in the Ruby counterpart files, citing file:line.
2. **Branch** — `feature/sync-python-sdk-<python-version>` (e.g., `feature/sync-python-sdk-0.1.56`). Batch-style audit work uses `audit/<topic>-batch-<n>` instead.
3. **Port** — adapt Python idioms to Ruby conventions:
   - snake_case names, keyword args, plain classes with `attr_accessor` (no Struct/Data)
   - `to_h` serialization with camelCase keys for CLI compatibility
   - user-facing callbacks must go through `FiberBoundary.invoke`
   - RSpec `expect` syntax only; add specs mirroring the Python tests
4. **Commit messages** — reference the Python PR number, e.g. `Add local-disk list_subagents (Python #825)`.
5. **Verify** — `bundle exec rake` (spec + rubocop) must be green. Run `RUN_INTEGRATION=1 bundle exec rspec` if the change touches the CLI wire protocol.
6. **PR** — title references the Python SDK version; body lists each ported change with its Python PR number.
7. **Record** — update the README parity table, CHANGELOG.md, and the memory files (new "last ported" version, anything skipped and why).

## Known traps from past batches

- The `mcp` gem's API has shifted between minor versions — verify against the locked version, not docs.
- Enumerator-based streaming input crosses threads; watch for FiberError (see `fiber_boundary.rb` docs).
- Some Python features are CLI-version-gated — prefer version-independent detection (in-band errors over version sniffing).
