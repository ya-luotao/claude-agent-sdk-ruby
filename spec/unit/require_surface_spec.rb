# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

# Exercises the gem's require surface in a pristine child process: the spec
# process has already loaded every file, so an in-process `require` cannot
# detect a missing shim or a missing transitive require.
RSpec.describe 'require surface' do
  def run_ruby(code)
    lib_dir = File.expand_path('../../lib', __dir__)
    Open3.capture3(RbConfig.ruby, '-I', lib_dir, '-e', code)
  end

  it 'loads the full SDK via the gem-named require (the Bundler autorequire path)' do
    # Bundler.require tries `require 'claude-agent-sdk'` then
    # 'claude/agent/sdk' and silently swallows both LoadErrors, leaving the
    # SDK unloaded in every default Rails/Bundler app unless this shim exists.
    _out, err, status = run_ruby("require 'claude-agent-sdk'; exit(ClaudeAgentSDK.respond_to?(:query) ? 0 : 1)")
    expect(status.exitstatus).to eq(0), "expected `require 'claude-agent-sdk'` to load the SDK: #{err}"
  end

  it 'loads the SDK core via the documented instrumentation entry point' do
    # docs/rails.md's initializer and OTelObserver's own @example use
    # `require 'claude_agent_sdk/instrumentation'` as their only require;
    # it must pull in the core (configure, ClaudeAgentOptions, ...) too.
    code = "require 'claude_agent_sdk/instrumentation'; " \
           "ClaudeAgentSDK.configure { |c| c.default_options = {} }; " \
           'exit(defined?(ClaudeAgentSDK::ClaudeAgentOptions) ? 0 : 1)'
    _out, err, status = run_ruby(code)
    expect(status.exitstatus).to eq(0), "instrumentation entry point must load the SDK core: #{err}"
  end

  it 'does not load Rails or the Railtie outside a Rails app' do
    # The Railtie is required only `if defined?(Rails::Railtie)`; a plain
    # require must stay exactly as Rails-free as before it existed.
    code = "require 'claude_agent_sdk'; exit(defined?(ClaudeAgentSDK::Railtie) || defined?(Rails) ? 1 : 0)"
    _out, err, status = run_ruby(code)
    expect(status.exitstatus).to eq(0), "a non-Rails require must load neither Rails nor the Railtie: #{err}"
  end

  it 'lets the configuration file be required on its own' do
    # default_options= deep-copies through Type.deep_dup_for_options; a
    # standalone require of configuration.rb must bring that in itself.
    code = "require 'claude_agent_sdk/configuration'; " \
           "ClaudeAgentSDK::Configuration.new.default_options = { model: 'x' }"
    _out, err, status = run_ruby(code)
    expect(status.exitstatus).to eq(0), "standalone configuration require must work: #{err}"
  end
end
