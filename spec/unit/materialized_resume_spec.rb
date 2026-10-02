# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

RSpec.describe ClaudeAgentSDK::MaterializedResume do
  # When the mirror dropped batches the materialized config dir is kept, since
  # it holds the only copy of the dropped turns. It must then hold nothing but
  # those transcripts.
  describe '#preserve_transcripts' do
    let(:config_dir) { Dir.mktmpdir('claude-resume-') }
    let(:outside) { Dir.mktmpdir }
    let(:sid) { '11111111-1111-4111-8111-111111111111' }

    # What the SDK seeds from the caller's .claude.json: it can carry MCP
    # header secrets.
    let(:claude_json) do
      JSON.generate('oauthAccount' => { 'emailAddress' => 'user@example.invalid' },
                    'mcpServers' => { 'internal' => { 'type' => 'http', 'url' => 'https://mcp.example.invalid',
                                                      'headers' => { 'Authorization' => 'Bearer MCP-HEADER-SECRET' } } })
    end

    # The four files the SDK seeds, then what a real CLI (2.1.286) left beside
    # them after a store-backed resume — at startup it saves the seeded
    # .claude.json as backups/.claude.json.backup.<epoch ms> before rewriting
    # it — and a file name nobody has heard of yet.
    let(:secrets) do
      {
        '.credentials.json' => '{"claudeAiOauth":{"accessToken":"ACCESS-TOKEN"}}',
        '.claude.json' => claude_json,
        'settings.json' => '{"env":{"INTERNAL_API_KEY":"SETTINGS-SECRET"}}',
        'cowork_settings.json' => '{"env":{"INTERNAL_API_KEY":"SETTINGS-SECRET"}}',
        'backups/.claude.json.backup.1790881328533' => claude_json,
        'cache/model-catalog/x-cc.json' => '{}',
        'written-by-a-later-cli.json' => claude_json
      }
    end
    let(:transcripts) do
      {
        "projects/-proj/#{sid}.jsonl" => %({"type":"user","uuid":"u1","sessionId":"#{sid}"}\n),
        "projects/-proj/#{sid}/subagents/agent-a1.jsonl" => %({"type":"user","uuid":"s1","isSidechain":true}\n),
        "projects/-proj/#{sid}/subagents/agent-a1.meta.json" => '{"agentType":"worker"}'
      }
    end

    before do
      secrets.merge(transcripts).each do |relative, content|
        path = File.join(config_dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      Dir.mkdir(File.join(config_dir, 'sessions')) # the CLI leaves this one empty
      File.write(File.join(outside, 'not-ours.txt'), 'keep me')
      File.symlink(outside, File.join(config_dir, 'linked-elsewhere'))
    end

    after do
      [config_dir, outside].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
    end

    def preserve
      described_class.new(config_dir: config_dir, resume_session_id: sid).preserve_transcripts
    end

    def files_under(dir)
      Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).select { |relative| File.file?(File.join(dir, relative)) }
    end

    it 'keeps projects/ and deletes every other entry, known or not' do
      expect { preserve }.to output(/transcript mirror dropped batches.*#{Regexp.escape(File.join(config_dir, 'projects'))}/).to_stderr

      expect(Dir.children(config_dir)).to eq(['projects'])
      expect(files_under(config_dir).to_h { |relative| [relative, File.read(File.join(config_dir, relative))] })
        .to eq(transcripts)
    end

    it 'removes a symlink without following it' do
      expect { preserve }.to output.to_stderr

      expect(File.symlink?(File.join(config_dir, 'linked-elsewhere'))).to be(false)
      expect(File.read(File.join(outside, 'not-ours.txt'))).to eq('keep me')
    end

    it 'still reports the incomplete store copy, without raising, when the directory is already gone' do
      FileUtils.remove_entry(config_dir)

      expect { preserve }.to output(/transcript mirror dropped batches/).to_stderr
    end
  end
end
