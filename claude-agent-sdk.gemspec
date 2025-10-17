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
  spec.metadata['documentation_uri'] = 'https://docs.anthropic.com/en/docs/claude-code/sdk'

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir['lib/**/*', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'async', '~> 2.0'
  spec.add_dependency 'mcp', '~> 0.4'

  # Development dependencies
  spec.add_development_dependency 'bundler', '~> 2.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rubocop', '~> 1.0'
end
