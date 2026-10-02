# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# Under LANG=C / LC_ALL=C (minimal Docker images, cron, systemd) Ruby hands
# out the paths it gets from the system — ENV values, Dir.pwd, File.realpath —
# tagged BINARY or US-ASCII. They are UTF-8 all the same. The locale of a
# process is fixed when it starts, so this runs the SDK in a child process.
RSpec.describe 'session paths under a non-UTF-8 locale' do
  include_context 'with a Claude config dir'

  let(:session_id) { '7e6f5d4c-3b2a-4190-8f7e-6d5c4b3a2910' }
  let(:accented) { "caf#{[0xE9].pack('U')}" } # "café", NFC

  # What the SDK reports in a child started with LC_ALL=C, as hex (the pipe
  # back is read as bytes) plus the encoding of each value.
  let(:probe) do
    <<~'RUBY'
      require 'claude_agent_sdk'
      require 'json'
      report = lambda do |value|
        value.is_a?(String) ? [value.unpack1('H*'), value.encoding.name, value.valid_encoding?] : value
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end
      attempt = lambda do |&block|
        report.call(block.call)
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end
      puts JSON.generate(
        'external' => Encoding.default_external.name,
        'config_dir' => attempt.call { ClaudeAgentSDK::Sessions.config_dir },
        'projects_dir' => attempt.call { ClaudeAgentSDK::SessionStores.projects_dir },
        'key_for_pwd' => attempt.call { ClaudeAgentSDK.project_key_for_directory(Dir.pwd) },
        'key_for_default' => attempt.call { ClaudeAgentSDK.project_key_for_directory },
        'listed_for_pwd' => attempt.call { ClaudeAgentSDK.list_sessions(directory: Dir.pwd).map(&:session_id) }
      )
    RUBY
  end

  def hex(string)
    [string.unpack1('H*'), 'UTF-8', true]
  end

  def run_under_c_locale(chdir:, config:)
    env = { 'LC_ALL' => 'C', 'LANG' => 'C', 'LC_CTYPE' => 'C', 'CLAUDE_CONFIG_DIR' => config }
    output, errors, status = Open3.capture3(env, RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__),
                                            '-e', probe, chdir: chdir)
    raise "probe failed: #{errors}" unless status.success?

    JSON.parse(output)
  end

  it 'reads a non-ASCII CLAUDE_CONFIG_DIR and lists the sessions of Dir.pwd' do
    config = File.join(cwd, "#{accented}-config")
    project = File.join(cwd, "#{accented}-project").tap { |dir| FileUtils.mkdir_p(dir) }
    transcript = CLITranscript.new(session_id: session_id, cwd: project)
    transcript.prompt(:prompt, 'hi')
    transcript.write(File.join(config, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(project),
                               "#{session_id}.jsonl"))

    seen = run_under_c_locale(chdir: project, config: config)

    expect(seen['external']).to eq('US-ASCII')
    expect(seen['config_dir']).to eq(hex(config))
    expect(seen['projects_dir']).to eq(hex(File.join(config, 'projects')))
    expect(seen['key_for_pwd']).to eq(hex(ClaudeAgentSDK::Sessions.sanitize_path(project)))
    expect(seen['key_for_default']).to eq(seen['key_for_pwd'])
    expect(seen['listed_for_pwd']).to eq([session_id])
  end
end
