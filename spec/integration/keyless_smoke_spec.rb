# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# A real-CLI smoke that needs no secret, so CI can run it on every PR that
# moves the pinned CLI (integration.yml, job keyless-smoke): the installed
# binary, the real transport, the control protocol, the message parser and
# the error path, against a CLI that has no credentials at all. It reaches
# no model: without credentials the CLI answers a prompt itself.
#
# It runs only with RUN_KEYLESS_SMOKE=1, and from then on it skips nothing:
# a missing CLI is a failure. The CLI is found the way the SDK finds it
# (CLAUDE_CLI_PATH, the vendored install, PATH):
#
#   bundle exec rake claude_agent_sdk:install_cli
#   RUN_KEYLESS_SMOKE=1 bundle exec rspec spec/integration/keyless_smoke_spec.rb
RSpec.describe 'The real CLI with no credentials', if: ENV['RUN_KEYLESS_SMOKE'] == '1' do
  around do |example|
    Dir.mktmpdir('keyless-smoke') do |home|
      @home = File.realpath(home)
      example.run
    end
  end

  # Nothing the CLI could authenticate with: a fresh HOME and config dir, no
  # settings files, and none of the variables that carry a key or a token or
  # pick a cloud provider (a developer machine may export any of them).
  def keyless_options(**options)
    env = { 'HOME' => @home, 'CLAUDE_CONFIG_DIR' => File.join(@home, '.claude'),
            'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }
    %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
       CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY].each { |name| env[name] = nil }
    ClaudeAgentSDK::ClaudeAgentOptions.new(cwd: @home, setting_sources: [], env: env, **options)
  end

  # Runs the block on a thread of its own: whatever the CLI does without
  # credentials, it must not leave the SDK waiting. Generous — a healthy run
  # takes a few seconds.
  def bounded(seconds = 120)
    worker = Thread.new do
      Thread.current.report_on_exception = false # re-raised below, by #value
      yield
    end
    return worker.value if worker.join(seconds)

    ClaudeAgentSDK::SubprocessCLITransport.kill_active_processes # the CLI is what it waits on
    worker.kill unless worker.join(30)
    raise "still running after #{seconds}s (the CLI was terminated to end the example)"
  end

  it 'completes the initialize handshake' do
    info = bounded do
      ClaudeAgentSDK::Client.open(options: keyless_options, &:server_info)
    end

    expect(info.fetch(:commands)).to include(a_hash_including(:name, :description))
    expect(info.fetch(:models)).to include(a_hash_including(:value))
    expect(info.fetch(:agents)).to include(a_hash_including(:name))
    expect(info.dig(:account, :tokenSource)).to eq('none')
  end

  it 'turns a prompt it cannot send into a typed failure' do
    messages = []
    error = bounded do
      ClaudeAgentSDK.query(prompt: 'Say hi', options: keyless_options(max_turns: 1)) { |message| messages << message }
      nil
    rescue ClaudeAgentSDK::ResultError => e
      e
    end

    expect(messages.map(&:class)).to eq([ClaudeAgentSDK::InitMessage, ClaudeAgentSDK::AssistantMessage,
                                         ClaudeAgentSDK::ResultMessage])
    assistant, result = messages.last(2)
    expect(assistant.error).to eq('authentication_failed')
    expect(result.is_error).to be(true)
    expect(result.total_cost_usd).to eq(0) # the CLI answered itself; no model was called
    expect(error).to be_a(ClaudeAgentSDK::ResultError)
    expect(error.exit_code).to eq(1)
  end
end
