# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClaudeAgentSDK::SessionSummary do
  def user_entry(text, timestamp: '2024-01-01T00:00:00.000Z', **extra)
    { 'type' => 'user', 'timestamp' => timestamp, 'message' => { 'content' => text } }.merge(extra.transform_keys(&:to_s))
  end

  let(:key) { { 'project_key' => 'proj', 'session_id' => 'sess' } }

  describe '.fold_session_summary' do
    it 'latches created_at from the first parseable timestamp and seeds session_id' do
      summary = described_class.fold_session_summary(nil, key, [user_entry('hi', timestamp: '2024-01-01T00:00:00.000Z')])
      expect(summary['session_id']).to eq('sess')
      expect(summary['mtime']).to eq(0) # fold never stamps mtime; adapter does
      expect(summary['data']['created_at']).to eq(Time.iso8601('2024-01-01T00:00:00.000Z').to_f.*(1000).to_i)
    end

    it 'extracts the first meaningful user prompt and locks it' do
      summary = described_class.fold_session_summary(nil, key, [user_entry('First real prompt')])
      expect(summary['data']['first_prompt']).to eq('First real prompt')
      expect(summary['data']['first_prompt_locked']).to be true
    end

    it 'does not overwrite a locked first_prompt on later appends' do
      first = described_class.fold_session_summary(nil, key, [user_entry('original')])
      second = described_class.fold_session_summary(first, key, [user_entry('later message')])
      expect(second['data']['first_prompt']).to eq('original')
    end

    it 'stashes a command_fallback for slash-command messages without locking first_prompt' do
      summary = described_class.fold_session_summary(nil, key, [user_entry('<command-name>/deploy</command-name>')])
      expect(summary['data']['command_fallback']).to eq('/deploy')
      expect(summary['data']['first_prompt_locked']).to be_nil
    end

    it 'skips auto-generated/system prompt patterns' do
      summary = described_class.fold_session_summary(nil, key, [user_entry('<local-command-stdout>noise</local-command-stdout>')])
      expect(summary['data']['first_prompt']).to be_nil
    end

    it 'truncates a long first prompt to 200 chars plus an ellipsis' do
      summary = described_class.fold_session_summary(nil, key, [user_entry('x' * 250)])
      expect(summary['data']['first_prompt']).to eq("#{'x' * 200}…")
    end

    it 'applies last-wins string fields across appends' do
      first = described_class.fold_session_summary(nil, key, [{ 'type' => 'x', 'customTitle' => 'A', 'gitBranch' => 'main' }])
      second = described_class.fold_session_summary(first, key, [{ 'type' => 'x', 'customTitle' => 'B' }])
      expect(second['data']['custom_title']).to eq('B')
      expect(second['data']['git_branch']).to eq('main')
    end

    it 'sets and then clears a tag' do
      tagged = described_class.fold_session_summary(nil, key, [{ 'type' => 'tag', 'tag' => 'release' }])
      expect(tagged['data']['tag']).to eq('release')
      cleared = described_class.fold_session_summary(tagged, key, [{ 'type' => 'tag', 'tag' => '' }])
      expect(cleared['data'].key?('tag')).to be false
    end

    it 'records is_sidechain set-once and cwd set-once' do
      summary = described_class.fold_session_summary(nil, key, [
                                                       { 'type' => 'x', 'isSidechain' => true, 'cwd' => '/work' },
                                                       { 'type' => 'x', 'cwd' => '/ignored' }
                                                     ])
      expect(summary['data']['is_sidechain']).to be true
      expect(summary['data']['cwd']).to eq('/work')
    end

    it 'skips tool_result-carrying user messages for first_prompt' do
      entry = { 'type' => 'user', 'timestamp' => '2024-01-01T00:00:00.000Z',
                'message' => { 'content' => [{ 'type' => 'tool_result', 'content' => 'x' }] } }
      summary = described_class.fold_session_summary(nil, key, [entry])
      expect(summary['data']['first_prompt']).to be_nil
    end

    it 'does not mutate the prev summary it was given' do
      first = described_class.fold_session_summary(nil, key, [user_entry('original')])
      snapshot = Marshal.load(Marshal.dump(first))
      described_class.fold_session_summary(first, key, [{ 'type' => 'x', 'customTitle' => 'changed' }])
      expect(first).to eq(snapshot)
    end
  end

  describe '.summary_entry_to_sdk_info' do
    def summary_with(data, session_id = 'sess', mtime = 1_700_000_000_000)
      { 'session_id' => session_id, 'mtime' => mtime, 'data' => data }
    end

    it 'builds an SDKSessionInfo from a folded summary' do
      summary = described_class.fold_session_summary(nil, key, [user_entry('Build me a thing', cwd: '/proj')])
      summary['mtime'] = 1_700_000_000_000
      info = described_class.summary_entry_to_sdk_info(summary, nil)
      expect(info).to be_a(ClaudeAgentSDK::SDKSessionInfo)
      expect(info.session_id).to eq('sess')
      expect(info.summary).to eq('Build me a thing')
      expect(info.first_prompt).to eq('Build me a thing')
      expect(info.last_modified).to eq(1_700_000_000_000)
      expect(info.file_size).to be_nil
      expect(info.cwd).to eq('/proj')
    end

    it 'returns nil for sidechain sessions' do
      expect(described_class.summary_entry_to_sdk_info(summary_with('is_sidechain' => true), nil)).to be_nil
    end

    it 'returns nil when no summary can be derived' do
      expect(described_class.summary_entry_to_sdk_info(summary_with({}), nil)).to be_nil
    end

    it 'prefers custom_title over last_prompt/summary_hint/first_prompt' do
      info = described_class.summary_entry_to_sdk_info(
        summary_with('custom_title' => 'Title', 'last_prompt' => 'lp', 'first_prompt' => 'fp',
                     'first_prompt_locked' => true), nil
      )
      expect(info.summary).to eq('Title')
      expect(info.custom_title).to eq('Title')
    end

    it 'falls back to command_fallback for first_prompt when not locked' do
      info = described_class.summary_entry_to_sdk_info(summary_with('command_fallback' => '/deploy'), nil)
      expect(info.summary).to eq('/deploy')
      expect(info.first_prompt).to eq('/deploy')
    end

    it 'treats empty strings as absent (presence semantics)' do
      info = described_class.summary_entry_to_sdk_info(
        summary_with('custom_title' => '', 'last_prompt' => 'real', 'git_branch' => '', 'tag' => ''), nil
      )
      expect(info.summary).to eq('real')
      expect(info.custom_title).to be_nil
      expect(info.git_branch).to be_nil
      expect(info.tag).to be_nil
    end

    it 'uses project_path as the cwd fallback' do
      info = described_class.summary_entry_to_sdk_info(summary_with('last_prompt' => 'x'), '/fallback')
      expect(info.cwd).to eq('/fallback')
    end
  end
end
