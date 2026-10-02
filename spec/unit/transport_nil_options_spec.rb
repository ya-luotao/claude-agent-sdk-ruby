# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

# `env` and `extra_args` are signed nilable: the constructor fills in `{}`,
# but `options.dup_with(env: nil)` and `options.env = nil` — the natural way
# to clear one — keep the nil. The transport read both as Hashes.
RSpec.describe ClaudeAgentSDK::SubprocessCLITransport, 'options set back to nil' do
  after { described_class.active_processes.clear }

  around do |example|
    Dir.mktmpdir('nil-options-spec') do |dir|
      @dir = dir
      example.run
    end
  end

  let(:seen_sdk_version) { File.join(@dir, 'sdk-version') }

  # Answers the version probe; as a session it records the SDK version the
  # transport put in its environment, then ends the run.
  let(:fake_cli) do
    path = File.join(@dir, 'claude')
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "-v" ]; then
        echo '2.1.286 (Claude Code)'
        exit 0
      fi
      printf '%s' "$CLAUDE_AGENT_SDK_VERSION" > '#{seen_sdk_version}'
      printf '%s\\n' '#{JSON.generate(sample_result_message)}'
    SH
    File.chmod(0o755, path)
    path
  end

  let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: fake_cli) }

  def frame_types_from(transport)
    types = []
    transport.connect
    transport.read_messages { |frame| types << frame[:type] }
    types
  ensure
    transport.close
  end

  it 'connects when env was cleared with dup_with(env: nil)' do
    transport = described_class.new(options.dup_with(env: nil))

    expect(frame_types_from(transport)).to eq(['result'])
    # The SDK's own additions to the environment still reach the CLI.
    expect(File.read(seen_sdk_version)).to eq(ClaudeAgentSDK::VERSION)
  end

  it 'connects when env was cleared with the setter' do
    options.env = nil

    expect(frame_types_from(described_class.new(options))).to eq(['result'])
  end

  # CommandBuilder reads extra_args too and is nil-unsafe in the same way
  # (command_builder.rb, fixed separately); stubbing the argv keeps this
  # example on the transport's own read of the option.
  it 'connects when extra_args was cleared with dup_with(extra_args: nil)' do
    transport = described_class.new(options.dup_with(extra_args: nil))
    allow(transport).to receive(:build_command).and_return([fake_cli])

    expect(frame_types_from(transport)).to eq(['result'])
  end
end
