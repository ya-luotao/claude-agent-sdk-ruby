# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'stringio'
require 'tmpdir'

# `sandbox: { enabled: true }` asks for a sandbox; when the CLI cannot start
# one (and failIfUnavailable is not set) it says so on stderr and carries on
# unsandboxed. An SDK host never sees that line unless it passed a `stderr:`
# callback, so the transport repeats it as a Ruby warning.
RSpec.describe ClaudeAgentSDK::SubprocessCLITransport, 'unavailable sandbox warning' do
  after { described_class.active_processes.clear }

  around do |example|
    Dir.mktmpdir('sandbox-warning-spec') do |dir|
      @dir = dir
      example.run
    end
  end

  # Byte for byte what CLI 2.1.286 / 2.1.287 write at startup
  # (`process.stderr.write(`\n⚠ Sandbox disabled: ${reason}\n  Commands
  # will run WITHOUT sandboxing. ...\n\n`)`), with the reason the CLI builds
  # on a Linux host that has neither bubblewrap nor socat.
  let(:unavailable_reason) do
    'sandbox is enabled but dependencies are missing: ' \
      'bubblewrap (bwrap) not installed, socat not installed ' \
      '· install missing tools (e.g. apt install bubblewrap socat) ' \
      'or see https://code.claude.com/docs/en/sandboxing'
  end
  let(:cli_line) { "⚠ Sandbox disabled: #{unavailable_reason}" }
  let(:cli_notice) do
    "\n#{cli_line}\n  " \
      "Commands will run WITHOUT sandboxing. Network and filesystem restrictions will NOT be enforced.\n\n"
  end

  # Writes +stderr_text+ to stderr, then ends the run (with a result frame
  # unless +result+ is false).
  def install_fake_cli(stderr_text, exit_status: 0, result: true)
    stderr_file = File.join(@dir, 'stderr.txt')
    File.write(stderr_file, stderr_text)
    path = File.join(@dir, 'claude')
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "-v" ]; then
        echo '2.1.286 (Claude Code)'
        exit 0
      fi
      cat '#{stderr_file}' >&2
      #{"printf '%s\\n' '#{JSON.generate(sample_result_message)}'" if result}
      exit #{exit_status}
    SH
    File.chmod(0o755, path)
    path
  end

  # Everything written to $stderr while a session runs to its end. The
  # warning is issued on the stderr drain thread, so the swap covers that
  # thread's whole life: it ends at EOF, when the fake has exited.
  def stderr_during_session(transport, stderr: StringIO.new)
    original = $stderr
    $stderr = stderr
    begin
      transport.connect
      # Bounded: a drain that died or stalls fails the example instead of hanging the suite.
      raise 'the stderr drain did not finish' unless transport.instance_variable_get(:@stderr_task).join(15)

      transport.read_messages { |_frame| nil }
    ensure
      $stderr = original
      transport.close
    end
    stderr.string if stderr.respond_to?(:string)
  end

  def transport_with(**values)
    described_class.new(ClaudeAgentSDK::ClaudeAgentOptions.new(**values))
  end

  # The real CLI prints the notice once; twice pins "one warning per
  # transport" rather than "one warning per line".
  let(:cli) { install_fake_cli(cli_notice * 2) }

  {
    'a SandboxSettings with enabled: true' => -> { ClaudeAgentSDK::SandboxSettings.new(enabled: true) },
    'a Hash with enabled: true' => -> { { enabled: true } },
    'a Hash with a String "enabled" key' => -> { { 'enabled' => true } },
    # Either key saying true is a request, whatever the other one says (the
    # command line carries the later of the two).
    'a Hash whose Symbol key says true and whose String key says false' => -> { { enabled: true, 'enabled' => false } },
    'a Hash whose String key says true and whose Symbol key says false' => -> { { enabled: false, 'enabled' => true } },
    'sandbox: true' => -> { true }
  }.each do |description, sandbox|
    it "warns once when the sandbox was requested by #{description}" do
      output = stderr_during_session(transport_with(cli_path: cli, sandbox: sandbox.call))

      expect(output.scan('[claude-agent-sdk]').size).to eq(1)
      expect(output).to include(cli_line).and include('fail_if_unavailable: true')
    end
  end

  it 'warns once on the stderr-callback path too, and still hands the callback the line' do
    seen = []
    transport = transport_with(cli_path: cli, sandbox: { enabled: true }, stderr: ->(line) { seen << line })

    output = stderr_during_session(transport)

    expect(output.scan('[claude-agent-sdk]').size).to eq(1)
    expect(seen.count(cli_line)).to eq(2)
  end

  {
    'no sandbox option' => -> {},
    'sandbox: false' => -> { false },
    'a Hash with enabled: false' => -> { { enabled: false } },
    'an empty Hash' => -> { {} },
    # Only true is a request.
    'a Hash whose enabled is truthy but not true' => -> { { enabled: 'true', 'enabled' => 1 } },
    'a SandboxSettings with enabled: false' => -> { ClaudeAgentSDK::SandboxSettings.new(enabled: false) },
    'a SandboxSettings that leaves enabled unset' => -> { ClaudeAgentSDK::SandboxSettings.new }
  }.each do |description, sandbox|
    it "stays silent with #{description}" do
      output = stderr_during_session(transport_with(cli_path: cli, sandbox: sandbox.call))

      expect(output).to be_empty
    end
  end

  # With failIfUnavailable the CLI does not carry on unsandboxed: it prints
  # this instead (2.1.286 / 2.1.287, same startup branch) and exits 1, which
  # the session already reports as a ProcessError carrying the text.
  it 'stays silent when the CLI refuses to start without the sandbox' do
    refusal = "\nError: sandbox required but unavailable: #{unavailable_reason}\n  " \
              "sandbox.failIfUnavailable is set — refusing to start without a working sandbox.\n\n"
    refusing_cli = install_fake_cli(refusal, exit_status: 1, result: false)
    transport = transport_with(cli_path: refusing_cli, sandbox: { enabled: true, failIfUnavailable: true })
    captured = StringIO.new

    expect { stderr_during_session(transport, stderr: captured) }.to raise_error(ClaudeAgentSDK::ProcessError)
    expect(captured.string).to be_empty
  end

  # A host's $stderr can be a pipe nobody reads any more, or a custom sink
  # that fails in a way that is not a StandardError. The warning is advisory:
  # failing to print it must not end the drain, or the CLI stalls on a full
  # stderr pipe.
  {
    Errno::EPIPE => 'a pipe nobody reads any more',
    NotImplementedError => 'an abstract sink',
    LoadError => 'a sink that cannot load its code',
    SystemStackError => 'a sink that recurses'
  }.each do |error_class, what|
    it "keeps draining when $stderr raises #{error_class} (#{what})" do
      broken = Object.new
      broken.define_singleton_method(:write) { |*| raise error_class }
      # spawn flushes $stderr before it forks
      def broken.flush = self
      failing_cli = install_fake_cli("#{cli_notice}a later stderr line\n", exit_status: 1)
      transport = transport_with(cli_path: failing_cli, sandbox: { enabled: true })

      expect { stderr_during_session(transport, stderr: broken) }
        .to raise_error(ClaudeAgentSDK::ProcessError) { |error|
          expect(error.stderr.lines.last).to eq('a later stderr line')
        }
    end
  end
end
