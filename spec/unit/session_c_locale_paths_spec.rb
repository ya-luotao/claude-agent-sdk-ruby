# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# Under LANG=C / LC_ALL=C (minimal Docker images, cron, systemd) Ruby hands
# out the paths it gets from the system — ENV values, Dir.pwd, File.realpath,
# File.readlink — tagged BINARY or US-ASCII. They are UTF-8 all the same. The
# locale of a process is fixed when it starts, so this runs the SDK in a
# child process.
RSpec.describe 'session paths under a non-UTF-8 locale' do
  include_context 'with a Claude config dir'

  let(:session_id) { '7e6f5d4c-3b2a-4190-8f7e-6d5c4b3a2910' }
  let(:accented) { "caf#{[0xE9].pack('U')}" } # "café", NFC

  # The start of each child script. A String is reported as hex (the pipe
  # back is read as bytes) with its encoding, an error as its class and
  # message.
  let(:prelude) do
    <<~'RUBY'
      require 'claude_agent_sdk'
      require 'json'
      report = lambda do |value|
        value.is_a?(String) ? [value.unpack1('H*'), value.encoding.name, value.valid_encoding?] : value
      end
      attempt = lambda do |&block|
        report.call(block.call)
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end
    RUBY
  end

  def hex(string)
    [string.unpack1('H*'), 'UTF-8', true]
  end

  def key_of(path)
    hex(ClaudeAgentSDK::Sessions.sanitize_path(path))
  end

  def record_session(directory, config = config_dir)
    transcript = CLITranscript.new(session_id: session_id, cwd: directory)
    transcript.prompt(:prompt, 'hi')
    transcript.write(File.join(config, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(directory),
                               "#{session_id}.jsonl"))
  end

  # What +script+ prints as JSON in a child started with LC_ALL=C in +chdir+.
  def run_under_c_locale(script, chdir:, **env)
    env = { 'LC_ALL' => 'C', 'LANG' => 'C', 'LC_CTYPE' => 'C' }.merge(env.transform_keys(&:to_s))
    output, errors, status = Open3.capture3(env, RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__),
                                            '-e', "#{prelude}\n#{script}", chdir: chdir)
    raise "probe failed: #{errors}" unless status.success?

    JSON.parse(output)
  end

  it 'reads a non-ASCII CLAUDE_CONFIG_DIR and lists the sessions of Dir.pwd' do
    config = File.join(cwd, "#{accented}-config")
    project = File.join(cwd, "#{accented}-project").tap { |dir| FileUtils.mkdir_p(dir) }
    record_session(project, config)
    script = <<~RUBY
      puts JSON.generate(
        'external' => Encoding.default_external.name,
        'config_dir' => attempt.call { ClaudeAgentSDK::Sessions.config_dir },
        'projects_dir' => attempt.call { ClaudeAgentSDK::SessionStores.projects_dir },
        'key_for_pwd' => attempt.call { ClaudeAgentSDK.project_key_for_directory(Dir.pwd) },
        'key_for_default' => attempt.call { ClaudeAgentSDK.project_key_for_directory },
        'listed_for_pwd' => attempt.call { ClaudeAgentSDK.list_sessions(directory: Dir.pwd).map(&:session_id) }
      )
    RUBY

    seen = run_under_c_locale(script, chdir: project, CLAUDE_CONFIG_DIR: config)

    expect(seen['external']).to eq('US-ASCII')
    expect(seen['config_dir']).to eq(hex(config))
    expect(seen['projects_dir']).to eq(hex(File.join(config, 'projects')))
    expect(seen['key_for_pwd']).to eq(key_of(project))
    expect(seen['key_for_default']).to eq(seen['key_for_pwd'])
    expect(seen['listed_for_pwd']).to eq([session_id])
  end

  # A path File.realpath cannot resolve is walked component by component.
  # The walk joins what it is given with the working directory (BINARY here)
  # and with the targets of the links on the way (US-ASCII here, whatever
  # their bytes): a session recorded in café-checkout, reached through the
  # link `current` after café-checkout was removed, and a relative path with
  # a non-ASCII name of its own.
  it 'resolves a missing path through a link with a non-ASCII target, and a non-ASCII relative one' do
    checkout = File.join(cwd, "#{accented}-checkout")
    link = File.join(cwd, 'current').tap { |path| File.symlink(checkout, path) }
    project = File.join(cwd, "#{accented}-project").tap { |dir| FileUtils.mkdir_p(dir) }
    record_session(checkout)
    script = <<~'RUBY'
      link = ENV.fetch('SESSION_LINK')
      id = ENV.fetch('SESSION_ID')
      puts JSON.generate(
        'key_through_link' => attempt.call { ClaudeAgentSDK.project_key_for_directory(link) },
        'listed_through_link' => attempt.call { ClaudeAgentSDK.list_sessions(directory: link).map(&:session_id) },
        'title_after_rename' => attempt.call do
          ClaudeAgentSDK.rename_session(session_id: id, title: 'Old checkout', directory: link)
          ClaudeAgentSDK.get_session_info(session_id: id, directory: link).custom_title
        end,
        'key_for_relative' => attempt.call { ClaudeAgentSDK.project_key_for_directory("caf#{[0xE9].pack('U')}-gone") }
      )
    RUBY

    seen = run_under_c_locale(script, chdir: project, CLAUDE_CONFIG_DIR: config_dir, SESSION_LINK: link,
                                      SESSION_ID: session_id)

    expect(seen['key_through_link']).to eq(key_of(checkout))
    expect(seen['listed_through_link']).to eq([session_id])
    expect(seen['title_after_rename']).to eq(hex('Old checkout'))
    expect(seen['key_for_relative']).to eq(key_of(File.join(project, "#{accented}-gone")))
  end
end
