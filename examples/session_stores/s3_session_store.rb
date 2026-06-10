# frozen_string_literal: true

# S3-backed ClaudeAgentSDK::SessionStore reference adapter.
#
# This is a REFERENCE implementation — copy it into your own project and adapt
# as needed. It mirrors the S3 reference adapters in the Python and TypeScript
# SDKs.
#
# Transcripts are stored as JSONL part files:
#
#     s3://{bucket}/{prefix}{project_key}/{session_id}/part-{epochMs13}-{rand6}.jsonl
#
# Each #append writes a new part; #load lists, sorts, and concatenates them. The
# 13-digit zero-padded epoch-ms prefix means lexical key order == chronological
# order. A per-instance monotonic millisecond counter orders same-instance
# same-ms appends; the random hex suffix disambiguates concurrent instances.
#
# Requires the `aws-sdk-s3` gem (not a dependency of claude-agent-sdk):
#
#     gem install aws-sdk-s3
#
# Usage:
#
#     require 'aws-sdk-s3'
#     require 'claude_agent_sdk'
#     require_relative 's3_session_store'
#
#     store = S3SessionStore.new(bucket: 'my-claude-sessions', prefix: 'transcripts',
#                                client: Aws::S3::Client.new(region: 'us-east-1'))
#
#     ClaudeAgentSDK.query(prompt: 'Hello!',
#                          options: ClaudeAgentSDK::ClaudeAgentOptions.new(session_store: store)) do |msg|
#       # messages are mirrored to S3 automatically
#     end
#
# Retention: this adapter never deletes objects on its own. Configure an S3
# lifecycle policy on the bucket/prefix to expire transcripts. #delete is
# implemented but only invoked when you call delete_session_via_store from the
# SDK.
require 'json'
require 'securerandom'
require 'stringio'
require 'claude_agent_sdk'

