# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

# The `stderr:` callback runs on the transport's stderr drain thread. An
# exception that is not a StandardError (NotImplementedError and LoadError
# are ScriptErrors; SystemStackError is its own branch) used to end that
# thread. Nothing read the pipe any more, and a CLI that then wrote more than
# one pipe buffer of stderr (64 KiB) blocked in write(2) for good.
RSpec.describe ClaudeAgentSDK::SubprocessCLITransport, 'stderr callback isolation' do
  after { described_class.active_processes.clear }

  around do |example|
    Dir.mktmpdir('stderr-callback-spec') do |dir|
      @dir = dir
      example.run
    end
  end

  # 800 lines of ~120 bytes: about 94 KiB, well past one pipe buffer.
  let(:stderr_line_count) { 800 }
  let(:last_stderr_line) { format('stderr line %<n>04d %<pad>s', n: stderr_line_count - 1, pad: 'x' * 100) }

  # Fills stderr, then ends the way a failed run does: a result frame on
  # stdout and a non-zero exit — which is when the SDK reports what it kept
  # of stderr (ProcessError#stderr).
  let(:fake_cli) do
    path = File.join(@dir, 'claude')
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "-v" ]; then
        echo '2.1.286 (Claude Code)'
        exit 0
      fi
      pad=#{'x' * 100}
      i=0
      while [ "$i" -lt #{stderr_line_count} ]; do
        printf 'stderr line %04d %s\\n' "$i" "$pad" >&2
        i=$((i + 1))
      done
      printf '%s\\n' '#{JSON.generate(sample_result_message)}'
      exit 1
    SH
    File.chmod(0o755, path)
    path
  end

  {
    NotImplementedError => 'Logger#write is abstract',
    LoadError => 'cannot load such file -- some_logger',
    SystemStackError => 'stack level too deep'
  }.each do |error_class, message|
    it "keeps draining after the callback raises #{error_class} on the first line" do
      seen = []
      callback = lambda do |line|
        seen << line
        raise error_class, message if seen.size == 1
      end
      transport = described_class.new(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: fake_cli, stderr: callback))
      frames = []

      begin
        transport.connect
        # A drain thread the callback killed leaves the fake blocked on a
        # full pipe, short of its result frame, so reading stdout would
        # hang. Joining the thread first reports that as the callback's own
        # exception instead.
        transport.instance_variable_get(:@stderr_task).join

        expect { transport.read_messages { |frame| frames << frame } }
          .to raise_error(ClaudeAgentSDK::ProcessError) { |error|
            expect(error.exit_code).to eq(1)
            expect(error.stderr.lines.last).to eq(last_stderr_line)
          }
      ensure
        transport.close
      end

      expect(frames.map { |frame| frame[:type] }).to eq(['result'])
      expect(seen.size).to eq(stderr_line_count)
      expect(seen.last).to eq(last_stderr_line)
    end
  end
end
