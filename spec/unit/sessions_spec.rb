# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'timeout'

RSpec.describe ClaudeAgentSDK::Sessions do
  describe '.simple_hash' do
    it 'returns "0" for empty string' do
      expect(described_class.simple_hash('')).to eq('0')
    end

    it 'produces consistent output for known inputs' do
      # These must match TypeScript's simpleHash exactly
      result = described_class.simple_hash('/Users/test/project')
      expect(result).to be_a(String)
      expect(result).to match(/\A[0-9a-z]+\z/)
    end

    it 'handles unicode characters' do
      result = described_class.simple_hash('/Users/日本語/project')
      expect(result).to be_a(String)
      expect(result.length).to be > 0
    end

    it 'uses UTF-16 code units so supplementary chars match JS charCodeAt' do
      # '😀' (U+1F600) encodes as UTF-16 surrogate pair D83D DE00 (55357, 56832).
      # A codepoint-based implementation would hash the single value 128512 and
      # produce a different result.
      expect(described_class.simple_hash('😀')).to eq('11zz7')
    end
  end

  describe '.sanitize_path' do
    it 'replaces non-alphanumeric characters with hyphens' do
      expect(described_class.sanitize_path('/Users/test/project')).to eq('-Users-test-project')
    end

    it 'returns as-is when under 200 chars' do
      short_path = '/Users/test'
      result = described_class.sanitize_path(short_path)
      expect(result.length).to be <= 200
      expect(result).not_to include('/')
    end

    it 'appends hash suffix for paths over 200 chars' do
      long_path = "/Users/#{'a' * 300}/project"
      result = described_class.sanitize_path(long_path)
      expect(result.length).to be > 200
      expect(result).to match(/-[0-9a-z]+\z/)
    end
  end

  describe '.extract_json_string_field' do
    it 'extracts first occurrence by default' do
      text = '{"summary":"first"}\n{"summary":"second"}'
      expect(described_class.extract_json_string_field(text, 'summary')).to eq('first')
    end

    it 'extracts last occurrence when last: true' do
      text = '{"summary":"first"}\n{"summary":"second"}'
      expect(described_class.extract_json_string_field(text, 'summary', last: true)).to eq('second')
    end

    it 'handles escaped characters' do
      text = '{"title":"hello \\"world\\""}'
      expect(described_class.extract_json_string_field(text, 'title')).to eq('hello "world"')
    end

    it 'returns nil when field not found' do
      text = '{"other":"value"}'
      expect(described_class.extract_json_string_field(text, 'missing')).to be_nil
    end

    it 'handles spacing after colon' do
      text = '{"summary": "with space"}'
      expect(described_class.extract_json_string_field(text, 'summary')).to eq('with space')
    end
  end

  describe '.extract_first_prompt_from_head' do
    it 'extracts plain string content' do
      head = '{"type":"user","message":{"content":"Hello Claude"}}'
      expect(described_class.extract_first_prompt_from_head(head)).to eq('Hello Claude')
    end

    it 'extracts text from content blocks' do
      head = '{"type":"user","message":{"content":[{"type":"text","text":"Block text"}]}}'
      expect(described_class.extract_first_prompt_from_head(head)).to eq('Block text')
    end

    it 'skips tool_result lines' do
      lines = [
        '{"type":"user","message":{"content":"tool result"},"tool_result":true}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    it 'skips isMeta lines' do
      lines = [
        '{"type":"user","message":{"content":"meta"},"isMeta":true}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    it 'skips isCompactSummary lines' do
      lines = [
        '{"type":"user","message":{"content":"Summary of prior conversation"},"isCompactSummary":true}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    it 'skips session-start-hook content' do
      lines = [
        '{"type":"user","message":{"content":"<session-start-hook>stuff"}}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    it 'truncates long prompts to 200 chars with ellipsis' do
      long_text = 'x' * 300
      head = "{\"type\":\"user\",\"message\":{\"content\":\"#{long_text}\"}}"
      result = described_class.extract_first_prompt_from_head(head)
      expect(result.length).to eq(201) # 200 + ellipsis character
      expect(result).to end_with('…')
    end

    it 'returns empty string when no valid prompt found' do
      head = '{"type":"assistant","message":{"content":"Not a user message"}}'
      expect(described_class.extract_first_prompt_from_head(head)).to eq('')
    end

    it 'extracts command name as fallback' do
      head = '{"type":"user","message":{"content":"<command-name>commit</command-name>"}}'
      expect(described_class.extract_first_prompt_from_head(head)).to eq('commit')
    end

    # Regression (M13): the byte pre-filter matches `"type":"user"` nested in
    # a tool_use input on an assistant line; without a post-parse type
    # recheck, the assistant's text became the session's first prompt.
    it 'ignores assistant lines whose tool_use input embeds "type":"user"' do
      lines = [
        '{"type":"assistant","message":{"content":[{"type":"text","text":"Assistant reply"},' \
        '{"type":"tool_use","name":"SendMessage","input":{"payload":"{\"type\":\"user\"}"}}]}}',
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end

    # Regression (M12): Python's shape guards were dropped in the port — one
    # malformed head line (string message, non-string text, non-Hash entry)
    # raised NoMethodError/TypeError into read_session_lite's blanket rescue,
    # silently dropping the WHOLE session from disk listings. Each guard must
    # skip just the bad line.
    it 'skips malformed lines instead of dropping the whole session' do
      lines = [
        '["type":"user"]',                                                          # invalid JSON → ParserError skip
        '[{"type":"user"}]',                                                        # non-Hash entry
        '{"type":"user","message":"bare string with \"type\":\"user\" inside"}',    # non-Hash message
        '{"type":"user","message":{"content":[{"type":"text","text":42}]}}',        # non-String text
        '{"type":"user","message":{"content":"Real prompt"}}'
      ].join("\n")
      expect(described_class.extract_first_prompt_from_head(lines)).to eq('Real prompt')
    end
  end

  describe '.read_session_lite' do
    it 'reads a valid session file' do
      Dir.mktmpdir do |dir|
        session_id = '12345678-1234-1234-1234-123456789abc'
        file_path = File.join(dir, "#{session_id}.jsonl")
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'assistant', uuid: 'a1', message: { content: 'Hi!' } }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result).to be_a(ClaudeAgentSDK::SDKSessionInfo)
        expect(result.session_id).to eq(session_id)
        expect(result.first_prompt).to eq('Hello')
        expect(result.summary).to eq('Hello')
        expect(result.file_size).to be > 0
        expect(result.last_modified).to be > 0
      end
    end

    it 'returns nil for sidechain files' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, { type: 'user', isSidechain: true, message: { content: 'x' } }.to_json)

        expect(described_class.read_session_lite(file_path, '/test')).to be_nil
      end
    end

    # L9: sidechain classification must read the TOP-LEVEL key (like the
    # store fold) — a nested "isSidechain":true inside a structured field
    # hid the session from disk listings only.
    it 'does not classify a session as sidechain from a nested isSidechain field' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path,
                   { type: 'user', meta: { isSidechain: true }, message: { content: 'Hello' } }.to_json)

        result = described_class.read_session_lite(file_path, '/test')
        expect(result).not_to be_nil
        expect(result.summary).to eq('Hello')
      end
    end

    # Regression (H3): Python's `or` treats "" as falsy but Ruby's || does
    # not, so a trailing title-clearing entry ({"customTitle":""}) won the
    # custom_title chain, summary became "", and the presence gate dropped
    # the ENTIRE session from disk listings. The store path (via
    # SessionSummary.presence) and Python both fall through to the first
    # prompt — the two paths must agree.
    it 'falls through blank customTitle entries instead of dropping the session' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'custom-title', customTitle: '' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result).not_to be_nil
        expect(result.summary).to eq('Hello')
        expect(result.custom_title).to be_nil
      end
    end

    [
      [{ customTitle: 'Old custom', aiTitle: 'AI title' }, { customTitle: '' }, 'AI title'],
      [{ customTitle: 'Old custom', aiTitle: 'Old AI' }, { customTitle: '', aiTitle: '' }, nil],
      [{ aiTitle: 'Old AI' }, { aiTitle: '' }, nil],
      [{ customTitle: 'Old custom' }, { aiTitle: 'New AI' }, 'Old custom'],
      [{ customTitle: 'Old custom', aiTitle: 'Old AI' }, { customTitle: 'New custom' }, 'New custom']
    ].each do |head_titles, tail_titles, expected_title|
      it "resolves long-file titles #{head_titles.inspect} then #{tail_titles.inspect}" do
        Dir.mktmpdir do |dir|
          sid = '12345678-1234-1234-1234-123456789abc'
          file_path = File.join(dir, "#{sid}.jsonl")
          entries = [
            { type: 'user', uuid: 'u1', message: { content: 'Hello' } },
            { type: 'custom-title', **head_titles },
            { type: 'assistant', uuid: 'a1', message: { content: 'x' * 140_000 } },
            { type: 'custom-title', **tail_titles }
          ]
          File.write(file_path, entries.map(&:to_json).join("\n"))
          store = ClaudeAgentSDK::InMemorySessionStore.new
          key = { 'project_key' => described_class.project_key_for_directory(dir), 'session_id' => sid }
          store.append(key, entries.map { |entry| JSON.parse(entry.to_json) })

          disk = described_class.read_session_lite(file_path, dir)
          stored = described_class.get_session_info_from_store(session_store: store, session_id: sid, directory: dir)
          [disk, stored].each do |info|
            expect(info.custom_title).to eq(expected_title)
            expect(info.summary).to eq(expected_title || 'Hello')
          end
        end
      end
    end

    it 'treats whitespace-only titles as blank too' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'custom-title', customTitle: '   ' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result).not_to be_nil
        expect(result.summary).to eq('Hello')
      end
    end

    # Issue #67: SessionSummary.presence only rejected "", so a whitespace-only
    # value reaching the store path kept an invisible summary/title/branch
    # while the disk path (which strips) hid it. One shared presence helper
    # now drives both paths.
    it 'treats whitespace-only summary and metadata fields as blank on disk and store alike' do
      Dir.mktmpdir do |dir|
        sid = '12345678-1234-1234-1234-123456789abc'
        project_path = described_class.canonicalize_path(dir)
        file_path = File.join(dir, "#{sid}.jsonl")
        entries = [
          { 'type' => 'user', 'uuid' => 'u1', 'cwd' => '   ', 'gitBranch' => ' ',
            'message' => { 'content' => 'Hello' } },
          { 'type' => 'custom-title', 'customTitle' => '  ' },
          { 'type' => 'ai-title', 'aiTitle' => "\t" },
          { 'type' => 'last-prompt', 'lastPrompt' => '   ' },
          { 'type' => 'summary', 'summary' => ' ' },
          { 'type' => 'tag', 'tag' => '  ' }
        ]
        File.write(file_path, entries.map(&:to_json).join("\n"))
        store = ClaudeAgentSDK::InMemorySessionStore.new
        store.append({ 'project_key' => described_class.project_key_for_directory(dir), 'session_id' => sid }, entries)

        disk = described_class.read_session_lite(file_path, project_path)
        stored = described_class.get_session_info_from_store(session_store: store, session_id: sid, directory: dir)
        [disk, stored].each do |info|
          expect(info.summary).to eq('Hello')
          expect(info.custom_title).to be_nil
          expect(info.git_branch).to be_nil
          expect(info.cwd).to eq(project_path)
          expect(info.tag).to be_nil
        end
      end
    end

    # Issue #121: residual disk/store disagreements over the same transcript.
    describe 'disk and store agree on (issue #121)' do
      let(:sid) { '12345678-1234-1234-1234-123456789abc' }

      def read_both(dir, entries)
        file_path = File.join(dir, "#{sid}.jsonl")
        File.write(file_path, "#{entries.map(&:to_json).join("\n")}\n")
        store = ClaudeAgentSDK::InMemorySessionStore.new
        store.append({ 'project_key' => described_class.project_key_for_directory(dir), 'session_id' => sid },
                     JSON.parse(JSON.generate(entries)))
        [described_class.read_session_lite(file_path, described_class.canonicalize_path(dir)),
         described_class.get_session_info_from_store(session_store: store, session_id: sid, directory: dir)]
      end

      # (3) Python: `_extract_first_prompt_from_head(head) or None` (disk) and
      # the fold's unlocked first_prompt (store) are both None.
      it 'first_prompt is nil, not "", when the session has no prompt' do
        Dir.mktmpdir do |dir|
          infos = read_both(dir, [
                              { 'type' => 'custom-title', 'customTitle' => 'Titled' },
                              { 'type' => 'assistant', 'uuid' => 'a1', 'message' => { 'content' => 'hi' } }
                            ])
          infos.each do |info|
            expect(info.summary).to eq('Titled')
            expect(info.first_prompt).to be_nil
          end
        end
      end

      # (4) The store fold takes the first non-blank cwd; the disk scan took
      # the first cwd even when blank and then fell back to the project path.
      # Blank reads as absent (#67), so both keep looking past it.
      ['', '   '].each do |blank|
        it "cwd skips a leading #{blank.inspect} cwd for the first non-blank one" do
          Dir.mktmpdir do |dir|
            infos = read_both(dir, [
                                { 'type' => 'user', 'uuid' => 'u1', 'cwd' => blank, 'message' => { 'content' => 'Hi' } },
                                # A cwd nested in a tool input is not the session's cwd (the fold reads
                                # top-level keys only).
                                { 'type' => 'assistant', 'uuid' => 'a1',
                                  'message' => { 'content' => [{ 'type' => 'tool_use', 'input' => { 'cwd' => '/nested' } }] } },
                                { 'type' => 'user', 'uuid' => 'u2', 'cwd' => '/real/cwd', 'message' => { 'content' => 'Again' } }
                              ])
            expect(infos.map(&:cwd)).to eq(['/real/cwd', '/real/cwd'])
          end
        end
      end
    end

    # Issue #75: sidechain classification must come from the same entry on
    # both paths. The store never holds an unparseable line (import skips
    # them; the fold skips non-object entries), so the disk path now skips
    # leading blank/unparseable/non-object lines too and classifies from the
    # first parseable entry.
    sidechain_line = { type: 'user', uuid: 'u1', isSidechain: true, message: { content: 'Side' } }.to_json
    main_line = { type: 'user', uuid: 'u1', message: { content: 'Main' } }.to_json
    [
      ['a corrupt first line before a sidechain entry', ['{"type":"user","uu', sidechain_line], nil],
      ['a corrupt first line mentioning isSidechain before a main entry',
       ['{"isSidechain":true,"type":"us', main_line], 'Main'],
      ['a non-object first line before a sidechain entry', ['42', sidechain_line], nil],
      ['a blank first line before a sidechain entry', ['', sidechain_line], nil],
      ['an invalidly encoded first line before a main entry', ["\xFF\xFE garbage", main_line], 'Main']
    ].each do |label, lines, expected_summary|
      it "classifies sidechain-ness identically on disk and store for #{label}" do
        Dir.mktmpdir do |dir|
          sid = '12345678-1234-1234-1234-123456789abc'
          file_path = File.join(dir, "#{sid}.jsonl")
          File.write(file_path, "#{lines.join("\n")}\n")
          store = ClaudeAgentSDK::InMemorySessionStore.new
          # What import_session_to_store would mirror: unparseable lines dropped.
          parsed = lines.filter_map do |line|
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          store.append({ 'project_key' => described_class.project_key_for_directory(dir), 'session_id' => sid }, parsed)

          disk = described_class.read_session_lite(file_path, dir)
          stored = described_class.get_session_info_from_store(session_store: store, session_id: sid, directory: dir)
          expect(disk&.summary).to eq(expected_summary)
          expect(stored&.summary).to eq(expected_summary)
        end
      end
    end

    it 'keeps the substring heuristic for a first line truncated by the head window' do
      stub_const('ClaudeAgentSDK::Sessions::LITE_READ_BUF_SIZE', 64)
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        # The head window ends inside the first entry: it can't be parsed, but
        # it is not corrupt — skipping it would misclassify a real sidechain.
        File.write(file_path, [
          { isSidechain: true, type: 'user', uuid: 'u1', message: { content: "Side #{'x' * 200}" } }.to_json,
          main_line
        ].join("\n"))

        expect(described_class.read_session_lite(file_path, dir)).to be_nil
      end
    end

    # Regression (M14): the tail byte-scan also matched summary/customTitle/
    # lastPrompt keys nested inside tool_use inputs (subagent/teammate tool
    # arguments carry unescaped `"summary":"..."`), reporting tool-argument
    # text as the session summary/title — diverging from the store fold,
    # which reads only top-level keys. Matches are now verified against the
    # top level of their containing line.
    it 'ignores summary/customTitle keys nested inside tool_use inputs' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'summary', summary: 'true summary' }.to_json,
          { type: 'assistant', uuid: 'a1',
            message: { content: [{ type: 'tool_use', name: 'SendMessage',
                                   input: { summary: 'nested tool-arg summary',
                                            customTitle: 'nested title',
                                            lastPrompt: 'nested prompt' } }] } }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.summary).to eq('true summary')
        expect(result.custom_title).to be_nil
      end
    end

    it 'falls through to the first prompt when the only key matches are nested' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'assistant', uuid: 'a1',
            message: { content: [{ type: 'tool_use', name: 'SendMessage',
                                   input: { summary: 'nested tool-arg summary' } }] } }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.summary).to eq('Hello')
      end
    end

    %w[customTitle aiTitle].each do |field|
      it "does not let an unverified nested blank #{field} clear a head title" do
        Dir.mktmpdir do |dir|
          sid = '12345678-1234-1234-1234-123456789abc'
          file_path = File.join(dir, "#{sid}.jsonl")
          entries = [
            { 'type' => 'user', 'uuid' => 'u1', 'message' => { 'content' => 'Hello' } },
            { 'type' => 'custom-title', field => 'Real title' },
            { 'type' => 'assistant', 'uuid' => 'a1', 'message' => {
              'content' => [{ 'type' => 'tool_use', 'name' => 'SendMessage',
                              'input' => { 'padding' => 'x' * 140_000, field => '' } }]
            } }
          ]
          File.write(file_path, entries.map(&:to_json).join("\n"))
          store = ClaudeAgentSDK::InMemorySessionStore.new
          store.append({ 'project_key' => described_class.project_key_for_directory(dir), 'session_id' => sid }, entries)

          disk = described_class.read_session_lite(file_path, dir)
          stored = described_class.get_session_info_from_store(session_store: store, session_id: sid, directory: dir)
          [disk, stored].each do |info|
            expect(info.custom_title).to eq('Real title')
            expect(info.summary).to eq('Real title')
          end
        end
      end
    end

    it 'keeps the raw-scan value for a line truncated at the tail window edge' do
      stub_const('ClaudeAgentSDK::Sessions::LITE_READ_BUF_SIZE', 64)
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        # The summary entry is longer than the window, so the tail window
        # starts mid-line: the containing line can't be parsed, and the match
        # keeps its raw-scan value instead of being discarded.
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { pad: 'A' * 100, type: 'summary', summary: 'tail summary' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.summary).to eq('tail summary')
      end
    end

    it 'still prefers a real customTitle over the first prompt' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'custom-title', customTitle: 'My session' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.summary).to eq('My session')
        expect(result.custom_title).to eq('My session')
      end
    end

    it 'returns nil for empty files' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, '')

        expect(described_class.read_session_lite(file_path, '/test')).to be_nil
      end
    end

    it 'prefers customTitle as summary' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'system', uuid: 's1', customTitle: 'My Custom Title' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.summary).to eq('My Custom Title')
        expect(result.custom_title).to eq('My Custom Title')
      end
    end

    it 'extracts tag from {"type":"tag"} lines' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'tag', tag: 'experiment', sessionId: '12345678-1234-1234-1234-123456789abc' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.tag).to eq('experiment')
      end
    end

    it 'treats empty tag as cleared (nil)' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'tag', tag: 'first', sessionId: '12345678-1234-1234-1234-123456789abc' }.to_json,
          { type: 'tag', tag: '', sessionId: '12345678-1234-1234-1234-123456789abc' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.tag).to be_nil
      end
    end

    it 'returns nil tag when no tag lines exist' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json)

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.tag).to be_nil
      end
    end

    it 'extracts created_at from first entry ISO timestamp' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', timestamp: '2026-01-15T10:30:00Z',
            message: { content: 'Hello' } }.to_json,
          { type: 'assistant', uuid: 'a1', message: { content: 'Hi' } }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.created_at).to be_a(Integer)
        expect(result.created_at).to be > 0
        # 2026-01-15T10:30:00Z in epoch ms
        expected_ms = (Time.utc(2026, 1, 15, 10, 30, 0).to_f * 1000).to_i
        expect(result.created_at).to eq(expected_ms)
      end
    end

    it 'returns nil created_at when no head entry has a timestamp field' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json)

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.created_at).to be_nil
      end
    end

    it 'finds created_at when the first record is metadata-only (Python #907)' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'permission-mode', permissionMode: 'acceptEdits' }.to_json,
          { type: 'user', uuid: 'u1', timestamp: '2026-01-15T10:30:00.000Z',
            message: { content: 'Hello' } }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.created_at).to eq((Time.utc(2026, 1, 15, 10, 30, 0).to_f * 1000).to_i)
      end
    end

    it 'uses aiTitle as fallback for custom_title' do
      Dir.mktmpdir do |dir|
        file_path = File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl')
        File.write(file_path, [
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json,
          { type: 'system', uuid: 's1', aiTitle: 'AI Generated Title' }.to_json
        ].join("\n"))

        result = described_class.read_session_lite(file_path, '/test')
        expect(result.custom_title).to eq('AI Generated Title')
        expect(result.summary).to eq('AI Generated Title')
      end
    end
  end

  describe '.read_sessions_from_dir' do
    it 'reads all valid session files from a directory' do
      Dir.mktmpdir do |dir|
        # Valid session file
        File.write(
          File.join(dir, '12345678-1234-1234-1234-123456789abc.jsonl'),
          { type: 'user', uuid: 'u1', message: { content: 'Hello' } }.to_json
        )
        # Another valid session file
        File.write(
          File.join(dir, 'abcdef01-2345-6789-abcd-ef0123456789.jsonl'),
          { type: 'user', uuid: 'u2', message: { content: 'World' } }.to_json
        )
        # Invalid filename (not UUID)
        File.write(File.join(dir, 'not-a-uuid.jsonl'), 'ignored')
        # Non-JSONL file
        File.write(File.join(dir, 'readme.txt'), 'ignored')

        sessions = described_class.read_sessions_from_dir(dir)
        expect(sessions.length).to eq(2)
        expect(sessions.map(&:session_id)).to contain_exactly(
          '12345678-1234-1234-1234-123456789abc',
          'abcdef01-2345-6789-abcd-ef0123456789'
        )
      end
    end

    it 'returns empty array for non-existent directory' do
      expect(described_class.read_sessions_from_dir('/nonexistent')).to eq([])
    end
  end

  describe '.list_sessions' do
    it 'returns empty array when no config dir exists' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect(described_class.list_sessions).to eq([])
    end

    # Issue #121 (6): the same session in several project dirs is deduped to
    # the newest copy, but on EQUAL mtimes the first copy seen won — and the
    # global scan walked Dir.children in filesystem order, so which copy's
    # metadata surfaced was arbitrary. Rule: newest last_modified, then the
    # larger file (the more complete copy), then the project dir whose name
    # sorts first.
    describe 'duplicate session ids with equal mtimes (issue #121)' do
      let(:uuid) { '12345678-1234-1234-1234-123456789abc' }

      def write_copy(config_dir, project, prompt, mtime)
        project_dir = File.join(config_dir, 'projects', project)
        FileUtils.mkdir_p(project_dir)
        path = File.join(project_dir, "#{uuid}.jsonl")
        File.write(path, "#{{ type: 'user', uuid: 'u1', message: { content: prompt } }.to_json}\n")
        File.utime(mtime, mtime, path)
      end

      def list_with_children_order(config_dir, order)
        projects_dir = File.join(config_dir, 'projects')
        allow(Dir).to receive(:children).and_call_original
        allow(Dir).to receive(:children).with(projects_dir).and_return(order)
        described_class.list_sessions
      end

      it 'keeps the larger copy regardless of scan order' do
        Dir.mktmpdir do |config_dir|
          allow(described_class).to receive(:config_dir).and_return(config_dir)
          mtime = Time.at(1_700_000_000)
          write_copy(config_dir, '-a', 'short', mtime)
          write_copy(config_dir, '-b', 'a much longer prompt', mtime)

          [%w[-a -b], %w[-b -a]].each do |order|
            sessions = list_with_children_order(config_dir, order)
            expect(sessions.map(&:summary)).to eq(['a much longer prompt'])
          end
        end
      end

      it 'keeps the copy in the project dir that sorts first when sizes tie too' do
        Dir.mktmpdir do |config_dir|
          allow(described_class).to receive(:config_dir).and_return(config_dir)
          mtime = Time.at(1_700_000_000)
          write_copy(config_dir, '-b', 'prompt B', mtime)
          write_copy(config_dir, '-a', 'prompt A', mtime)

          [%w[-a -b], %w[-b -a]].each do |order|
            sessions = list_with_children_order(config_dir, order)
            expect(sessions.map(&:summary)).to eq(['prompt A'])
          end
        end
      end

      it 'still keeps the newest copy first of all' do
        Dir.mktmpdir do |config_dir|
          allow(described_class).to receive(:config_dir).and_return(config_dir)
          write_copy(config_dir, '-a', 'a much longer prompt', Time.at(1_700_000_000))
          write_copy(config_dir, '-b', 'newer', Time.at(1_700_000_100))

          expect(described_class.list_sessions.map(&:summary)).to eq(['newer'])
        end
      end
    end

    it 'respects limit parameter' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        3.times do |i|
          uuid = "12345678-1234-1234-1234-12345678900#{i}"
          File.write(
            File.join(project_dir, "#{uuid}.jsonl"),
            { type: 'user', uuid: "u#{i}", message: { content: "Prompt #{i}" } }.to_json
          )
          # Ensure different mtimes
          FileUtils.touch(File.join(project_dir, "#{uuid}.jsonl"), mtime: Time.now + i)
        end

        sessions = described_class.list_sessions(limit: 2)
        expect(sessions.length).to eq(2)
      end
    end

    it 'sorts by last_modified descending' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        uuid_old = '12345678-1234-1234-1234-123456789000'
        uuid_new = '12345678-1234-1234-1234-123456789001'

        File.write(
          File.join(project_dir, "#{uuid_old}.jsonl"),
          { type: 'user', uuid: 'u1', message: { content: 'Old' } }.to_json
        )
        FileUtils.touch(File.join(project_dir, "#{uuid_old}.jsonl"), mtime: Time.now - 100)

        File.write(
          File.join(project_dir, "#{uuid_new}.jsonl"),
          { type: 'user', uuid: 'u2', message: { content: 'New' } }.to_json
        )

        sessions = described_class.list_sessions
        expect(sessions.first.session_id).to eq(uuid_new)
      end
    end

    it 'treats offset: nil the same as offset: 0' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect { described_class.list_sessions(offset: nil) }.not_to raise_error
    end

    # Issue #78: equal mtimes (same-second writes, bulk copies) had no
    # secondary key, so their order depended on directory enumeration order
    # and offset/limit paging could skip or repeat sessions. Ties now break by
    # session_id ascending — the same order the store path produces.
    it 'breaks equal-mtime ties by session_id, identically to the store path' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)
        tie = Time.at(1_700_000_000)
        sids = %w[ffffffff-1234-4234-8234-123456789abc 00000000-1234-4234-8234-123456789abc
                  88888888-1234-4234-8234-123456789abc 44444444-1234-4234-8234-123456789abc]
        entries = {}
        # Spread across project dirs so the unsorted Dir.children walk (not a
        # sorted glob) decides the pre-sort order.
        sids.each_with_index do |sid, i|
          project_dir = File.join(config_dir, 'projects', "-proj-#{%w[z a m c][i]}")
          FileUtils.mkdir_p(project_dir)
          entries[sid] = [{ 'type' => 'user', 'uuid' => "u-#{sid}", 'message' => { 'content' => "p #{sid}" } }]
          path = File.join(project_dir, "#{sid}.jsonl")
          File.write(path, entries[sid].map(&:to_json).join("\n"))
          File.utime(tie, tie, path)
        end

        disk = described_class.list_sessions.map(&:session_id)
        expect(disk).to eq(sids.sort)
        expect(described_class.list_sessions(limit: 2).map(&:session_id) +
               described_class.list_sessions(limit: 2, offset: 2).map(&:session_id)).to eq(sids.sort)

        store = Class.new(ClaudeAgentSDK::SessionStore) do
          def initialize(entries, mtime)
            super()
            @entries = entries
            @mtime = mtime
          end

          def append(_key, _entries) = nil
          def load(key) = @entries[key['session_id']]
          def list_sessions(_project_key) = @entries.keys.reverse.map { |s| { 'session_id' => s, 'mtime' => @mtime } }
        end.new(entries, (tie.to_f * 1000).to_i)
        expect(described_class.list_sessions_from_store(session_store: store).map(&:session_id)).to eq(disk)
      end
    end
  end

  describe '.get_session_info' do
    it 'returns nil for invalid session_id' do
      expect(described_class.get_session_info(session_id: 'not-a-uuid')).to be_nil
    end

    it 'returns nil when session file not found' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect(described_class.get_session_info(session_id: '12345678-1234-1234-1234-123456789abc')).to be_nil
    end

    it 'finds a session by id in a specific directory' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        # Create a project dir matching the directory path
        dir_path = File.join(config_dir, 'testproject')
        FileUtils.mkdir_p(dir_path)
        sanitized = described_class.sanitize_path(File.realpath(dir_path).unicode_normalize(:nfc))
        project_dir = File.join(config_dir, 'projects', sanitized)
        FileUtils.mkdir_p(project_dir)

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          { type: 'user', uuid: 'u1', message: { content: 'Hello from info' } }.to_json
        )

        result = described_class.get_session_info(session_id: session_id, directory: dir_path)
        expect(result).to be_a(ClaudeAgentSDK::SDKSessionInfo)
        expect(result.session_id).to eq(session_id)
        expect(result.first_prompt).to eq('Hello from info')
      end
    end

    it 'finds a session by id across all project dirs' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-some-project')
        FileUtils.mkdir_p(project_dir)

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          { type: 'user', uuid: 'u1', message: { content: 'Found it' } }.to_json
        )

        result = described_class.get_session_info(session_id: session_id)
        expect(result).to be_a(ClaudeAgentSDK::SDKSessionInfo)
        expect(result.session_id).to eq(session_id)
        expect(result.first_prompt).to eq('Found it')
      end
    end

    it 'returns nil for sidechain sessions' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          { type: 'user', isSidechain: true, uuid: 'u1', message: { content: 'Side' } }.to_json
        )

        expect(described_class.get_session_info(session_id: session_id)).to be_nil
      end
    end
  end

  describe '.get_session_messages' do
    it 'returns empty for invalid session_id' do
      expect(described_class.get_session_messages(session_id: 'not-a-uuid')).to eq([])
    end

    it 'returns empty when session file not found' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect(described_class.get_session_messages(session_id: '12345678-1234-1234-1234-123456789abc')).to eq([])
    end

    it 'treats offset: nil the same as offset: 0' do
      allow(described_class).to receive(:config_dir).and_return('/nonexistent')
      expect do
        described_class.get_session_messages(
          session_id: '12345678-1234-1234-1234-123456789abc',
          offset: nil
        )
      end.not_to raise_error
    end

    it 'parses a simple conversation' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        entries = [
          {
            type: 'user', uuid: 'msg-1', sessionId: session_id,
            message: { role: 'user', content: 'Hello' }
          },
          {
            type: 'assistant', uuid: 'msg-2', parentUuid: 'msg-1', sessionId: session_id,
            message: { role: 'assistant', content: [{ type: 'text', text: 'Hi!' }] }
          }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.length).to eq(2)
        expect(messages[0]).to be_a(ClaudeAgentSDK::SessionMessage)
        expect(messages[0].type).to eq('user')
        expect(messages[0].uuid).to eq('msg-1')
        expect(messages[1].type).to eq('assistant')
      end
    end

    it 'filters out sidechain messages' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        # Main chain: msg-1 → msg-2 → msg-3 (continues main)
        # Sidechain: msg-4 branches off msg-2
        entries = [
          { type: 'user', uuid: 'msg-1', sessionId: session_id, message: { content: 'Hello' } },
          { type: 'assistant', uuid: 'msg-2', parentUuid: 'msg-1', sessionId: session_id,
            message: { content: 'Hi' } },
          { type: 'user', uuid: 'msg-3', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'Follow up' } },
          { type: 'user', uuid: 'msg-4', parentUuid: 'msg-2', isSidechain: true,
            sessionId: session_id, message: { content: 'Side branch' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.length).to eq(3)
        expect(messages.map(&:uuid)).to eq(%w[msg-1 msg-2 msg-3])
        expect(messages.none? { |m| m.uuid == 'msg-4' }).to be true
      end
    end

    it 'filters out meta messages' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        entries = [
          { type: 'user', uuid: 'msg-1', sessionId: session_id, isMeta: true,
            message: { content: 'Meta' } },
          { type: 'user', uuid: 'msg-2', sessionId: session_id,
            message: { content: 'Real' } },
          { type: 'assistant', uuid: 'msg-3', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'Response' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.none? { |m| m.uuid == 'msg-1' }).to be true
      end
    end

    it 'handles circular parentUuid references without infinite loop' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        # msg-1 and msg-2 form a cycle, msg-3 is a terminal that leads into the cycle
        entries = [
          { type: 'user', uuid: 'msg-1', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'First' } },
          { type: 'assistant', uuid: 'msg-2', parentUuid: 'msg-1', sessionId: session_id,
            message: { content: 'Second' } },
          { type: 'system', uuid: 'msg-3', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'System' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        # Should not hang — returns some result without infinite looping
        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.length).to be <= 3
      end
    end

    it 'applies offset and limit' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        entries = [
          { type: 'user', uuid: 'msg-1', sessionId: session_id, message: { content: 'First' } },
          { type: 'assistant', uuid: 'msg-2', parentUuid: 'msg-1', sessionId: session_id,
            message: { content: 'Second' } },
          { type: 'user', uuid: 'msg-3', parentUuid: 'msg-2', sessionId: session_id,
            message: { content: 'Third' } },
          { type: 'assistant', uuid: 'msg-4', parentUuid: 'msg-3', sessionId: session_id,
            message: { content: 'Fourth' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id, offset: 1, limit: 2)
        expect(messages.length).to eq(2)
        expect(messages[0].uuid).to eq('msg-2')
        expect(messages[1].uuid).to eq('msg-3')
      end
    end

    it 'keeps isCompactSummary messages visible' do
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)

        session_id = '12345678-1234-1234-1234-123456789abc'
        project_dir = File.join(config_dir, 'projects', '-test')
        FileUtils.mkdir_p(project_dir)

        entries = [
          { type: 'user', uuid: 'compact-summary', sessionId: session_id,
            isCompactSummary: true, message: { content: 'Summary of prior conversation' } },
          { type: 'assistant', uuid: 'reply-1', parentUuid: 'compact-summary', sessionId: session_id,
            message: { content: 'Continuing from summary' } }
        ]

        File.write(
          File.join(project_dir, "#{session_id}.jsonl"),
          entries.map(&:to_json).join("\n")
        )

        messages = described_class.get_session_messages(session_id: session_id)
        expect(messages.length).to eq(2)
        expect(messages[0].uuid).to eq('compact-summary')
        expect(messages[1].uuid).to eq('reply-1')
      end
    end
  end
end

RSpec.describe ClaudeAgentSDK::SDKSessionInfo do
  it 'stores all fields including tag and created_at' do
    info = described_class.new(
      session_id: 'abc-123',
      summary: 'Test session',
      last_modified: 1_000_000,
      file_size: 4096,
      custom_title: 'My Title',
      first_prompt: 'Hello',
      git_branch: 'main',
      cwd: '/test',
      tag: 'experiment',
      created_at: 900_000
    )

    expect(info.session_id).to eq('abc-123')
    expect(info.summary).to eq('Test session')
    expect(info.last_modified).to eq(1_000_000)
    expect(info.file_size).to eq(4096)
    expect(info.custom_title).to eq('My Title')
    expect(info.first_prompt).to eq('Hello')
    expect(info.git_branch).to eq('main')
    expect(info.cwd).to eq('/test')
    expect(info.tag).to eq('experiment')
    expect(info.created_at).to eq(900_000)
  end

  it 'defaults file_size, tag, and created_at to nil' do
    info = described_class.new(session_id: 'x', summary: 's', last_modified: 0)
    expect(info.file_size).to be_nil
    expect(info.tag).to be_nil
    expect(info.created_at).to be_nil
  end
end

RSpec.describe ClaudeAgentSDK::SessionMessage do
  it 'stores message data' do
    msg = described_class.new(
      type: 'user',
      uuid: 'msg-1',
      session_id: 'sess-1',
      message: { 'role' => 'user', 'content' => 'Hello' }
    )

    expect(msg.type).to eq('user')
    expect(msg.uuid).to eq('msg-1')
    expect(msg.session_id).to eq('sess-1')
    expect(msg.message).to eq({ 'role' => 'user', 'content' => 'Hello' })
    expect(msg.parent_tool_use_id).to be_nil
    expect(msg.parent_agent_id).to be_nil
  end

  it 'carries the subagent parent ids when given' do
    msg = described_class.new(
      type: 'assistant', uuid: 'abc', session_id: 'sess', message: nil,
      parent_tool_use_id: 'toolu_1', parent_agent_id: 'agent-1'
    )

    expect(msg.parent_tool_use_id).to eq('toolu_1')
    expect(msg.parent_agent_id).to eq('agent-1')
  end

  def build(message)
    described_class.new(type: 'assistant', uuid: 'u', session_id: 's', message: message)
  end

  describe '#text' do
    it 'returns "" when message is nil' do
      expect(build(nil).text).to eq('')
    end

    it 'returns "" when message is not a Hash' do
      expect(build('raw string').text).to eq('')
    end

    it 'returns the raw string when content is a String' do
      expect(build({ 'role' => 'user', 'content' => 'Hello' }).text).to eq('Hello')
    end

    it 'concatenates text blocks in an Array content, skipping non-text blocks' do
      msg = build(
        'role' => 'assistant',
        'content' => [
          { 'type' => 'text', 'text' => 'First' },
          { 'type' => 'tool_use', 'id' => 't1', 'name' => 'Read', 'input' => {} },
          { 'type' => 'text', 'text' => 'Second' }
        ]
      )
      expect(msg.text).to eq("First\n\nSecond")
    end

    it 'returns "" when content is an empty Array' do
      expect(build('content' => []).text).to eq('')
    end

    it 'accepts symbol-keyed blocks as a fallback' do
      msg = build(
        content: [
          { type: 'text', text: 'Sym' }
        ]
      )
      expect(msg.text).to eq('Sym')
    end

    it 'aliases #to_s to #text' do
      msg = build('content' => 'Hello')
      expect(msg.to_s).to eq('Hello')
      expect("got: #{msg}").to eq('got: Hello')
    end
  end

  describe '#content_blocks' do
    it 'returns [] when message is nil' do
      expect(build(nil).content_blocks).to eq([])
    end

    it 'returns [] when message is not a Hash' do
      expect(build(42).content_blocks).to eq([])
    end

    it 'returns [] when content is a String (no blocks existed in the transcript)' do
      expect(build('content' => 'Hello').content_blocks).to eq([])
    end

    it 'parses typed blocks from an Array content' do
      msg = build(
        'content' => [
          { 'type' => 'text', 'text' => 'Hi' },
          { 'type' => 'tool_use', 'id' => 't1', 'name' => 'Read', 'input' => { 'path' => '/tmp/x' } },
          { 'type' => 'thinking', 'thinking' => 'hmm', 'signature' => 'sig' },
          { 'type' => 'tool_result', 'tool_use_id' => 't1', 'content' => 'ok', 'is_error' => false }
        ]
      )
      blocks = msg.content_blocks
      expect(blocks.map(&:class)).to eq(
        [
          ClaudeAgentSDK::TextBlock,
          ClaudeAgentSDK::ToolUseBlock,
          ClaudeAgentSDK::ThinkingBlock,
          ClaudeAgentSDK::ToolResultBlock
        ]
      )
      expect(blocks[0].text).to eq('Hi')
      expect(blocks[1].id).to eq('t1')
      expect(blocks[1].name).to eq('Read')
      expect(blocks[1].input).to eq({ 'path' => '/tmp/x' })
      expect(blocks[3].tool_use_id).to eq('t1')
    end

    it 'yields UnknownBlock for unrecognized block types' do
      msg = build(
        'content' => [
          { 'type' => 'image', 'source' => { 'type' => 'base64', 'data' => '...' } }
        ]
      )
      block = msg.content_blocks.first
      expect(block).to be_a(ClaudeAgentSDK::UnknownBlock)
      expect(block.type).to eq('image')
    end

    it 'skips non-Hash entries in a mixed Array' do
      msg = build('content' => [{ 'type' => 'text', 'text' => 'ok' }, 'bare string', nil])
      expect(msg.content_blocks.size).to eq(1)
      expect(msg.content_blocks[0]).to be_a(ClaudeAgentSDK::TextBlock)
    end
  end
end

RSpec.describe 'ClaudeAgentSDK top-level session functions' do
  it 'delegates list_sessions to Sessions module' do
    expect(ClaudeAgentSDK::Sessions).to receive(:list_sessions)
      .with(directory: '/test', limit: 5, offset: 0, include_worktrees: false)
      .and_return([])

    ClaudeAgentSDK.list_sessions(directory: '/test', limit: 5, include_worktrees: false)
  end

  it 'delegates get_session_info to Sessions module' do
    expect(ClaudeAgentSDK::Sessions).to receive(:get_session_info)
      .with(session_id: 'abc', directory: '/test')
      .and_return(nil)

    ClaudeAgentSDK.get_session_info(session_id: 'abc', directory: '/test')
  end

  it 'delegates get_session_messages to Sessions module' do
    expect(ClaudeAgentSDK::Sessions).to receive(:get_session_messages)
      .with(session_id: 'abc', directory: nil, limit: nil, offset: 0)
      .and_return([])

    ClaudeAgentSDK.get_session_messages(session_id: 'abc')
  end

  describe 'local-disk subagent readers' do
    let(:described_class) { ClaudeAgentSDK::Sessions }
    let(:uuid) { '12345678-1234-1234-1234-123456789abc' }

    # Real CLI subagent transcript entries ALL carry isSidechain: true — the
    # fixtures must mirror real CLI shape or the readers' sidechain-aware
    # pipeline is not actually exercised (the v0.17.0 lesson).
    def sidechain_entry(entry_uuid, parent: nil, text: 'work')
      { type: 'assistant', uuid: entry_uuid, parentUuid: parent, isSidechain: true,
        sessionId: uuid, message: { role: 'assistant', content: [{ type: 'text', text: text }] } }
    end

    def with_session_on_disk
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)
        Dir.mktmpdir do |repo|
          canonical = File.realpath(repo).unicode_normalize(:nfc)
          allow(described_class).to receive(:detect_worktrees).and_return([canonical])
          project_dir = File.join(config_dir, 'projects', described_class.sanitize_path(canonical))
          FileUtils.mkdir_p(project_dir)
          # Parent session transcript must be NON-EMPTY (size > 0 resolution rule).
          File.write(File.join(project_dir, "#{uuid}.jsonl"),
                     { type: 'user', uuid: 'u1', sessionId: uuid,
                       message: { role: 'user', content: 'Hello' } }.to_json)
          subagents_dir = File.join(project_dir, uuid, 'subagents')
          FileUtils.mkdir_p(subagents_dir)
          yield subagents_dir, canonical
        end
      end
    end

    it 'lists agent ids from top-level and nested workflow paths in sorted walk order' do
      with_session_on_disk do |subagents_dir, canonical|
        File.write(File.join(subagents_dir, 'agent-beta.jsonl'), sidechain_entry('b1').to_json)
        nested = File.join(subagents_dir, 'workflows', 'run-1')
        FileUtils.mkdir_p(nested)
        File.write(File.join(nested, 'agent-alpha.jsonl'), sidechain_entry('a1').to_json)

        # sorted interleave: 'agent-beta.jsonl' < 'workflows' at the top level
        expect(ClaudeAgentSDK.list_subagents(session_id: uuid, directory: canonical))
          .to eq(%w[beta alpha])
      end
    end

    it 'reads sidechain subagent messages (real CLI transcript shape)' do
      with_session_on_disk do |subagents_dir, canonical|
        File.write(File.join(subagents_dir, 'agent-worker.jsonl'), [
          sidechain_entry('s1', text: 'step one').to_json,
          sidechain_entry('s2', parent: 's1', text: 'step two').to_json
        ].join("\n"))

        messages = ClaudeAgentSDK.get_subagent_messages(
          session_id: uuid, agent_id: 'worker', directory: canonical
        )
        expect(messages.length).to eq(2)
        expect(messages.first).to be_a(ClaudeAgentSDK::SessionMessage)
        expect(messages.map(&:uuid)).to eq(%w[s1 s2])
      end
    end

    it 'applies limit/offset with the Ruby family convention (limit: 0 yields [])' do
      with_session_on_disk do |subagents_dir, canonical|
        File.write(File.join(subagents_dir, 'agent-worker.jsonl'), [
          sidechain_entry('s1').to_json,
          sidechain_entry('s2', parent: 's1').to_json,
          sidechain_entry('s3', parent: 's2').to_json
        ].join("\n"))

        args = { session_id: uuid, agent_id: 'worker', directory: canonical }
        expect(ClaudeAgentSDK.get_subagent_messages(**args, limit: 1, offset: 1).map(&:uuid)).to eq(%w[s2])
        # Deliberate divergence from Python (limit=0 means "no limit" there):
        # the Ruby read-API family standardized limit <= 0 -> [].
        expect(ClaudeAgentSDK.get_subagent_messages(**args, limit: 0)).to eq([])
      end
    end

    # --- parent ids recovered from the .meta.json sidecar (Python PR #1207) ---

    def write_agent(subagents_dir, agent_id, meta)
      File.write(File.join(subagents_dir, "agent-#{agent_id}.jsonl"), [
        sidechain_entry('s1', text: 'hi').to_json,
        sidechain_entry('s2', parent: 's1', text: 'hello').to_json
      ].join("\n"))
      return if meta.nil?

      File.write(File.join(subagents_dir, "agent-#{agent_id}.meta.json"),
                 meta.is_a?(String) ? meta : JSON.generate(meta))
    end

    it 'reads metadata without parsing the transcript, preserving unknown fields and nesting' do
      with_session_on_disk do |subagents_dir, canonical|
        nested = File.join(subagents_dir, 'workflows', 'run-1')
        FileUtils.mkdir_p(nested)
        meta = { 'agentType' => 'reviewer', 'toolUseId' => 'spawn-7', 'parentAgentId' => 'parent-2',
                 'spawnDepth' => 2, 'futureField' => { 'enabled' => false } }
        write_agent(nested, 'worker', meta)
        File.write(File.join(nested, 'agent-worker.jsonl'), '')
        expect(described_class).not_to receive(:parse_jsonl_entries)

        expect(ClaudeAgentSDK.get_subagent_metadata(session_id: uuid, agent_id: 'worker', directory: canonical))
          .to eq(meta)
        Dir.mktmpdir do |tmp|
          # Canonicalize like with_session_on_disk: on macOS the tmpdir is a
          # symlink, and the reader passes detect_worktrees the realpath.
          other = File.realpath(tmp).unicode_normalize(:nfc)
          allow(described_class).to receive(:detect_worktrees).with(other).and_return([other])
          expect(ClaudeAgentSDK.get_subagent_metadata(session_id: uuid, agent_id: 'worker', directory: other))
            .to be_nil
        end
      end
    end

    it 'selects the same first matching transcript as the message reader' do
      with_session_on_disk do |subagents_dir, canonical|
        nested = File.join(subagents_dir, 'workflows', 'run-1')
        FileUtils.mkdir_p(nested)
        write_agent(nested, 'worker', 'toolUseId' => 'nested')
        write_agent(subagents_dir, 'worker', 'toolUseId' => 'top-level')

        expect(ClaudeAgentSDK.get_subagent_metadata(session_id: uuid, agent_id: 'worker', directory: canonical))
          .to eq('toolUseId' => 'top-level')
      end
    end

    it 'returns nil for unavailable metadata, but preserves an empty metadata object' do
      with_session_on_disk do |subagents_dir, canonical|
        [nil, 'not json', '[]', "{\"bad\":\"\xFF\"}"].each do |meta|
          FileUtils.rm_f(File.join(subagents_dir, 'agent-worker.meta.json'))
          write_agent(subagents_dir, 'worker', meta)
          expect(ClaudeAgentSDK.get_subagent_metadata(session_id: uuid, agent_id: 'worker', directory: canonical))
            .to be_nil
        end
        write_agent(subagents_dir, 'worker', {})
        expect(ClaudeAgentSDK.get_subagent_metadata(session_id: uuid, agent_id: 'worker', directory: canonical))
          .to eq({})
        expect(ClaudeAgentSDK.get_subagent_metadata(session_id: uuid, agent_id: 'missing', directory: canonical)).to be_nil
        expect(ClaudeAgentSDK.get_subagent_metadata(session_id: 'invalid', agent_id: 'worker')).to be_nil
        expect(ClaudeAgentSDK.get_subagent_metadata(session_id: uuid, agent_id: '')).to be_nil
      end
    end

    it 'stamps toolUseId/parentAgentId from the sidecar on every message' do
      with_session_on_disk do |subagents_dir, canonical|
        write_agent(subagents_dir, 'abc', 'agentType' => 'general-purpose', 'toolUseId' => 'toolu_01ABC',
                                          'parentAgentId' => 'a-parent', 'spawnDepth' => 2)

        messages = ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: 'abc', directory: canonical)
        expect(messages.length).to eq(2)
        expect(messages.map(&:parent_tool_use_id)).to eq(%w[toolu_01ABC toolu_01ABC])
        expect(messages.map(&:parent_agent_id)).to eq(%w[a-parent a-parent])
      end
    end

    it 'reads the sidecar beside a nested workflow transcript' do
      with_session_on_disk do |subagents_dir, canonical|
        nested = File.join(subagents_dir, 'workflows', 'run-1')
        FileUtils.mkdir_p(nested)
        write_agent(nested, 'deep', 'toolUseId' => 'toolu_nested')

        messages = ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: 'deep', directory: canonical)
        expect(messages.map(&:parent_tool_use_id)).to eq(%w[toolu_nested toolu_nested])
        expect(messages.map(&:parent_agent_id)).to eq([nil, nil])
      end
    end

    [
      [nil, 'no sidecar'],
      ['not json {', 'an unparseable sidecar'],
      ['[1, 2]', 'a non-object sidecar'],
      [{ 'agentType' => 'general-purpose' }, 'a sidecar without ids'],
      [{ 'toolUseId' => 42, 'parentAgentId' => ['x'] }, 'non-String ids']
    ].each do |meta, label|
      it "leaves both parent ids nil for #{label}" do
        with_session_on_disk do |subagents_dir, canonical|
          write_agent(subagents_dir, 'x', meta)

          messages = ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: 'x', directory: canonical)
          expect(messages.length).to eq(2)
          expect(messages.map(&:parent_tool_use_id)).to eq([nil, nil])
          expect(messages.map(&:parent_agent_id)).to eq([nil, nil])
        end
      end
    end

    it 'treats a sidecar holding illegal UTF-8 bytes as absent' do
      # JSON.parse accepts illegal bytes inside a UTF-8-tagged document and
      # hands back a Hash whose values only blow up later, at JSON.generate
      # time. Accepting it here poisons everything downstream (see the import
      # + resume regression in session_import_spec).
      with_session_on_disk do |subagents_dir, canonical|
        write_agent(subagents_dir, 'x', nil)
        File.binwrite(File.join(subagents_dir, 'agent-x.meta.json'),
                      %({"toolUseId":"toolu_1","note":"bad \xFF\xFE bytes"}))

        messages = ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: 'x', directory: canonical)
        expect(messages.length).to eq(2)
        expect(messages.map(&:parent_tool_use_id)).to eq([nil, nil])
      end
    end

    it 'skips a FIFO sidecar instead of blocking forever on it' do
      # Opening a FIFO with no writer waits forever, and the caller's
      # best-effort rescue never fires because nothing is ever raised.
      skip 'requires File.mkfifo' unless File.respond_to?(:mkfifo)

      with_session_on_disk do |subagents_dir, canonical|
        write_agent(subagents_dir, 'x', nil)
        File.mkfifo(File.join(subagents_dir, 'agent-x.meta.json'))

        messages = Timeout.timeout(5) do
          ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: 'x', directory: canonical)
        end
        expect(messages.length).to eq(2)
        expect(messages.map(&:parent_tool_use_id)).to eq([nil, nil])
      end
    end

    it 'degrades to no metadata when the sidecar exists but cannot be read' do
      # A directory where the sidecar is expected raises EISDIR out of the read
      # helper; this best-effort caller must swallow it, not propagate.
      with_session_on_disk do |subagents_dir, canonical|
        write_agent(subagents_dir, 'x', nil)
        Dir.mkdir(File.join(subagents_dir, 'agent-x.meta.json'))

        messages = ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: 'x', directory: canonical)
        expect(messages.length).to eq(2)
        expect(messages.map(&:parent_tool_use_id)).to eq([nil, nil])
        expect(messages.map(&:parent_agent_id)).to eq([nil, nil])
      end
    end

    it 'never sets parent ids on top-level session messages' do
      with_session_on_disk do |_subagents_dir, canonical|
        messages = ClaudeAgentSDK.get_session_messages(session_id: uuid, directory: canonical)
        expect(messages).not_to be_empty
        expect(messages.map(&:parent_tool_use_id)).to all(be_nil)
        expect(messages.map(&:parent_agent_id)).to all(be_nil)
      end
    end

    it 'returns [] for unknown sessions, blank agent ids, and missing agents' do
      with_session_on_disk do |_subagents_dir, canonical|
        other_uuid = '99999999-9999-4999-8999-999999999999'
        expect(ClaudeAgentSDK.list_subagents(session_id: other_uuid, directory: canonical)).to eq([])
        expect(ClaudeAgentSDK.list_subagents(session_id: 'not-a-uuid')).to eq([])
        expect(ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: '', directory: canonical)).to eq([])
        expect(ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: 'ghost', directory: canonical))
          .to eq([])
      end
    end

    # Issue #74: a non-String id raised a deep NoMethodError (`123.match?`,
    # `123.empty?`) instead of getting the malformed-id answer. An invalidly
    # encoded String raised ArgumentError from the regexp match itself.
    [nil, 123, :sym, ['x'], "\xFFbad"].each do |bad|
      it "treats session_id #{bad.inspect} like a malformed id on every disk reader" do
        with_session_on_disk do |_subagents_dir, canonical|
          args = { session_id: bad, directory: canonical }
          expect(ClaudeAgentSDK.get_session_info(**args)).to be_nil
          expect(ClaudeAgentSDK.get_session_messages(**args)).to eq([])
          expect(ClaudeAgentSDK.list_subagents(**args)).to eq([])
          expect(ClaudeAgentSDK.get_subagent_metadata(**args, agent_id: 'abc')).to be_nil
          expect(ClaudeAgentSDK.get_subagent_messages(**args, agent_id: 'abc')).to eq([])
        end
      end

      it "treats agent_id #{bad.inspect} like a malformed id on the disk subagent readers" do
        with_session_on_disk do |_subagents_dir, canonical|
          args = { session_id: uuid, agent_id: bad, directory: canonical }
          expect(ClaudeAgentSDK.get_subagent_metadata(**args)).to be_nil
          expect(ClaudeAgentSDK.get_subagent_messages(**args)).to eq([])
        end
      end
    end

    # Issue #79: the store readers reject agent ids outside the id grammar
    # before synthesizing a subpath; the disk readers apply the same grammar
    # so the two paths accept exactly the same ids.
    it 'rejects a malformed agent_id on disk exactly like the store readers do' do
      with_session_on_disk do |subagents_dir, canonical|
        File.write(File.join(subagents_dir, 'agent-x%2Fy.jsonl'), sidechain_entry('s1').to_json)
        File.write(File.join(subagents_dir, 'agent-x%2Fy.meta.json'), '{}')
        expect(ClaudeAgentSDK.get_subagent_messages(session_id: uuid, agent_id: 'x%2Fy', directory: canonical))
          .to eq([])
        expect(ClaudeAgentSDK.get_subagent_metadata(session_id: uuid, agent_id: 'x%2Fy', directory: canonical))
          .to be_nil
      end
    end
  end

  describe 'sessions read-path hygiene (M12/M11/L8/L9)' do
    let(:described_class) { ClaudeAgentSDK::Sessions }
    let(:uuid) { '12345678-1234-1234-1234-123456789abc' }

    def with_config_dir
      Dir.mktmpdir do |config_dir|
        allow(described_class).to receive(:config_dir).and_return(config_dir)
        FileUtils.mkdir_p(File.join(config_dir, 'projects'))
        yield config_dir
      end
    end

    def project_dir_for(config_dir, path)
      dir = File.join(config_dir, 'projects', described_class.sanitize_path(path))
      FileUtils.mkdir_p(dir)
      dir
    end

    describe 'with a nonexistent directory argument' do
      it 'list_sessions returns [] instead of raising' do
        with_config_dir do
          expect(described_class.list_sessions(directory: '/definitely/not/a/dir')).to eq([])
        end
      end

      it 'get_session_info returns nil instead of raising' do
        with_config_dir do
          expect(described_class.get_session_info(session_id: uuid, directory: '/definitely/not/a/dir')).to be_nil
        end
      end

      it 'get_session_messages returns [] instead of raising' do
        with_config_dir do
          expect(described_class.get_session_messages(session_id: uuid, directory: '/definitely/not/a/dir')).to eq([])
        end
      end
    end

    describe '0-byte transcript stubs' do
      it 'skips a stub in the canonical project dir and finds the worktree transcript' do
        with_config_dir do |config_dir|
          Dir.mktmpdir do |repo|
            canonical = File.realpath(repo).unicode_normalize(:nfc)
            worktree = File.join(canonical, 'wt')
            FileUtils.mkdir_p(worktree)
            allow(described_class).to receive(:detect_worktrees).and_return([canonical, worktree])

            stub_dir = project_dir_for(config_dir, canonical)
            File.write(File.join(stub_dir, "#{uuid}.jsonl"), '')

            wt_dir = project_dir_for(config_dir, worktree)
            File.write(File.join(wt_dir, "#{uuid}.jsonl"),
                       { type: 'user', uuid: 'u1', sessionId: uuid,
                         message: { role: 'user', content: 'Hello' } }.to_json)

            messages = described_class.get_session_messages(session_id: uuid, directory: canonical)
            expect(messages.length).to eq(1)
          end
        end
      end
    end

    describe 'explicit directory scoping' do
      it 'does not fall back to scanning unrelated project dirs' do
        with_config_dir do |config_dir|
          Dir.mktmpdir do |repo|
            canonical = File.realpath(repo).unicode_normalize(:nfc)
            allow(described_class).to receive(:detect_worktrees).and_return([canonical])

            other_dir = File.join(config_dir, 'projects', 'unrelated-project')
            FileUtils.mkdir_p(other_dir)
            File.write(File.join(other_dir, "#{uuid}.jsonl"),
                       { type: 'user', uuid: 'u1', sessionId: uuid,
                         message: { role: 'user', content: 'Hello' } }.to_json)

            expect(described_class.get_session_messages(session_id: uuid, directory: canonical)).to eq([])
            # nil directory still searches all projects
            expect(described_class.get_session_messages(session_id: uuid).length).to eq(1)
          end
        end
      end
    end

    describe 'CLAUDE_CONFIG_DIR handling' do
      around do |example|
        previous = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
        example.run
      ensure
        if previous
          ENV['CLAUDE_CONFIG_DIR'] = previous
        else
          ENV.delete('CLAUDE_CONFIG_DIR')
        end
      end

      it 'treats an empty CLAUDE_CONFIG_DIR as unset' do
        ENV['CLAUDE_CONFIG_DIR'] = ''
        expect(described_class.config_dir).to eq(File.expand_path('~/.claude'))
      end

      it 'NFC-normalizes a set CLAUDE_CONFIG_DIR' do
        ENV['CLAUDE_CONFIG_DIR'] = "/tmp/café" # decomposed é
        expect(described_class.config_dir).to eq("/tmp/café")
      end

      # Issue #120: with CLAUDE_CONFIG_DIR unset and no usable home, the
      # default ~/.claude cannot be resolved. `~` expansion raised a bare
      # ArgumentError ("couldn't find login name" / "non-absolute home") from
      # deep inside every local-disk session API.
      context 'without a resolvable home directory (#120)' do
        around do |example|
          previous_home = ENV.fetch('HOME', nil) # rubocop:disable Style/EnvHome -- raw value; nil when unset
          example.run
        ensure
          previous_home.nil? ? ENV.delete('HOME') : (ENV['HOME'] = previous_home)
        end

        before { ENV.delete('CLAUDE_CONFIG_DIR') }

        # HOME unset with no passwd entry for the uid (docker --user in a
        # minimal image). Stubbed because the host's passwd fallback would
        # otherwise resolve a home.
        def remove_home
          ENV.delete('HOME')
          allow(Dir).to receive(:home).and_raise(ArgumentError, "couldn't find home for uid `4242'")
        end

        it 'raises ConfigDirError naming CLAUDE_CONFIG_DIR' do
          remove_home
          expect { described_class.config_dir }
            .to raise_error(ClaudeAgentSDK::ConfigDirError, /home directory.*CLAUDE_CONFIG_DIR/m)
        end

        it 'raises ConfigDirError for an empty or relative HOME' do
          ['', 'relative/home'].each do |home|
            ENV['HOME'] = home
            expect { described_class.config_dir }.to raise_error(ClaudeAgentSDK::ConfigDirError)
          end
        end

        it 'raises ConfigDirError (a ClaudeSDKError) from the public disk readers' do
          remove_home
          expect { described_class.list_sessions }.to raise_error(ClaudeAgentSDK::ConfigDirError)
          expect { described_class.get_session_info(session_id: '12345678-1234-1234-1234-123456789abc') }
            .to raise_error(ClaudeAgentSDK::ClaudeSDKError)
          expect { ClaudeAgentSDK::SessionMutations.rename_session(session_id: '12345678-1234-1234-1234-123456789abc', title: 't') }
            .to raise_error(ClaudeAgentSDK::ConfigDirError)
        end

        it 'needs no home when CLAUDE_CONFIG_DIR is set' do
          remove_home
          ENV['CLAUDE_CONFIG_DIR'] = '/srv/claude-nonexistent'
          expect(described_class.config_dir).to eq('/srv/claude-nonexistent')
          expect(described_class.list_sessions).to eq([])
        end
      end
    end
  end
end
