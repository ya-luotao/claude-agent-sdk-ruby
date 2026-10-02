# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# A session can end on an entry the CLI wrote itself: the body of a slash
# command or skill, a stop-hook message, a system reminder (isMeta: true),
# never answered because the user closed the session first. The conversation
# before it is still there to read.
RSpec.describe 'reading a session whose last entry is a meta injection' do
  include_context 'with a Claude config dir'

  let(:session_id) { '9e4b7a61-0c2d-4f38-8b15-6a7c8d9e0f12' }
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }

  def transcript
    @transcript ||= CLITranscript.new(session_id: session_id, cwd: cwd)
  end

  def exchange
    transcript.prompt(:prompt, 'What does a.rb define?')
    transcript.assistant(:answer, transcript.text('It defines Foo.'), parent: :prompt)
    transcript.system(:stop_hook, parent: :answer)
  end

  def from_disk
    transcript.write(transcript_path(session_id))
    transcript.labels(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd))
  end

  def from_store
    key = { 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id }
    store.append(key, transcript.store_entries)
    transcript.labels(
      ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd, session_store: store)
    )
  end

  # prompt ─ answer ─ stop_hook ─ reminder (isMeta, the last entry)
  context 'when the meta entry is the last entry of the file' do
    before do
      exchange
      transcript.meta(:reminder, '<system-reminder>The task list is empty.</system-reminder>', parent: :stop_hook)
    end

    it('returns the conversation before it from disk') { expect(from_disk).to eq(%w[prompt answer]) }
    it('returns the conversation before it from a store') { expect(from_store).to eq(%w[prompt answer]) }
  end

  # prompt ─ answer ─ stop_hook ─ command ─ skill_body (isMeta) ─ attachment (the last entry)
  context 'when an attachment hangs off the meta entry' do
    before do
      exchange
      transcript.prompt(:command, '<command-name>/simplify</command-name>', parent: :stop_hook)
      transcript.meta(:skill_body, [transcript.text('# Simplify: review the changed code')], parent: :command)
      transcript.attachment(:listing, parent: :skill_body, type: 'skill_listing')
    end

    it('returns the conversation before it from disk') { expect(from_disk).to eq(%w[prompt answer command]) }
    it('returns the conversation before it from a store') { expect(from_store).to eq(%w[prompt answer command]) }
  end

  # The same ending, plus a later branch with nothing to show: a subagent
  # recorded in the main transcript (isSidechain: true), written after the
  # meta entry. Its leaf is the latest in the file and its path to the root
  # holds no visible message.
  context 'when a sidechain branch was written after the meta entry' do
    before do
      exchange
      transcript.meta(:reminder, '<system-reminder>The task list is empty.</system-reminder>', parent: :stop_hook)
      transcript.prompt(:side_prompt, 'Explore the repository', parent: nil, isSidechain: true)
      transcript.assistant(:side_answer, transcript.text('Explored.'), parent: :side_prompt, isSidechain: true)
    end

    it('reads the conversation, not the sidechain, from disk') { expect(from_disk).to eq(%w[prompt answer]) }
    it('reads the conversation, not the sidechain, from a store') { expect(from_store).to eq(%w[prompt answer]) }
  end

  # A corrupt transcript: the parentUuid links of the later branch form a cycle.
  it 'reads the conversation when the other branch loops back on itself' do
    exchange
    transcript.meta(:reminder, '<system-reminder>The task list is empty.</system-reminder>', parent: :stop_hook)
    transcript.prompt(:loop_a, 'Explore the repository', parent: :loop_b, isSidechain: true)
    transcript.assistant(:loop_b, transcript.text('Explored.'), parent: :loop_a, isSidechain: true)
    transcript.attachment(:loop_tail, parent: :loop_b, isSidechain: true)

    expect(from_disk).to eq(%w[prompt answer])
  end

  it 'still returns nothing for a transcript written by a teammate throughout' do
    teammate = { teamName: 'crew', agentName: 'reviewer' }
    transcript.prompt(:prompt, 'Review the diff', **teammate)
    transcript.assistant(:answer, transcript.text('Looks fine.'), parent: :prompt, **teammate)

    expect(from_disk).to eq([])
  end

  it 'still returns nothing for a transcript without any user or assistant entry' do
    transcript.attachment(:environment, parent: nil, type: 'environment')
    transcript.attachment(:model, parent: :environment, type: 'model')

    expect(from_disk).to eq([])
  end

  it 'prefers the answered branch when the conversation went on after a meta entry' do
    exchange
    transcript.meta(:reminder, '<system-reminder>The task list is empty.</system-reminder>', parent: :stop_hook)
    transcript.prompt(:follow_up, 'And b.rb?', parent: :reminder)
    transcript.assistant(:second_answer, transcript.text('It defines Bar.'), parent: :follow_up, message: 'msg_02')

    expect(from_disk).to eq(%w[prompt answer follow_up second_answer])
  end
end
