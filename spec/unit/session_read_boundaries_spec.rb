# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# Boundary cases of the session readers and mutations, one group per case.
RSpec.describe 'session API boundaries' do
  include_context 'with a Claude config dir'

  let(:session_id) { 'c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f' }

  before { allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees) { |path| [path] } }

  def conversation(directory = cwd)
    transcript = CLITranscript.new(session_id: session_id, cwd: directory)
    transcript.queue_operations('what does a.rb define?')
    transcript.prompt(:prompt, 'what does a.rb define?')
    transcript.assistant(:answer, transcript.text('Foo.'), parent: :prompt)
    transcript.last_prompt('what does a.rb define?', leaf: :answer)
    transcript
  end

  # A config dir path is data, not a pattern: `/Volumes/Data [SSD]/claude`,
  # `/srv/{tenant}/claude`.
  describe 'a config dir whose path contains glob characters' do
    ['cfg [prod]', 'tenant{a,b}'].each do |name|
      it "lists the sessions under #{name.inspect}" do
        ENV['CLAUDE_CONFIG_DIR'] = File.join(config_dir, name)
        conversation.write(File.join(ENV.fetch('CLAUDE_CONFIG_DIR'), 'projects',
                                     ClaudeAgentSDK::Sessions.sanitize_path(cwd), "#{session_id}.jsonl"))

        expect(ClaudeAgentSDK.list_sessions(directory: cwd).map(&:session_id)).to eq([session_id])
        expect(ClaudeAgentSDK.list_sessions.map(&:session_id)).to eq([session_id])
      end
    end
  end
end
