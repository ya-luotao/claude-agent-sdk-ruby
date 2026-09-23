## What and why

<!-- One focused change. Link the issue it fixes (Fixes #123), or the Python/TypeScript SDK PR it ports (Python #825). -->

## Checklist

- [ ] `bundle exec rake` passes (specs + RuboCop)
- [ ] Specs cover the change; a bug fix includes one that failed before the fix
- [ ] CHANGELOG entry under `## [Unreleased]` for anything a gem user would notice
- [ ] Docs updated (`docs/`, README, YARD) if public behavior changed
- [ ] If the CLI wire protocol changed: ran `RUN_INTEGRATION=1 bundle exec rspec spec/integration` (see CONTRIBUTING.md)
