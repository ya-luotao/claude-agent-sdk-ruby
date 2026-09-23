# frozen_string_literal: true

require_relative 'lib/claude_agent_sdk/version'

Gem::Specification.new do |spec|
  spec.name = 'claude-agent-sdk'
  spec.version = ClaudeAgentSDK::VERSION
  spec.authors = ['Community Contributors']
  spec.email = []

  spec.summary = 'Unofficial Ruby SDK for Claude Agent, with Rails integration'
  spec.description = 'Unofficial Ruby SDK for the Claude Code agent runtime: one-shot queries and bidirectional ' \
                     'sessions, in-process custom tools, hooks and permission callbacks. Includes Rails ' \
                     'integration (Railtie, install generator, CLI-vendoring rake task, executor-aware callback ' \
                     'wrapper), a pinned CLI installer, OpenTelemetry tracing, and session transcript mirroring. ' \
                     'Not affiliated with or officially maintained by Anthropic.'
  spec.homepage = 'https://github.com/ya-luotao/claude-agent-sdk-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/ya-luotao/claude-agent-sdk-ruby'
  spec.metadata['changelog_uri'] = 'https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/CHANGELOG.md'
  spec.metadata['documentation_uri'] = 'https://rubydoc.info/gems/claude-agent-sdk'
  spec.metadata['allowed_push_host'] = 'https://rubygems.org'

  # Ship only git-tracked files: a working-tree Dir glob would package any
  # stray/untracked files under lib/ or docs/ present at build time (a stray
  # lib/*.rb even becomes requireable code in the released gem). Releases are
  # built from a git checkout (publish.yml), so this is the path that matters.
  #
  # Without git (a source tarball, or a Bundler `path:` source in a git-less
  # container) fall back to a glob restricted to the file types git ships —
  # spec/unit/gemspec_spec.rb asserts both select the same set. Not a hard
  # failure: Bundler evaluates this file for path/git-sourced consumers, and
  # raising here would break their bundle, not just a release build.
  tracked = begin
    IO.popen(%w[git ls-files -z lib docs README.md LICENSE CHANGELOG.md],
             chdir: __dir__, err: File::NULL, &:read).split("\x0")
  rescue SystemCallError
    []
  end
  spec.files = if tracked.empty?
                 # .rake: the Railtie's tasks; .tt: the Rails generator's templates.
                 Dir.glob(['lib/**/*.{rb,rake,tt}', 'docs/**/*.md', 'README.md', 'LICENSE', 'CHANGELOG.md'],
                          base: __dir__)
               else
                 tracked
               end
  spec.require_paths = ['lib']

  # Runtime dependencies
  # >= 2.10: Task#defer_stop, which Query#close relies on to finish its
  # teardown when called from inside a task it stops (an inline callback or
  # a streaming-input enumerator). Older releases also fail outright: 2.0.x
  # cannot run on Ruby 3.2+ (its scheduler io_write hook has the wrong
  # arity), and before 2.6.4 HookMatcher timeouts and pending-control-request
  # error delivery break. gemfiles/floor.gemfile pins this floor in CI.
  spec.add_dependency 'async', '>= 2.10', '< 3'
  # >= 0.22: 0.19 and older validate through the json-schema gem, whose
  # JSON.parse(s, quirks_mode: true) raises under json 3.x (strict keywords)
  # and fails every SDK MCP tools/call — and a fresh bundle resolves json 3.x
  # via async -> console -> json; 0.20/0.21 (the first json_schemer releases)
  # fail every tools/call of a tool whose input_schema uses
  # `$ref: '#/$defs/...'`.
  # tools/call error envelopes are normalized to in-band isError by the SDK
  # itself, and handler exceptions are rescued inside the SDK's tool class
  # (1.2+ redacts e.message from its own error text, CWE-209), so the gem's
  # per-version error behavior swings don't leak through.
  # < 2: the suite is verified against every 1.x release through 1.6.0.
  spec.add_dependency 'mcp', '>= 0.22', '< 2'

  # Development dependencies
  spec.add_development_dependency 'bundler', '~> 2.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  # Pinned to a single minor so local and CI resolve the same RuboCop (Gemfile.lock
  # is gitignored, per gem convention) — cop behavior changes land on minor bumps.
  spec.add_development_dependency 'rubocop', '~> 1.87.0'
end
