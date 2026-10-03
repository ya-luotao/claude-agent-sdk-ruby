# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# Subagent transcripts live at <session>/subagents/agent-<id>.jsonl and may
# nest under workflows/<runId>/. An id is one subagent wherever its
# transcripts sit: the message and metadata readers take the first match.
RSpec.describe 'list_subagents on disk' do
  include_context 'with a Claude config dir'

  let(:session_id) { 'b2a1c0d9-e8f7-4a6b-9c5d-4e3f2a1b0c9d' }

  before { allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees) { |path| [path] } }

  def write_subagent(agent_id, *nesting)
    transcript = CLITranscript.new(session_id: session_id, cwd: cwd, agent_id: agent_id)
    transcript.prompt(:task, 'Read a.rb')
    transcript.assistant(:report, transcript.text('It defines Foo.'), parent: :task)
    transcript.write(File.join(project_dir_for(cwd), session_id, 'subagents', *nesting, "agent-#{agent_id}.jsonl"))
  end

  before do
    parent = CLITranscript.new(session_id: session_id, cwd: cwd)
    parent.prompt(:prompt, 'Use subagents to read a.rb')
    parent.write(transcript_path(session_id))
  end

  it 'returns an id once when its transcript exists at two depths' do
    write_subagent('a1b2c3')
    write_subagent('a1b2c3', 'workflows', 'run-1')
    write_subagent('d4e5f6', 'workflows', 'run-1')

    expect(ClaudeAgentSDK.list_subagents(session_id: session_id, directory: cwd)).to eq(%w[a1b2c3 d4e5f6])
  end
end
