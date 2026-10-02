# frozen_string_literal: true

require 'spec_helper'
require_relative '../fixtures/cli_transcript'
require_relative '../fixtures/claude_config_dir'

# The CLI writes one assistant entry per tool_use and parents each tool_result
# on the entry holding ITS tool_use. With parallel tool calls only the result
# written last is an ancestor of the leaf; the others hang off the chain as
# siblings of the next tool_use entry. A reader that follows one parentUuid
# path returns tool_use blocks whose results are on disk but not in its answer.
RSpec.describe 'session readers and parallel tool calls' do
  include_context 'with a Claude config dir'

  let(:session_id) { '0d9f6a3c-2b1e-4c7d-8a5f-3e2d1c0b9a88' }
  let(:agent_id) { 'a1b2c3d4e5f60718' }
  let(:store) { ClaudeAgentSDK::InMemorySessionStore.new }

  # Two tool calls of one API message, in the order the CLI writes them:
  #
  #   prompt
  #   └─ think                 assistant[thinking]    msg_01
  #      └─ use_a              assistant[tool_use a]  msg_01
  #         ├─ use_b           assistant[tool_use b]  msg_01
  #         │  ├─ pre          attachment PreToolUse
  #         │  └─ result_b     user[tool_result b]
  #         │     └─ post_b    attachment PostToolUse
  #         │        └─ answer assistant[text]        msg_02   <- leaf
  #         └─ result_a        user[tool_result a]              <- off the leaf's path
  #            └─ post_a       attachment PostToolUse
  #               └─ pre_b     attachment PreToolUse
  def two_tool_batch(transcript)
    transcript.prompt(:prompt, 'Read a.rb and b.rb')
    transcript.assistant(:think, transcript.thinking, parent: :prompt)
    transcript.assistant(:use_a, transcript.tool_use('toolu_a'), parent: :think)
    transcript.assistant(:use_b, transcript.tool_use('toolu_b'), parent: :use_a)
    transcript.attachment(:pre, parent: :use_b, hook: 'PreToolUse')
    transcript.tool_result(:result_a, 'toolu_a', 'contents of a.rb', parent: :use_a)
    transcript.attachment(:post_a, parent: :result_a)
    transcript.attachment(:pre_b, parent: :post_a, hook: 'PreToolUse')
    transcript.tool_result(:result_b, 'toolu_b', 'contents of b.rb', parent: :use_b)
    transcript.attachment(:post_b, parent: :result_b)
    transcript.assistant(:answer, transcript.text('Both files read.'), parent: :post_b, message: 'msg_02')
    transcript
  end

  def main_transcript
    transcript = CLITranscript.new(session_id: session_id, cwd: cwd)
    transcript.queue_operations('Read a.rb and b.rb')
    yield transcript
    transcript.last_prompt('Read a.rb and b.rb', leaf: :answer)
    transcript
  end

  def tool_result_ids(messages)
    messages.flat_map(&:content_blocks).grep(ClaudeAgentSDK::ToolResultBlock).map(&:tool_use_id)
  end

  let(:batch_order) { %w[prompt think use_a use_b result_a result_b answer] }

  describe 'get_session_messages' do
    it 'returns every result of a parallel batch from a transcript on disk' do
      transcript = main_transcript { |t| two_tool_batch(t) }
      transcript.write(transcript_path(session_id))

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

      expect(transcript.labels(messages)).to eq(batch_order)
      expect(tool_result_ids(messages)).to eq(%w[toolu_a toolu_b])
    end

    it 'returns every result of a parallel batch from a session store' do
      transcript = main_transcript { |t| two_tool_batch(t) }
      key = { 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id }
      store.append(key, transcript.store_entries)

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd, session_store: store)

      expect(transcript.labels(messages)).to eq(batch_order)
    end

    it 'returns each result once when a retried mirror batch repeated it in the store' do
      transcript = main_transcript { |t| two_tool_batch(t) }
      key = { 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id }
      store.append(key, transcript.store_entries)
      store.append(key, transcript.store_entries.last(8)) # the retry overlaps the first write

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd, session_store: store)

      expect(transcript.labels(messages)).to eq(batch_order)
    end

    # One API message, three tool calls, streamed: the second call finished
    # before the third tool_use was written (so that entry is parented under
    # result_b), and the first call finished last.
    #
    #   use_a ─ use_b ─ result_b ─ post_b ─ use_c ─ result_c ─ post_c ─ answer
    #     └─ result_a   (written after use_c)
    it 'keeps a late result with its batch: before the first result on the chain' do
      transcript = main_transcript do |t|
        t.prompt(:prompt, 'Read a.rb, b.rb and c.rb')
        t.assistant(:use_a, t.tool_use('toolu_a'), parent: :prompt)
        t.assistant(:use_b, t.tool_use('toolu_b'), parent: :use_a)
        t.attachment(:pre, parent: :use_b, hook: 'PreToolUse')
        t.tool_result(:result_b, 'toolu_b', 'contents of b.rb', parent: :use_b)
        t.attachment(:post_b, parent: :result_b)
        t.assistant(:use_c, t.tool_use('toolu_c'), parent: :post_b)
        t.attachment(:pre_c, parent: :use_c, hook: 'PreToolUse')
        t.tool_result(:result_a, 'toolu_a', 'contents of a.rb', parent: :use_a)
        t.attachment(:post_a, parent: :result_a)
        t.attachment(:pre_x, parent: :post_a, hook: 'PreToolUse')
        t.tool_result(:result_c, 'toolu_c', 'contents of c.rb', parent: :use_c)
        t.attachment(:post_c, parent: :result_c)
        t.assistant(:answer, t.text('All three read.'), parent: :post_c, message: 'msg_02')
      end
      transcript.write(transcript_path(session_id))

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

      expect(transcript.labels(messages)).to eq(%w[prompt use_a use_b result_a result_b use_c result_c answer])
    end

    it 'puts the results of a three-call batch back in the order they were written' do
      transcript = main_transcript do |t|
        t.prompt(:prompt, 'Read a.rb, b.rb and c.rb')
        t.assistant(:use_a, t.tool_use('toolu_a'), parent: :prompt)
        t.assistant(:use_b, t.tool_use('toolu_b'), parent: :use_a)
        t.assistant(:use_c, t.tool_use('toolu_c'), parent: :use_b)
        t.attachment(:pre, parent: :use_c, hook: 'PreToolUse')
        t.tool_result(:result_b, 'toolu_b', 'contents of b.rb', parent: :use_b) # b finished first
        t.attachment(:post_b, parent: :result_b)
        t.tool_result(:result_a, 'toolu_a', 'contents of a.rb', parent: :use_a)
        t.attachment(:post_a, parent: :result_a)
        t.tool_result(:result_c, 'toolu_c', 'contents of c.rb', parent: :use_c)
        t.attachment(:post_c, parent: :result_c)
        t.assistant(:answer, t.text('All three read.'), parent: :post_c, message: 'msg_02')
      end
      transcript.write(transcript_path(session_id))

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

      expect(transcript.labels(messages)).to eq(%w[prompt use_a use_b use_c result_b result_a result_c answer])
    end

    # A rewind leaves the abandoned prompt in the file as a second child of
    # the entry the conversation was rewound to. It is a user sibling too,
    # but it answers no tool call: the branch it starts was dropped.
    it 'does not pull in the prompt of a branch abandoned by a rewind' do
      transcript = main_transcript do |t|
        t.prompt(:prompt, 'Read a.rb')
        t.assistant(:use_a, t.tool_use('toolu_a'), parent: :prompt)
        t.tool_result(:result_a, 'toolu_a', 'contents of a.rb', parent: :use_a)
        t.assistant(:summary, t.text('a.rb defines Foo.'), parent: :result_a, message: 'msg_02')
        t.prompt(:abandoned, 'Now delete it', parent: :summary)
        t.assistant(:abandoned_reply, t.text('Deleted.'), parent: :abandoned, message: 'msg_03')
        t.prompt(:kept, 'Now rename it', parent: :summary)
        t.assistant(:answer, t.text('Renamed.'), parent: :kept, message: 'msg_04')
      end
      transcript.write(transcript_path(session_id))

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

      expect(transcript.labels(messages)).to eq(%w[prompt use_a result_a summary kept answer])
    end

    # Not a shape the CLI writes (a result is parented on its own tool_use
    # entry); it pins the check itself. A user child that carries a
    # tool_result for a call the conversation does not contain stays out.
    it 'does not pull in a tool_result that answers no tool_use of the conversation' do
      transcript = main_transcript do |t|
        t.prompt(:prompt, 'Read a.rb')
        t.assistant(:use_a, t.tool_use('toolu_a'), parent: :prompt)
        t.tool_result(:stray, 'toolu_from_another_branch', 'unrelated', parent: :use_a)
        t.tool_result(:result_a, 'toolu_a', 'contents of a.rb', parent: :use_a)
        t.assistant(:answer, t.text('a.rb defines Foo.'), parent: :result_a, message: 'msg_02')
      end
      transcript.write(transcript_path(session_id))

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

      expect(transcript.labels(messages)).to eq(%w[prompt use_a result_a answer])
    end

    it 'leaves a conversation without parallel calls as it was' do
      transcript = main_transcript do |t|
        t.prompt(:prompt, 'Read a.rb')
        t.assistant(:use_a, t.tool_use('toolu_a'), parent: :prompt)
        t.attachment(:pre, parent: :use_a, hook: 'PreToolUse')
        t.tool_result(:result_a, 'toolu_a', 'contents of a.rb', parent: :use_a)
        t.attachment(:post_a, parent: :result_a)
        t.assistant(:answer, t.text('a.rb defines Foo.'), parent: :post_a, message: 'msg_02')
      end
      transcript.write(transcript_path(session_id))

      messages = ClaudeAgentSDK.get_session_messages(session_id: session_id, directory: cwd)

      expect(transcript.labels(messages)).to eq(%w[prompt use_a result_a answer])
    end
  end

  # Every entry of a real subagent transcript carries isSidechain: true, and
  # its parallel batches have the same shape as the main transcript's.
  describe 'get_subagent_messages' do
    def subagent_transcript
      two_tool_batch(CLITranscript.new(session_id: session_id, cwd: cwd, agent_id: agent_id))
    end

    def parent_session
      transcript = CLITranscript.new(session_id: session_id, cwd: cwd)
      transcript.prompt(:prompt, 'Use a subagent to read a.rb and b.rb')
      transcript
    end

    it 'returns every result of a parallel batch from a subagent transcript on disk' do
      parent_session.write(transcript_path(session_id))
      transcript = subagent_transcript
      transcript.write(subagent_transcript_path(session_id, agent_id))

      messages = ClaudeAgentSDK.get_subagent_messages(session_id: session_id, agent_id: agent_id, directory: cwd)

      expect(transcript.entries.grep(Hash)).to all(include('isSidechain' => true))
      expect(transcript.labels(messages)).to eq(batch_order)
    end

    it 'returns every result of a parallel batch from a subagent transcript in a session store' do
      transcript = subagent_transcript
      key = { 'project_key' => ClaudeAgentSDK.project_key_for_directory(cwd), 'session_id' => session_id }
      store.append(key, parent_session.store_entries)
      store.append(key.merge('subpath' => "subagents/agent-#{agent_id}"), transcript.store_entries)

      messages = ClaudeAgentSDK.get_subagent_messages(session_id: session_id, agent_id: agent_id, directory: cwd,
                                                      session_store: store)

      expect(transcript.labels(messages)).to eq(batch_order)
    end
  end
end
