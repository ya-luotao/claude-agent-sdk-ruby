# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in claude-agent-sdk.gemspec
gemspec

gem 'rake', '~> 13.0'
gem 'rspec', '~> 3.0'
gem 'rubocop', '~> 1.0'
gem 'yard', '~> 0.9'

# Used by examples/ only; base64 was removed from Ruby 3.4's default gems.
gem 'base64', '~> 0.2'

# Used by examples/otel_langfuse_example.rb and instrumentation specs.
# Kept out of the gemspec so end users only pay for OTel if they opt in.
gem 'opentelemetry-sdk', '~> 1.4'
gem 'opentelemetry-exporter-otlp', '~> 0.26'
