# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in claude-agent-sdk.gemspec
gemspec

gem 'rake', '~> 13.0'
gem 'rspec', '~> 3.0'
gem 'rubocop', '~> 1.0'
gem 'yard', '~> 0.9'

# Optional group: only activated when explicitly requested (e.g. from an
# example via Bundler.setup(:default, :instrumentation)). Kept out of the
# default groups so `bundle exec rspec` doesn't put the real opentelemetry
# gem on $LOAD_PATH — the instrumentation spec supplies its own mock and
# breaks if the real gem is auto-loaded over it.
group :instrumentation, optional: true do
  # base64 was removed from Ruby 3.4's default gems; used by the OTel
  # examples to encode Langfuse basic-auth credentials.
  gem 'base64', '~> 0.2'

  # Used by examples/otel_langfuse_example.rb and examples/test_langfuse_otel.rb.
  # Kept out of the gemspec so end users only pay for OTel if they opt in.
  gem 'opentelemetry-exporter-otlp', '~> 0.26'
  gem 'opentelemetry-sdk', '~> 1.4'
end
