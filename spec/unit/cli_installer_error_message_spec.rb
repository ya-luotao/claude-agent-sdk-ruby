# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The message of the CLIInstallError that wraps a filesystem failure names the
# install directory. When resolving that directory is itself what failed (the
# default one, with the process's working directory deleted under it), the
# message used to read "… into : Errno::ENOENT: … getcwd".
RSpec.describe ClaudeAgentSDK::CLIInstaller, 'the message of a wrapped filesystem failure' do
  it 'names the default directory when the working directory no longer exists' do
    gone = Dir.mktmpdir('cli-installer-cwd')

    Dir.chdir(gone) do
      Dir.rmdir(gone)

      expect { described_class.install(version: '2.1.220') }
        .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error|
          expect(error.message).to start_with('Failed to install the Claude Code CLI into vendor/claude: Errno::ENOENT')
          expect(error.cause).to be_a(Errno::ENOENT)
        }
    end
  end

  it 'names the explicit directory otherwise' do
    Dir.mktmpdir('cli-installer-message') do |dir|
      blocked = File.join(dir, 'a-file')
      File.write(blocked, 'not a directory')

      expect { described_class.install(version: '2.1.220', dir: File.join(blocked, 'claude')) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, /\AFailed to install the Claude Code CLI into #{Regexp.escape(blocked)}/)
    end
  end
end
