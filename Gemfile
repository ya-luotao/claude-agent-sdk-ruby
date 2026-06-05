# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in claude-agent-sdk.gemspec
gemspec

gem 'rake', '~> 13.0'
gem 'rspec', '~> 3.0'
gem 'rubocop', '~> 1.87.0' # pin minor so local matches CI (Gemfile.lock is gitignored)
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

# Optional group: backend client gems for the SessionStore reference adapters
# under examples/session_stores/. Kept out of the default groups so a plain
# `bundle exec rspec` never requires them — the Redis/Postgres example specs
# skip unless these load and a backend is reachable (SESSION_STORE_*_URL). The
# S3 example spec uses an in-process fake and needs none of these. Enable with
# `bundle config set --local with examples && bundle install`.
group :examples, optional: true do
  gem 'aws-sdk-s3', '~> 1.0'
  gem 'pg', '~> 1.0'
  gem 'redis', '~> 5.0'
end
