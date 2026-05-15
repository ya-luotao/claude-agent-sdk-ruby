---
description: Cut a new gem release — bump version, sync docs, update CHANGELOG, tag, and publish a GitHub Release. The publish.yml workflow then pushes to rubygems.org via trusted publisher (no manual `gem push`).
argument-hint: patch | minor | major | <explicit-version> [--dry-run] [--draft]
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Release the gem

You are cutting a new release of the `claude-agent-sdk` Ruby gem. Argument: `$ARGUMENTS`.

**`gem push` is fully automated.** Publishing the GitHub Release fires `.github/workflows/publish.yml`, which uses RubyGems trusted publishing (OIDC) to push to rubygems.org. The maintainer does not run `gem push` and does not need an OTP. Your job ends at "GitHub Release published; workflow run started at <url>."

## Preconditions — fail loudly if any of these are wrong

Run these in one batch and abort if any fail:

1. Current branch is `main` (`git rev-parse --abbrev-ref HEAD`).
2. Working tree is clean (`git status --porcelain` returns empty).
3. Local is synced with origin (`git fetch && git status -sb` shows `## main...origin/main` with no `ahead`/`behind`).
4. Last run of `bundle exec rake` is green — run it now and abort on failure.

If the user passed `--dry-run`, do everything below **except** git commit, push, tag, and `gh release create`. Print the planned diff instead.

## Step 1 — Determine the new version

Read current version from `lib/claude_agent_sdk/version.rb` (the `VERSION = '...'` constant is the source of truth; the gemspec reads it).

Resolve the requested version:
- `patch` → bump the last segment (e.g. `0.14.2` → `0.14.3`).
- `minor` → bump middle, reset patch (`0.14.2` → `0.15.0`).
- `major` → bump first, reset rest (`0.14.2` → `1.0.0`).
- Explicit `X.Y.Z` → use as-is after a semver sanity check.

Show the proposed version and the commits since the last tag:

```
git describe --tags --abbrev=0                     # last tag, e.g. v0.14.2
git log <last-tag>..HEAD --oneline --no-merges     # commits to include
```

## Step 2 — Version bumps (all sites must stay in lockstep)

Edit these files. Use `Edit`, not `sed`.

1. **`lib/claude_agent_sdk/version.rb`** — replace the `VERSION` string.
2. **`README.md`** — the gem pin line: `gem 'claude-agent-sdk', '~> X.Y.Z'`. There may also be a `gem install claude-agent-sdk -v X.Y.Z` example — update both if present. Grep first: `grep -nE "(gem 'claude-agent-sdk'|gem install claude-agent-sdk)" README.md`.
3. **`plugins/claude-agent-ruby/.claude-plugin/plugin.json`** — the `"version"` field. This is the Claude Code plugin manifest version; it tracks the gem version.
4. **`CLAUDE.md`** — usually no version pin, but grep to confirm: `grep -nE "[0-9]+\.[0-9]+\.[0-9]+" CLAUDE.md`. Edit only if a gem version appears.

## Step 3 — Skill sync (both copies must match)

There are **two** skill trees in this repo and they drift:
- `skills/` (canonical)
- `plugins/claude-agent-ruby/skills/claude-agent-ruby/` (plugin-packaged copy)

Run `diff -qr skills plugins/claude-agent-ruby/skills/claude-agent-ruby`. If files differ, mirror the changes so both trees match. The `SKILL.md` frontmatter `description` should be identical across copies.

Only edit the skill *content* if the release actually changed a documented API surface (new message types, new options, etc.). A pure bug-fix release may not need any skill edit — in that case just sync any existing drift and move on.

## Step 4 — CHANGELOG

Open `CHANGELOG.md`. The file follows Keep-a-Changelog.

1. Promote `## [Unreleased]` content into a new `## [X.Y.Z] - YYYY-MM-DD` section (use today's date, UTC).
2. Leave a fresh empty `## [Unreleased]` section at the top.
3. Use subsections `### Added`, `### Changed`, `### Fixed`, `### Removed` as applicable. If `[Unreleased]` was empty, synthesize entries from `git log <last-tag>..HEAD`, grouping by commit message intent.

Keep entries terse and user-facing — describe what the gem's consumers can now do or no longer do, not internal refactors.

## Step 5 — Validate

Run in this order, abort on failure:

```
bundle exec rake            # spec + rubocop
bundle exec rake build      # smoke test — produces pkg/claude-agent-sdk-X.Y.Z.gem
```

`rake build` is a **local smoke test only** — it catches gemspec errors before tagging. The workflow rebuilds and signs the gem in CI; the local `.gem` artifact is not used for publishing.

Confirm the built gem filename matches the new version.

## Step 6 — Commit, tag, push

Commit message shape (match prior releases):

```
Bump version to X.Y.Z and cut CHANGELOG

<short 1–2 line summary of what's in this release>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Stage explicitly — not `git add -A` — to avoid sweeping in `pkg/*.gem`:

```
git add lib/claude_agent_sdk/version.rb README.md CHANGELOG.md \
        plugins/claude-agent-ruby/.claude-plugin/plugin.json \
        skills plugins/claude-agent-ruby/skills
# Include CLAUDE.md only if Step 2.4 modified it.
git commit -m "$(cat <<'EOF'
...
EOF
)"
git push origin main
```

Then tag and push the tag:

```
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

## Step 7 — GitHub release

Draft the release body from the new CHANGELOG section. Prior releases use this shape (see v0.14.2 for reference):

```markdown
### Added
- ...
### Changed
- ...
### Fixed
- ...

### Usage
(optional short code example for notable changes)

### What's changed
- #NN <title> — @author

**Full Changelog**: https://github.com/ya-luotao/claude-agent-sdk-ruby/compare/v<prev>...vX.Y.Z

---

\`\`\`
gem install claude-agent-sdk -v X.Y.Z
\`\`\`
```

Generate the "What's changed" list from merged PRs since the last tag:

```
gh pr list --repo ya-luotao/claude-agent-sdk-ruby \
  --state merged --search "merged:>=<last-tag-date>" \
  --json number,title,author
```

Create the release. Default: publish immediately (this is what fires `publish.yml`). If the user passed `--draft`, append `--draft` so they can eyeball the notes in GitHub UI and click "Publish release" manually:

```
gh release create vX.Y.Z --repo ya-luotao/claude-agent-sdk-ruby \
  --title "vX.Y.Z" --notes-file <tmpfile>
# add --draft if --draft was passed
```

Mark it latest only if it is (for hotfixes to older minor lines, pass `--latest=false`).

## Step 8 — Verify the publish workflow

Publishing the GitHub Release triggers `.github/workflows/publish.yml`. The `rubygems` job uses trusted publishing (OIDC) to push the gem to rubygems.org — **no `gem push` command for the user to run**.

Locate the triggered run and surface its URL:

```
sleep 5  # give Actions a moment to register the dispatch
gh run list --workflow publish.yml --limit 1 --json databaseId,url,status --jq '.[0]'
```

Tell the user where to watch it. Do **not** wait for it to finish (the user can see the status notification when it lands). If the user passed `--draft`, note that the workflow won't fire until they click "Publish release" in the GitHub UI.

If publishing fails (e.g. trusted publisher misconfigured), the workflow stops cleanly with no side effects on rubygems.org — the maintainer can re-run after fixing config, since the version isn't published until `gem push` succeeds.

## What to report back

A terse summary:
- New version
- Files changed (count)
- Commit SHA + tag name
- GitHub Release URL
- publish.yml workflow run URL (or "release is draft — workflow will fire when you publish it")

That's it — no trailing recap of the workflow.
