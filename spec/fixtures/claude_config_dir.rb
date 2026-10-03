# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# A private Claude config dir and a project directory for one example, both
# real and canonical (macOS tmpdirs sit behind the /var symlink), reached
# through CLAUDE_CONFIG_DIR exactly as an application would set it.
RSpec.shared_context 'with a Claude config dir' do
  attr_reader :config_dir, :cwd

  around do |example|
    saved = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
    Dir.mktmpdir('claude-config') do |config|
      Dir.mktmpdir('claude-project') do |project|
        @config_dir = File.realpath(config)
        @cwd = File.realpath(project)
        ENV['CLAUDE_CONFIG_DIR'] = @config_dir
        example.run
      end
    end
  ensure
    saved.nil? ? ENV.delete('CLAUDE_CONFIG_DIR') : ENV['CLAUDE_CONFIG_DIR'] = saved
  end

  # The directory the CLI keeps a project's transcripts in.
  def project_dir_for(path)
    File.join(config_dir, 'projects', ClaudeAgentSDK::Sessions.sanitize_path(path))
  end

  def transcript_path(session_id, path = cwd)
    File.join(project_dir_for(path), "#{session_id}.jsonl")
  end

  def subagent_transcript_path(session_id, agent_id, path = cwd)
    File.join(project_dir_for(path), session_id, 'subagents', "agent-#{agent_id}.jsonl")
  end
end
