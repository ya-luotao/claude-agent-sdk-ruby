# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately. Don't open a public issue or PR.

Use [GitHub's private vulnerability reporting](https://github.com/ya-luotao/claude-agent-sdk-ruby/security/advisories/new) for this repository (Security tab → "Report a vulnerability"). If that form is unavailable, email the maintainer at the address in the gemspec (`luotao@hey.com`).

Please include the affected gem version, a description of the issue and its impact, and a proof of concept or steps to reproduce if you have them. Follow-up happens on the private advisory thread. Fixes ship in a patch release, and the advisory is published once that release is out.

## Scope

This policy covers the `claude-agent-sdk` gem, i.e. the code in this repository. Examples of in-scope issues:

- the CLI installer (`CLIInstaller`) fetching, verifying or placing a binary unsafely
- command or argument injection when building the `claude` command line
- credentials (API keys, MCP server headers or env) leaking through `#inspect`, logs, errors or observers
- SDK MCP tool, hook or permission-callback dispatch that bypasses a decision the user's code made

Out of scope, and reported to Anthropic instead through its [HackerOne program](https://hackerone.com/anthropic) (see the [Claude Code security policy](https://github.com/anthropics/claude-code/security/policy)):

- the Claude Code CLI itself, which this gem runs as a subprocess
- the Anthropic API, claude.ai, and the official TypeScript and Python SDKs

If you aren't sure which side an issue is on, report it here and we'll help route it.

## Supported versions

The gem is pre-1.0. Security fixes go into the latest minor release only; upgrade to receive them.