# S3-backed SessionStore. #append = PutObject of a new part file; #load =
# ListObjectsV2 + sort + GetObject + concat.
class S3SessionStore < ClaudeAgentSDK::SessionStore
  PART_MTIME_RE = %r{/part-(\d{13})-[0-9a-f]{6}\.jsonl\z}

  # @param bucket [String] S3 bucket name.
  # @param client [Aws::S3::Client] pre-configured client (caller controls
  #   region, credentials, endpoint, etc.). Any object responding to put_object/
  #   list_objects_v2/get_object/delete_objects works (see RecordingClient).
  # @param prefix [String] optional key prefix; a trailing slash is normalized.
  def initialize(bucket:, client:, prefix: '')
    super()
    raise ArgumentError, "S3SessionStore requires 'bucket' and 'client'" if bucket.nil? || client.nil?

    @bucket = bucket
    # Non-empty prefix always ends in exactly one '/'; empty stays empty.
    @prefix = prefix.empty? ? '' : "#{prefix.sub(%r{/+\z}, '')}/"
    @client = client
    @last_ms = 0
    @mutex = Mutex.new
  end

  def append(key, entries)
    return if entries.nil? || entries.empty?

    object_key = key_prefix(key) + next_part_name
    body = "#{entries.map { |e| JSON.generate(e) }.join("\n")}\n"
    @client.put_object(bucket: @bucket, key: object_key, body: body, content_type: 'application/x-ndjson')
    nil
  end

  def load(key)
    prefix = key_prefix(key)

    # List part files directly under this prefix only. Without Delimiter, S3
    # recurses into subpaths (e.g. subagents/*), so a main-transcript load would
    # mix in subagent entries — diverging from InMemorySessionStore's exact-key
    # semantics and corrupting resume.
    keys = []
    each_listed(prefix: prefix, delimiter: '/') do |k|
      # Guard against S3-compatibles that ignore Delimiter: keep only direct
      # children (part files have no '/' after the prefix).
      keys << k unless k[prefix.length..].include?('/')
    end
    return nil if keys.empty?

    # 13-digit epochMs prefix is fixed-width, so lexical == chronological.
    keys.sort!

    all_entries = []
    fetch_bodies(keys).each do |body|
      body = body.force_encoding('UTF-8') if body.respond_to?(:force_encoding)
      body.split("\n").each do |line|
        trimmed = line.strip
        next if trimmed.empty?

        begin
          all_entries << JSON.parse(trimmed)
        rescue JSON::ParserError
          next # skip malformed lines
        end
      end
    end
    all_entries.empty? ? nil : all_entries
  end

  def list_sessions(project_key)
    prefix = project_prefix(project_key)
    sessions = {}

    # List Contents (no Delimiter) so mtime can be derived from each part
    # filename's 13-digit epochMs prefix. CommonPrefixes carry no timestamp.
    each_listed(prefix: prefix) do |k, last_modified|
      # {prefix}{session_id}/part-{epochMs13}-{rand}.jsonl
      rest = k[prefix.length..]
      slash = rest.index('/')
      next if slash.nil?
      # Main-transcript parts only (one level under session_id); deeper keys are
      # subagent parts and would surface phantom session_ids / skew mtime.
      next if rest.index('/', slash + 1)

      session_id = rest[0...slash]
      m = PART_MTIME_RE.match(k)
      mtime = if m
                m[1].to_i
              elsif last_modified
                (last_modified.to_f * 1000).to_i
              else
                0
              end
      sessions[session_id] = mtime if mtime > (sessions[session_id] || 0)
    end

    sessions.map { |sid, mtime| { 'session_id' => sid, 'mtime' => mtime } }
  end

  def delete(key)
    prefix = key_prefix(key)
    # Match InMemorySessionStore: whole-session delete cascades into subpaths;
    # delete({subpath: 'a'}) is exact-key only (must NOT touch 'a/b'). An
    # empty-string subpath is treated as "no subpath" (main), matching
    # key_prefix / append, so it cascades like nil.
    subpath = key['subpath']
    direct_only = !(subpath.nil? || subpath.empty?)

    to_delete = []
    each_listed(prefix: prefix, delimiter: (direct_only ? '/' : nil)) do |k|
      next if direct_only && k[prefix.length..].include?('/')

      to_delete << { key: k }
    end
    return nil if to_delete.empty?

    # S3 DeleteObjects caps at 1000 keys per request.
    to_delete.each_slice(1000) do |batch|
      result = @client.delete_objects(bucket: @bucket, delete: { objects: batch, quiet: true })
      errors = result.errors || []
      next if errors.empty?

      detail = errors.map { |e| "#{e.key}: #{e.code}" }.join(', ')
      raise "S3 delete failed for #{errors.length} object(s): #{detail}"
    end
    nil
  end

  def list_subkeys(key)
    prefix = key_prefix('project_key' => key['project_key'], 'session_id' => key['session_id'])
    subkeys = []
    seen = {}
    each_listed(prefix: prefix) do |k|
      # {prefix}{project_key}/{session_id}/{subpath}/part-{epochMs}-{rand}.jsonl
      rel = k[prefix.length..]
      parts = rel.split('/')
      next unless parts.length >= 2

      # subpath is everything except the last segment (the part file).
      subpath = parts[0..-2].join('/')
      next if subpath.empty? || seen[subpath]

      seen[subpath] = true
      subkeys << subpath
    end

    # Defense-in-depth: drop '..'/'.'/'' segments (never produced by legit
    # writers). The primary traversal guard stays in materialize_resume_session.
    subkeys.reject { |sp| sp.split('/').any? { |seg| ['..', '.', ''].include?(seg) } }
  end

  # Bounded GetObject concurrency for #load (matches the Python reference's
  # 16-way limiter). Each #append writes a new part, so a long eager-mirrored
  # session accumulates hundreds of parts — fetching them serially puts
  # part_count x RTT on the resume path, enough to blow the default 60s load
  # timeout near ~1,000 parts.
  LOAD_CONCURRENCY = 16

  private

  # Fetch part bodies with a small worker pool, preserving +keys+ order. A
  # worker's failure propagates from Thread#join, matching the serial loop's
  # raise-on-failure semantics.
  def fetch_bodies(keys)
    bodies = Array.new(keys.length)
    next_index = -1
    index_mutex = Mutex.new
    workers = [LOAD_CONCURRENCY, keys.length].min.times.map do
      Thread.new do
        loop do
          i = index_mutex.synchronize { next_index += 1 }
          break if i >= keys.length

          bodies[i] = @client.get_object(bucket: @bucket, key: keys[i]).body.read
        end
      end
    end
    workers.each(&:join)
    bodies
  end

  # Directory prefix for a session (or subpath). Always ends in '/'.
  def key_prefix(key)
    parts = [key['project_key'], key['session_id']]
    subpath = key['subpath']
    parts << subpath if subpath && !subpath.empty?
    "#{@prefix}#{parts.join('/')}/"
  end

  # Directory prefix for a project. Always ends in '/'.
  def project_prefix(project_key)
    "#{@prefix}#{project_key}/"
  end

  # Fixed-width epoch ms => lexical sort == chronological. `last_ms + 1` makes
  # same-instance same-ms appends deterministic; the random suffix disambiguates
  # instances. Guarded by a mutex since the SDK may append from multiple threads.
  def next_part_name
    ms = @mutex.synchronize do
      @last_ms = [(Time.now.to_f * 1000).to_i, @last_ms + 1].max
    end
    format('part-%013d-%s.jsonl', ms, SecureRandom.hex(3))
  end

  # Yield every listed object key (and its LastModified) under +prefix+,
  # following ContinuationToken pagination. +delimiter+ restricts to direct
  # children when set to '/'.
  def each_listed(prefix:, delimiter: nil)
    token = nil
    loop do
      params = { bucket: @bucket, prefix: prefix }
      params[:delimiter] = delimiter if delimiter
      params[:continuation_token] = token if token
      result = @client.list_objects_v2(**params)
      (result.contents || []).each do |obj|
        k = obj.key
        yield(k, obj.respond_to?(:last_modified) ? obj.last_modified : nil) if k
      end
      token = result.next_continuation_token
      break if token.nil? || token.empty?
    end
  end
