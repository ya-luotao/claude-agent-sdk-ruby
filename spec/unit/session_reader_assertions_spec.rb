# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# Behavior of the disk readers that no example pinned: each of these stayed
# green with the line that implements it removed.
RSpec.describe 'disk session readers' do
  include_context 'with a Claude config dir'

  let(:session_id) { 'd4c3b2a1-0f9e-4d8c-8b7a-6f5e4d3c2b1a' }

  before { allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees) { |path| [path] } }

  def transcript
    @transcript ||= CLITranscript.new(session_id: session_id, cwd: cwd)
  end

  def listed
    transcript.write(transcript_path(session_id))
    ClaudeAgentSDK.list_sessions(directory: cwd)
  end

  # A session opened and closed without a prompt: the CLI wrote its opening
  # metadata lines and a hook attachment, nothing to show the session under.
  it 'do not list a transcript with no title, summary or prompt' do
    transcript.mode
    transcript.permission_mode
    transcript.attachment(:hook, parent: nil, hook: 'SessionStart')

    expect(listed).to eq([])
    expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd)).to be_nil
  end

  it 'list a transcript again once it has a prompt' do
    transcript.mode
    transcript.attachment(:hook, parent: nil, hook: 'SessionStart')
    transcript.prompt(:prompt, 'what does a.rb define?', parent: :hook)

    expect(listed.map(&:summary)).to eq(['what does a.rb define?'])
  end

  # prompt ─ skill_body (isMeta) ─ answer ─ note (a teammate's message) ─ reply
  it 'leave meta entries and teammate entries out of the messages of a conversation' do
    transcript.prompt(:prompt, '<command-name>/simplify</command-name>')
    transcript.meta(:skill_body, [transcript.text('# Simplify: review the changed code')], parent: :prompt)
    transcript.assistant(:answer, transcript.text('Simplified.'), parent: :skill_body)
    transcript.prompt(:note, 'Reviewer: looks fine.', parent: :answer, teamName: 'crew', agentName: 'reviewer')
    transcript.assistant(:reply, transcript.text('Thanks.'), parent: :note, message: 'msg_02')
    transcript.write(transcript_path(session_id))

    messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

    expect(transcript.labels(messages)).to eq(%w[prompt answer reply])
  end

  describe 'summary' do
    # An older CLI wrote {"type":"summary"} entries; a current one writes
    # last-prompt at exit. A transcript resumed across versions has both.
    def summary_entry(text)
      transcript.raw({ 'type' => 'summary', 'summary' => text, 'leafUuid' => transcript.id(:answer) })
    end

    before do
      transcript.prompt(:prompt, 'what does a.rb define?')
      transcript.assistant(:answer, transcript.text('Foo.'), parent: :prompt)
    end

    it 'is the last prompt when the tail holds a last-prompt and a summary entry' do
      summary_entry('Exploring a.rb')
      transcript.last_prompt('and b.rb?', leaf: :answer)

      expect(listed.map(&:summary)).to eq(['and b.rb?'])
    end

    it 'is the summary entry when there is no last-prompt entry' do
      summary_entry('Exploring a.rb')

      expect(listed.map(&:summary)).to eq(['Exploring a.rb'])
    end
  end
end
