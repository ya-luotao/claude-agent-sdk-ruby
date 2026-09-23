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

      keys = client.objects.keys - ['transcripts/pk/sid/.sequence']
      expect(keys.size).to eq(2)
      expect(keys).to all(match(%r{\Atranscripts/pk/sid/part-\d{13}-[0-9a-f]{6}\.jsonl\z}))
    end

    it 'preserves chronological order across parts on load (lexical == chronological)' do
      s = store
      5.times { |i| s.append({ 'project_key' => 'pk', 'session_id' => 'sid' }, [{ 'type' => 'user', 'uuid' => "u#{i}" }]) }
      loaded = s.load('project_key' => 'pk', 'session_id' => 'sid')
      expect(loaded.map { |e| e['uuid'] }).to eq(%w[u0 u1 u2 u3 u4])
    end

    it 'preserves order across sequential instance handoff after a same-ms burst' do
      key = { 'project_key' => 'pk', 'session_id' => 'sid' }
      allow(Time).to receive(:now).and_return(Time.at(1_800_000_000))
      first = store
      5.times { |i| first.append(key, [{ 'type' => 'user', 'customTitle' => i.to_s }]) }
      allow(Time).to receive(:now).and_return(Time.at(1_800_000_000, 1000))
      store.append(key, [{ 'type' => 'user', 'customTitle' => 'latest' }])

      expect(store.load(key).map { |e| e['customTitle'] }).to eq(%w[0 1 2 3 4 latest])
    end

    it 'does not use random suffix order for same-ms writes by separate instances' do
      key = { 'project_key' => 'pk', 'session_id' => 'sid' }
      allow(Time).to receive(:now).and_return(Time.at(1_800_000_000))
      allow(SecureRandom).to receive(:hex).with(3).and_return('ffffff', '000000')
      store.append(key, [{ 'type' => 'user', 'n' => 1 }])
      store.append(key, [{ 'type' => 'user', 'n' => 2 }])

      expect(store.load(key).map { |e| e['n'] }).to eq([1, 2])
    end

    it 'continues above existing legacy part timestamps even when the wall clock is behind' do
      key = { 'project_key' => 'pk', 'session_id' => 'sid' }
      client.put_object(bucket: 'test-bucket', key: 'transcripts/pk/sid/part-2000000000000-ffffff.jsonl',
                        body: "{\"type\":\"user\",\"n\":1}\n")
      allow(Time).to receive(:now).and_return(Time.at(1_800_000_000))
      store.append(key, [{ 'type' => 'user', 'n' => 2 }])

      expect(store.load(key).map { |e| e['n'] }).to eq([1, 2])
    end
  end

  describe 'durable sequence reservations' do
    let(:key) { { 'project_key' => 'pk', 'session_id' => 'sid' } }

    before { allow(Time).to receive(:now).and_return(Time.at(1_800_000_000)) }

    [false, true].each do |existing|
      it "retries a competing #{existing ? 'ETag update' : 'initial creation'} without reusing a sequence" do
        store.append(key, [{ 'type' => 'user', 'n' => 0 }]) if existing
        arrivals = Queue.new
        paused = {}
        lock = Mutex.new
        allow(client).to receive(:put_object).and_wrap_original do |original, **params|
          if params[:key].end_with?('/.sequence') && lock.synchronize { !paused[Thread.current] && (paused[Thread.current] = true) }
            gate = Queue.new
            arrivals << gate
            gate.pop
          end
          original.call(**params)
        end

        first = Thread.new { store.append(key, [{ 'type' => 'user', 'n' => 1 }]) }
        gate1 = arrivals.pop(timeout: 2)
        expect(gate1).not_to be_nil
        second = Thread.new { store.append(key, [{ 'type' => 'user', 'n' => 2 }]) }
        gate2 = arrivals.pop(timeout: 2)
        expect(gate2).not_to be_nil
        gate1 << true
        expect(first.join(2)).not_to be_nil
        first.value
        gate2 << true
        expect(second.join(2)).not_to be_nil
        second.value

        expect(store.load(key).map { |e| e['n'] }).to eq(existing ? [0, 1, 2] : [1, 2])
        writes = client.calls.select { |op, p| op == :put_object && p[:key].end_with?('/.sequence') }
        expect(writes.length).to eq(existing ? 4 : 3) # includes the rejected stale reservation
        expect(writes.last.last[:if_match]).not_to be_nil
      ensure
        gate1 << true if gate1
        gate2 << true if gate2
        [first, second].compact.each { |thread| thread.join(2) }
      end
    end

    it 'orders concurrent uploads by reservation even when the second upload finishes first' do
      ready = Queue.new
      release = Queue.new
      allow(client).to receive(:put_object).and_wrap_original do |original, **params|
        if params[:content_type] == 'application/x-ndjson' && JSON.parse(params[:body])['n'] == 1
          ready << true
          release.pop
        end
        original.call(**params)
      end
      first = Thread.new { store.append(key, [{ 'type' => 'user', 'n' => 1 }]) }
      expect(ready.pop(timeout: 2)).to be(true)
      store.append(key, [{ 'type' => 'user', 'n' => 2 }])
      expect(store.load(key).map { |e| e['n'] }).to eq([2])
      release << true
      expect(first.join(2)).not_to be_nil
      first.value
      expect(store.load(key).map { |e| e['n'] }).to eq([1, 2])
    ensure
      release << true
      first&.join(2)
    end

    it 'does not expose reservations as transcripts or subkeys after a failed upload' do
      allow(client).to receive(:put_object).and_wrap_original do |original, **params|
        raise 'upload failed' if params[:content_type] == 'application/x-ndjson'

        original.call(**params)
      end
      sub = key.merge('subpath' => 'subagents/agent-1')
      [key, sub].each do |target|
        expect { store.append(target, [{ 'type' => 'user' }]) }.to raise_error('upload failed')
        expect(store.load(target)).to be_nil
      end
      expect(store.list_sessions('pk')).to eq([])
      expect(store.list_subkeys(key)).to eq([])
      allow(client).to receive(:put_object).and_call_original
      store.append(key, [{ 'type' => 'user', 'n' => 2 }])
      expect(store.load(key).map { |e| e['n'] }).to eq([2])
      expect(client.objects.keys.grep(/\.jsonl\z/)).to contain_exactly(
        match(%r{\Atranscripts/pk/sid/part-1800000000001-[0-9a-f]{6}\.jsonl\z})
      )
      store.delete(key)
      expect(client.objects).to be_empty
    end

    it 'scans all legacy pages and ignores subagent timestamps when bootstrapping' do
      paged = S3SessionStore::RecordingClient.new(page_size: 1)
      [1_900_000_000_000, 2_000_000_000_000].each_with_index do |ms, i|
        paged.put_object(bucket: 'b', key: "pk/sid/part-#{ms}-000000.jsonl", body: JSON.generate('n' => i))
      end
      paged.put_object(bucket: 'b', key: 'pk/sid/subagents/a/part-3000000000000-000000.jsonl', body: '{}')
      s = described_class.new(bucket: 'b', client: paged)
      s.append(key, [{ 'n' => 2 }])

      expect(s.load(key).map { |e| e['n'] }).to eq([0, 1, 2])
      expect(paged.objects['pk/sid/.sequence']).to eq('2000000000001')
    end

    [409, 412].each do |status|
      it "bounds repeated HTTP #{status} contention instead of writing an unreserved part" do
        allow(client).to receive(:put_object).and_raise(S3SessionStore::RecordingClient::HttpError.new(status))
        expect { store.append(key, [{ 'n' => 1 }]) }.to raise_error(/contention exceeded/)
        expect(client).to have_received(:put_object).exactly(8).times
        expect(client.objects).to be_empty
      end
    end

    it 'propagates access errors without treating them as contention or absence' do
      allow(client).to receive(:get_object).and_raise(S3SessionStore::RecordingClient::HttpError.new(403))
      expect { store.append(key, [{ 'n' => 1 }]) }.to raise_error(/403/)
      expect(client).to have_received(:get_object).once
      expect(client.calls).to be_empty
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
