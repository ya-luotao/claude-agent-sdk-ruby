# frozen_string_literal: true

require_relative 'lib/claude_agent_sdk/version'

Gem::Specification.new do |spec|
  spec.name = 'claude-agent-sdk'
  spec.version = ClaudeAgentSDK::VERSION
  spec.authors = ['Community Contributors']
  spec.email = []

  spec.summary = 'Unofficial Ruby SDK for Claude Agent'
  spec.description = 'Unofficial Ruby SDK for interacting with Claude Code, supporting bidirectional conversations, custom tools, and hooks. Not officially maintained by Anthropic.'
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
  # lib/*.rb even becomes requireable code in the released gem). Fall back to
  # the glob when git is unavailable (e.g. building from a source tarball).
  tracked = begin
    IO.popen(%w[git ls-files -z lib docs README.md LICENSE CHANGELOG.md],
             chdir: __dir__, err: File::NULL, &:read).split("\x0")
  rescue SystemCallError
    []
  end
  spec.files = tracked.empty? ? Dir['lib/**/*', 'docs/**/*', 'README.md', 'LICENSE', 'CHANGELOG.md'] : tracked
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'async', '~> 2.0'
  # >= 0.6: 0.4 raised protocol errors for tool failures; 0.5 serializes
  # empty icons arrays into resources/prompts lists. tools/call error
  # envelopes are normalized to in-band isError by the SDK itself, so the
  # gem's per-version error behavior swings (0.7.1+/0.18) don't leak through.
  spec.add_dependency 'mcp', '>= 0.6', '< 1'

  # Development dependencies
  spec.add_development_dependency 'bundler', '~> 2.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  # Pinned to a single minor so local and CI resolve the same RuboCop (Gemfile.lock
  # is gitignored, per gem convention) — cop behavior changes land on minor bumps.
  spec.add_development_dependency 'rubocop', '~> 1.87.0'
end
