# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# A fork made without a title is named after its source: "<title> (fork)".
# The title is the one the listing shows for the source — the custom title,
# else the AI title, else the first prompt — whichever path forks it.
RSpec.describe 'the title fork_session derives for a fork' do
  include_context 'with a Claude config dir'

  let(:session_id) { 'f1e2d3c4-b5a6-4978-8695-a4b3c2d1e0f9' }
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }
  let(:key) { { 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id } }

  # [title shown for the source, title of its disk fork, title of its store fork]
  def titles(title: nil)
    transcript = CLITranscript.new(session_id: session_id, cwd: cwd)
    yield transcript
    transcript.write(transcript_path(session_id))
    store.append(key, transcript.store_entries)
    source = ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd)
    [source && (source.custom_title || source.first_prompt), fork_title(title), fork_title(title, session_store: store)]
  end

  # The title of a fork of the source, made on disk or in the store.
  def fork_title(title, **where)
    fork = ClaudeAgentSDK.fork_session(session_id: session_id, directory: cwd, title: title, **where)
    ClaudeAgentSDK.get_session_info(session_id: fork.session_id, directory: cwd, **where).custom_title
  end

  def exchange(transcript)
    transcript.prompt(:prompt, 'my first prompt')
    transcript.assistant(:answer, transcript.text('Answered.'), parent: :prompt)
  end

  it 'is the custom title of the source' do
    expect(titles { |t| exchange(t) && t.custom_title('Refactoring') })
      .to eq(['Refactoring', 'Refactoring (fork)', 'Refactoring (fork)'])
  end

  it 'is the AI title when the custom title was cleared' do
    shown = titles do |t|
      exchange(t)
      t.custom_title('Old title')
      t.ai_title('AI title')
      t.custom_title('')
    end

    expect(shown).to eq(['AI title', 'AI title (fork)', 'AI title (fork)'])
  end

  it 'is the first prompt when the custom title was cleared and there is no AI title' do
    shown = titles do |t|
      exchange(t)
      t.custom_title('Old title')
      t.custom_title('')
    end

    expect(shown).to eq(['my first prompt', 'my first prompt (fork)', 'my first prompt (fork)'])
  end

  it 'is not a customTitle key nested in a tool input' do
    shown = titles do |t|
      t.prompt(:prompt, 'my first prompt')
      t.assistant(:use, t.tool_use('toolu_a', 'RenameThing', { 'customTitle' => 'TOOL ARGUMENT' }), parent: :prompt)
      t.tool_result(:result, 'toolu_a', 'renamed', parent: :use)
      t.assistant(:answer, t.text('Renamed.'), parent: :result, message: 'msg_02')
    end

    expect(shown).to eq(['my first prompt', 'my first prompt (fork)', 'my first prompt (fork)'])
  end

  it 'is the first prompt when it lies beyond the 64 KiB head' do
    shown = titles do |t|
      t.attachment(:hook, parent: nil, hook: 'SessionStart', stdout: 'A' * 92_000)
      t.prompt(:prompt, 'my first prompt', parent: :hook)
      t.assistant(:answer, t.text('Answered.'), parent: :prompt)
    end

    expect(shown).to eq(['my first prompt', 'my first prompt (fork)', 'my first prompt (fork)'])
  end

  # Nothing to list it under, still a conversation to fork.
  it 'is the default when the source has no title and no prompt' do
    shown = titles do |t|
      t.meta(:skill_body, '<system-reminder>context</system-reminder>', parent: nil)
      t.assistant(:answer, t.text('Noted.'), parent: :skill_body)
    end

    expect(shown).to eq([nil, 'Forked session (fork)', 'Forked session (fork)'])
  end

  it 'is the title the caller gives' do
    expect(titles(title: 'Experiment') { |t| exchange(t) && t.custom_title('Refactoring') })
      .to eq(%w[Refactoring Experiment Experiment])
  end
end
