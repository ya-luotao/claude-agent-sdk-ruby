# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# Transcripts are UTF-8 whatever the process locale says, and a CLI killed in
# the middle of a write leaves a final line that stops inside a character.
RSpec.describe 'reading transcripts that are not clean UTF-8 text' do
  include_context 'with a Claude config dir'

  let(:session_id) { '3f8a1c2d-5e6b-4a79-9c80-d1e2f3a4b5c6' }
  let(:agent_id) { 'b7c8d9e0f1a2b3c4' }
  let(:question) { '你好，请读一下 a.rb — 然后总结' }
  let(:answer) { '好的。a.rb 定义了 Foo。' }
  let(:replacement) { [0xFFFD].pack('U') }

  def conversation(transcript)
    transcript.prompt(:prompt, question)
    transcript.assistant(:use_a, transcript.tool_use('toolu_a'), parent: :prompt)
    transcript.tool_result(:result_a, 'toolu_a', 'class Foo; end', parent: :use_a)
    transcript.assistant(:answer, transcript.text(answer), parent: :result_a, message: 'msg_02')
    transcript
  end

  def main_transcript
    transcript = CLITranscript.new(session_id: session_id, cwd: cwd)
    transcript.queue_operations(question)
    conversation(transcript)
    transcript.last_prompt(question, leaf: :answer)
    transcript
  end

  # What LANG=C / LC_ALL=C does to a Ruby process: files and pipes opened
  # without an explicit encoding yield US-ASCII-tagged Strings.
  def with_default_external(encoding)
    saved = Encoding.default_external
    switch_default_external(encoding)
    yield
  ensure
    switch_default_external(saved)
  end

  def switch_default_external(encoding)
    verbose = $VERBOSE
    $VERBOSE = nil # the assignment warns under -w
    Encoding.default_external = encoding
  ensure
    $VERBOSE = verbose
  end

  # +line+ cut one byte into the 3-byte character +char+: no closing quote,
  # no newline, and a lead byte with nothing after it.
  def cut_inside(line, char)
    bytes = line.b
    bytes[0, bytes.index(char.b) + 1]
  end

  describe 'under a non-UTF-8 locale' do
    it 'get_session_messages reads a transcript with non-ASCII text' do
      main_transcript.write(transcript_path(session_id))

      messages = with_default_external(Encoding::US_ASCII) do
        ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)
      end

      expect(messages.map(&:text)).to eq([question, '', '', answer])
      expect(messages.last.text.encoding).to eq(Encoding::UTF_8)
    end

    it 'get_subagent_messages reads a subagent transcript with non-ASCII text' do
      main_transcript.write(transcript_path(session_id))
      conversation(CLITranscript.new(session_id: session_id, cwd: cwd, agent_id: agent_id))
        .write(subagent_transcript_path(session_id, agent_id))

      messages = with_default_external(Encoding::US_ASCII) do
        ClaudeAgentSDK.get_subagent_messages(session_id: session_id, agent_id: agent_id, directory: cwd)
      end

      expect(messages.map(&:text)).to eq([question, '', '', answer])
    end
  end

  describe 'a final line cut inside a multibyte character' do
    before do
      transcript = main_transcript
      interrupted = CLITranscript.new(session_id: session_id, cwd: cwd)
                                 .assistant(:interrupted, transcript.text('最后一条回复被截断'), parent: :answer)
      File.binwrite(transcript.write(transcript_path(session_id)),
                    cut_inside(JSON.generate(interrupted), '最'), mode: 'ab')
    end

    it 'returns the complete messages before it' do
      expect(File.binread(transcript_path(session_id))[-1].unpack1('C')).to eq(0xE6) # a lead byte, then EOF

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

      expect(messages.map(&:text)).to eq([question, '', '', answer])
    end

    it 'stays readable after a later rename appended to the file' do
      ClaudeAgentSDK.rename_session(session_id: session_id, title: 'Renamed', directory: cwd)

      expect(ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd).length).to eq(4)
      expect(ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd).custom_title).to eq('Renamed')
    end
  end

  it 'returns a message that holds a raw invalid byte, with the byte replaced by U+FFFD' do
    transcript = main_transcript
    path = transcript.write(transcript_path(session_id))
    File.binwrite(path, File.binread(path).sub('class Foo; end'.b, "class \xFF; end".b))

    messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

    expect(transcript.labels(messages)).to eq(%w[prompt use_a result_a answer])
    result = messages[2].content_blocks.first
    expect(result.content).to eq("class #{replacement}; end")
    expect(result.content).to be_valid_encoding
  end

  describe 'import_session_to_store' do
    # A networked adapter serializes what it is given, and JSON.generate
    # rejects a String that is not valid UTF-8.
    let(:store) do
      Class.new(ClaudeAgentSDK::SessionStore) do
        def initialize
          super
          @rows = Hash.new { |rows, key| rows[key] = [] }
        end

        def append(key, entries)
          @rows[key].concat(entries.map { |entry| JSON.generate(entry) })
        end

        def load(key)
          @rows.key?(key) ? @rows[key].map { |row| JSON.parse(row) } : nil
        end
      end.new
    end

    it 'imports every entry of a transcript that holds a raw invalid byte' do
      transcript = main_transcript
      path = transcript.write(transcript_path(session_id))
      File.binwrite(path, File.binread(path).sub('class Foo; end'.b, "class \xFF; end".b))

      ClaudeAgentSDK.import_session_to_store(session_id: session_id, session_store: store, directory: cwd,
                                             batch_size: 2)

      stored = store.load('project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id)
      expect(stored.map { |entry| entry['type'] }).to eq(transcript.entries.map { |entry| entry['type'] })
      expect(stored[4].dig('message', 'content', 0, 'content')).to eq("class #{replacement}; end")
    end
  end
end
