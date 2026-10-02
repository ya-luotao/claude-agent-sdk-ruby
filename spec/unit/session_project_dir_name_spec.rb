# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# The CLI names a project directory with JavaScript's
# cwd.replace(/[^a-zA-Z0-9]/g, "-") — no `u` flag, so the replacement runs per
# UTF-16 code unit and a character outside the BMP (an emoji, a CJK
# Extension B ideograph) becomes TWO hyphens. The expected names below are
# the ones CLI 2.1.286 created for these directories.
RSpec.describe 'project directory names for paths with non-BMP characters' do
  rocket = [0x1F680].pack('U')    # an emoji
  ideograph = [0x20BB7].pack('U') # CJK Extension B

  describe 'Sessions.sanitize_path' do
    {
      'an emoji' => ["/work/proj-#{rocket}-x", '-work-proj----x'],
      'a CJK Extension B ideograph' => ["/work/proj-#{ideograph}-x", '-work-proj----x'],
      'two of them in a row' => ["/work/#{rocket}#{ideograph}", '-work-----'],
      'BMP characters only' => ['/work/proj-日本語-x', '-work-proj-----x']
    }.each do |label, (path, name)|
      it "names the directory as the CLI does for #{label}" do
        expect(ClaudeAgentSDK::Sessions.sanitize_path(path)).to eq(name)
      end
    end

    it 'truncates a long name after the two hyphens and keeps the hash of the path' do
      path = "/work/proj-#{rocket}-#{'a' * 190}"

      name = ClaudeAgentSDK::Sessions.sanitize_path(path)

      expect(name).to eq("-work-proj----#{'a' * 186}-#{ClaudeAgentSDK::Sessions.simple_hash(path)}")
      expect(name.length).to eq(201 + ClaudeAgentSDK::Sessions.simple_hash(path).length)
    end
  end

  context 'with a transcript in the directory the CLI created' do
    include_context 'with a Claude config dir'

    let(:session_id) { '4a5b6c7d-8e9f-4012-a345-b6c7d8e9f012' }
    let(:directory) { File.join(cwd, "proj-#{rocket}-x").tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:cli_project_dir) do
      File.join(config_dir, 'projects', "#{ClaudeAgentSDK::Sessions.sanitize_path(cwd)}-proj----x")
    end

    before do
      allow(ClaudeAgentSDK::Sessions).to receive(:detect_worktrees) { |path| [path] }
      transcript = CLITranscript.new(session_id: session_id, cwd: directory)
      transcript.queue_operations('hi')
      transcript.prompt(:prompt, 'hi')
      transcript.assistant(:answer, transcript.text('Hello.'), parent: :prompt)
      transcript.last_prompt('hi', leaf: :answer)
      transcript.write(File.join(cli_project_dir, "#{session_id}.jsonl"))
    end

    it 'derives the same name as the store key' do
      expect(ClaudeAgentSDK.project_key_for_directory(directory)).to eq(File.basename(cli_project_dir))
    end

    it 'lists the session for the directory' do
      expect(ClaudeAgentSDK.list_sessions(directory: directory).map(&:session_id)).to eq([session_id])
    end

    it 'reads the session for the directory' do
      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: directory)&.summary).to eq('hi')
      expect(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: directory).length).to eq(2)
    end
  end
end
