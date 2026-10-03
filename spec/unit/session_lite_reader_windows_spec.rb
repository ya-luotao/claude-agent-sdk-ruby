# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# The disk listing scans the first and the last 64 KiB of a transcript for a
# handful of fields. The scan steps through the window by offset; Ruby keeps
# no character index for a UTF-8 String that is not ASCII-only, so on such a
# window every offset step walks the bytes from the start. The windows are
# therefore scanned as bytes, and only what is returned is UTF-8.
RSpec.describe 'the 64 KiB windows of the disk session reader' do
  include_context 'with a Claude config dir'

  let(:session_id) { 'a9b8c7d6-e5f4-4a3b-8c2d-1e0f9a8b7c6d' }
  let(:prompt) { '请总结这个仓库的结构' }
  let(:title) { '仓库结构总结' }
  let(:branch) { '功能/会话读取' }
  let(:answer) { '好的。' }
  let(:last_prompt) { '最后一个问题' }

  # A session of about 350 KB of CJK text: neither window is ASCII-only.
  # +head_pad+ ASCII bytes in front of the first answer and +tail_pad+ after
  # the last prompt shift where the two windows are cut.
  def transcript_bytes(head_pad, tail_pad)
    transcript = CLITranscript.new(session_id: session_id, cwd: cwd, git_branch: branch)
    transcript.queue_operations(prompt)
    transcript.prompt(:prompt, prompt)
    parent = :prompt
    60.times do |turn|
      text = transcript.text("#{'x' * head_pad if turn.zero?}#{answer * 500}")
      transcript.assistant(:"answer_#{turn}", text, parent: parent, message: "msg_#{turn}")
      transcript.prompt(:"next_#{turn}", "继续 #{turn} #{'请继续说明' * 100}", parent: :"answer_#{turn}")
      parent = :"next_#{turn}"
    end
    transcript.custom_title(title)
    transcript.tag('重要')
    transcript.last_prompt("#{last_prompt}#{'x' * tail_pad}", leaf: parent)
    transcript.to_jsonl
  end

  def cut_inside_a_character?(bytes)
    window = ClaudeAgentSDK::Sessions::LITE_READ_BUF_SIZE
    [bytes.byteslice(0, window), bytes.byteslice(-window, window)].none? do |part|
      part.force_encoding('UTF-8').valid_encoding?
    end
  end

  # The smallest of +pads+ for which the block names a UTF-8 continuation
  # byte (the second or third byte of one of the fixture's CJK characters).
  def smallest_pad(pads)
    pads.find { |pad| yield(pad).between?(0x80, 0xBF) } || raise('no CJK text where the window is cut')
  end

  # [head pad, tail pad] that cut both windows of the fixture inside a
  # character, read off its unpadded bytes.
  #
  # cwd is on every line and is a temp dir, whose length differs between
  # machines and from run to run. It decides where the windows begin and
  # end, and that can be deep in the ASCII keys and ids of a line, where a
  # byte or two of padding changes nothing. So the pads are computed:
  #
  # * the head window ends inside a character when the byte after it is a
  #   continuation byte; +pad+ bytes in front of the first answer bring the
  #   byte from +pad+ places earlier there (it must lie behind the padding);
  # * the tail window starts inside a character when its first byte is one;
  #   +pad+ bytes after the last prompt move its start +pad+ places on.
  #   Padding in front of the window moves its start and the text alike, so
  #   the head pad does not come into it.
  def window_pads
    plain = transcript_bytes(0, 0).b
    window = ClaudeAgentSDK::Sessions::LITE_READ_BUF_SIZE
    tail_start = plain.bytesize - window
    [
      smallest_pad(0...(window - plain.index(answer.b))) { |pad| plain.getbyte(window - pad) },
      smallest_pad(0...(plain.rindex(last_prompt.b) - tail_start)) { |pad| plain.getbyte(tail_start + pad) }
    ]
  end

  # The fixture with both of its windows cut inside a 3-byte character.
  def write_transcript
    bytes = transcript_bytes(*window_pads)
    expect(cut_inside_a_character?(bytes)).to be(true), 'the fixture does not cut both windows inside a character'

    path = transcript_path(session_id)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    path
  end

  def utf8_strings(info)
    %i[summary custom_title first_prompt git_branch cwd tag].to_h { |field| [field, info.public_send(field)] }
  end

  it 'scans the windows as bytes' do
    path = write_transcript

    windows = ClaudeAgentSDK::Sessions.read_head_tail(path, File.size(path))

    expect(windows.map(&:encoding)).to eq([Encoding::BINARY, Encoding::BINARY])
  end

  it 'returns every field as a valid UTF-8 String with its value' do
    write_transcript

    info = ClaudeAgentSDK.get_session_info(session_id: session_id, directory: cwd)

    expect(File.size(transcript_path(session_id))).to be > 2 * ClaudeAgentSDK::Sessions::LITE_READ_BUF_SIZE
    expect(utf8_strings(info)).to eq(summary: title, custom_title: title, first_prompt: prompt, git_branch: branch,
                                     cwd: cwd, tag: '重要')
    expect(utf8_strings(info).values.map(&:encoding).uniq).to eq([Encoding::UTF_8])
    expect(utf8_strings(info).values).to all(be_valid_encoding)
  end

  # The value of a field on a line the window cut off, and a value that is
  # not a well-formed JSON string (a raw tab), come back as slices of the
  # window rather than from a JSON parse.
  describe 'values returned as slices of the window' do
    let(:window) { "{\"type\":\"custom-title\",\"customTitle\":\"#{title}\",\"sessionId\":\"x\"}\n".b }

    it 'returns a value from a line cut by the window as UTF-8' do
      cut = window[0, window.index('sessionId'.b)]

      value = ClaudeAgentSDK::Sessions.extract_top_level_string_field(cut, 'customTitle', last: true)

      expect([value, value.encoding, value.valid_encoding?]).to eq([title, Encoding::UTF_8, true])
    end

    it 'returns a value that does not parse as a JSON string as UTF-8' do
      raw = window.sub(title.b, "#{title}\t原文".b)

      value = ClaudeAgentSDK::Sessions.extract_json_string_field(raw, 'customTitle', last: true)

      expect([value, value.encoding, value.valid_encoding?]).to eq(["#{title}\t原文", Encoding::UTF_8, true])
    end
  end
end
