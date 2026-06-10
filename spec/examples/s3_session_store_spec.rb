# frozen_string_literal: true

require 'spec_helper'
require 'claude_agent_sdk/testing/session_store_conformance'
require_relative '../../examples/session_stores/s3_session_store'

# S3SessionStore is exercised against its bundled in-process RecordingClient
# fake, so this spec runs unconditionally (no aws-sdk-s3 gem or network needed).
RSpec.describe S3SessionStore do
  let(:client) { S3SessionStore::RecordingClient.new }

  def store(prefix: 'transcripts')
    described_class.new(bucket: 'test-bucket', client: client, prefix: prefix)
  end

  it 'passes the full SessionStore conformance suite' do
    expect do
      ClaudeAgentSDK::Testing.run_session_store_conformance(
        -> { described_class.new(bucket: 'test-bucket', client: S3SessionStore::RecordingClient.new) }
      )
    end.not_to raise_error
  end

  it 'requires bucket and client' do
    expect { described_class.new(bucket: nil, client: client) }.to raise_error(ArgumentError)
    expect { described_class.new(bucket: 'b', client: nil) }.to raise_error(ArgumentError)
  end

  describe 'part-file layout' do
    it 'writes one part per append under {prefix}{project_key}/{session_id}/' do
      s = store
      s.append({ 'project_key' => 'pk', 'session_id' => 'sid' }, [{ 'type' => 'user', 'uuid' => 'a' }])
      s.append({ 'project_key' => 'pk', 'session_id' => 'sid' }, [{ 'type' => 'assistant', 'uuid' => 'b' }])

      keys = client.objects.keys
      expect(keys.size).to eq(2)
      expect(keys).to all(match(%r{\Atranscripts/pk/sid/part-\d{13}-[0-9a-f]{6}\.jsonl\z}))
    end

    it 'preserves chronological order across parts on load (lexical == chronological)' do
      s = store
      5.times { |i| s.append({ 'project_key' => 'pk', 'session_id' => 'sid' }, [{ 'type' => 'user', 'uuid' => "u#{i}" }]) }
      loaded = s.load('project_key' => 'pk', 'session_id' => 'sid')
      expect(loaded.map { |e| e['uuid'] }).to eq(%w[u0 u1 u2 u3 u4])
    end
  end

  describe 'Delimiter isolation' do
    it 'does not mix subagent parts into a main-transcript load' do
      s = store
      s.append({ 'project_key' => 'pk', 'session_id' => 'sid' }, [{ 'type' => 'user', 'uuid' => 'main' }])
      s.append({ 'project_key' => 'pk', 'session_id' => 'sid', 'subpath' => 'subagents/agent-1' },
               [{ 'type' => 'user', 'uuid' => 'sub' }])

      main = s.load('project_key' => 'pk', 'session_id' => 'sid')
      expect(main.map { |e| e['uuid'] }).to eq(['main'])

      sub = s.load('project_key' => 'pk', 'session_id' => 'sid', 'subpath' => 'subagents/agent-1')
      expect(sub.map { |e| e['uuid'] }).to eq(['sub'])
    end

    it 'lists only main-transcript sessions (not phantom subagent session_ids)' do
      s = store
      s.append({ 'project_key' => 'pk', 'session_id' => 'sid' }, [{ 'type' => 'user', 'uuid' => 'm' }])
      s.append({ 'project_key' => 'pk', 'session_id' => 'sid', 'subpath' => 'subagents/agent-1' },
               [{ 'type' => 'user', 'uuid' => 's' }])
      expect(s.list_sessions('pk').map { |e| e['session_id'] }).to eq(['sid'])
    end
  end
end