end

# Minimal in-memory S3 client double for unit tests. Implements only the four
# methods S3SessionStore calls and returns response objects shaped like
# aws-sdk-s3's (method-style accessors). Honors Prefix and Delimiter='/' (only
# direct children appear in #contents). Records every call so tests can assert
# on operation sequences without a network round-trip.
class S3SessionStore
  class RecordingClient
    Listed = Struct.new(:key, :last_modified)
    ListResult = Struct.new(:contents, :next_continuation_token)
    GetResult = Struct.new(:body)
    DeleteError = Struct.new(:key, :code)
    DeleteResult = Struct.new(:errors)

    attr_reader :objects, :calls

    def initialize
      @objects = {}
      @calls = []
    end

    def put_object(bucket:, key:, body:, **_rest)
      @calls << [:put_object, { bucket: bucket, key: key }]
      @objects[key] = body.is_a?(String) ? body.dup : body
      {}
    end

    def list_objects_v2(bucket:, prefix: '', delimiter: nil, **_rest)
      @calls << [:list_objects_v2, { bucket: bucket, prefix: prefix, delimiter: delimiter }]
      contents = @objects.keys.filter_map do |k|
        next unless k.start_with?(prefix)
        next if delimiter == '/' && k[prefix.length..].include?('/')

        Listed.new(k, nil)
      end
      ListResult.new(contents, nil)
    end

    def get_object(bucket:, key:, **_rest)
      @calls << [:get_object, { bucket: bucket, key: key }]
      GetResult.new(StringIO.new(@objects.fetch(key)))
    end

    def delete_objects(bucket:, delete:, **_rest)
      @calls << [:delete_objects, { bucket: bucket }]
      delete[:objects].each { |obj| @objects.delete(obj[:key]) }
      DeleteResult.new([])
    end
  end
end
