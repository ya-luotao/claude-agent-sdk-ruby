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
# 13-digit prefix is a logical epoch-ms sequence reserved via conditional PUT
# of a per-transcript .sequence object, so ordering survives instance handoff
# and clock rollback. Concurrent appends are ordered by reservation, NOT upload
# completion; a failed upload leaves a harmless gap. Reads during concurrent
# appends may omit unfinished uploads (they are not transactional snapshots).
# Old part files remain readable. Upgrade all writers before writing again:
# old writers do not participate in the sequence protocol.
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
require 'digest'
require 'securerandom'
require 'stringio'
require 'claude_agent_sdk'

# S3-backed SessionStore. #append = PutObject of a new part file; #load =
# ListObjectsV2 + sort + GetObject + concat.
class S3SessionStore < ClaudeAgentSDK::SessionStore
  PART_MTIME_RE = %r{/part-(\d{13})-[0-9a-f]{6}\.jsonl\z}
  SEQUENCE_FILE = '.sequence'
  SEQUENCE_ATTEMPTS = 8

  # @param bucket [String] S3 bucket name.
  # @param client [Aws::S3::Client] pre-configured client (caller controls
  #   region, credentials, endpoint, etc.). Any object responding to put_object/
  #   list_objects_v2/get_object/delete_objects works if it implements S3's
  #   strong consistency and conditional PUT/ETag semantics (see RecordingClient).
  # @param prefix [String] optional key prefix; a trailing slash is normalized.
  def initialize(bucket:, client:, prefix: '')
    super()
    raise ArgumentError, "S3SessionStore requires 'bucket' and 'client'" if bucket.nil? || client.nil?

    @bucket = bucket
    # Non-empty prefix always ends in exactly one '/'; empty stays empty.
    @prefix = prefix.empty? ? '' : "#{prefix.sub(%r{/+\z}, '')}/"
    @client = client
  end

  def append(key, entries)
    return if entries.nil? || entries.empty?

    body = "#{entries.map { |e| JSON.generate(e) }.join("\n")}\n"
    object_key = key_prefix(key) + next_part_name(key)
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
      next if k == prefix + SEQUENCE_FILE

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
      next if k.end_with?("/#{SEQUENCE_FILE}")

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
      next if k.end_with?("/#{SEQUENCE_FILE}")

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

  # S3 conditional PUT is the serialization point, shared by all instances.
  # A lost response or failed part upload can consume a number; never reuse it.
  # This costs one GET + one PUT per append, plus a one-time legacy-part scan.
  # Do not delete/expire .sequence while writers are active.
  def next_part_name(key)
    prefix = key_prefix(key)
    sequence_key = prefix + SEQUENCE_FILE
    SEQUENCE_ATTEMPTS.times do
      previous, condition = read_sequence(sequence_key, prefix)
      ms = [(Time.now.to_f * 1000).to_i, previous + 1].max
      begin
        @client.put_object(bucket: @bucket, key: sequence_key, body: ms.to_s,
                           content_type: 'text/plain', **condition)
        return format('part-%013d-%s.jsonl', ms, SecureRandom.hex(3))
      rescue StandardError => e
        # 412 = another writer won; 409 = conditional-write conflict. Re-read
        # the current ETag before retrying. Other errors must reach the caller.
        raise unless [409, 412].include?(http_status(e))
      end
    end
    raise 'S3 append sequence contention exceeded retry limit'
  end

  def read_sequence(sequence_key, prefix)
    response = @client.get_object(bucket: @bucket, key: sequence_key)
    [Integer(response.body.read, 10), { if_match: response.etag }]
  rescue StandardError => e
    raise unless http_status(e) == 404

    # First writer after upgrade starts beyond every legacy part, not merely
    # beyond its own wall clock. Concurrent initializers compete with If-None-Match.
    last = 0
    each_listed(prefix: prefix, delimiter: '/') do |k|
      next if k[prefix.length..].include?('/')

      match = PART_MTIME_RE.match(k)
      last = [last, match[1].to_i].max if match
    end
    [last, { if_none_match: '*' }]
  end

  # Avoid requiring aws-sdk-s3 just to load this reference implementation.
  def http_status(error)
    error.context.http_response.status_code if error.respond_to?(:context)
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
# direct children appear in #contents), pagination, and atomic conditional
# writes. ETags are opaque quoted digests; missing keys / precondition failures
# expose the same HTTP status path as aws-sdk-s3 errors.
class S3SessionStore
  class RecordingClient
    Listed = Struct.new(:key, :last_modified)
    ListResult = Struct.new(:contents, :next_continuation_token)
    GetResult = Struct.new(:body, :etag)
    DeleteError = Struct.new(:key, :code)
    DeleteResult = Struct.new(:errors)
    HttpResponse = Struct.new(:status_code)
    Context = Struct.new(:http_response)

    class HttpError < StandardError
      attr_reader :context

      def initialize(status)
        super("S3 HTTP #{status}")
        @context = Context.new(HttpResponse.new(status))
      end
    end

    attr_reader :objects, :calls

    def initialize(page_size: 1000)
      @objects = {}
      @calls = []
      @mutex = Mutex.new
      @page_size = page_size
    end

    def put_object(bucket:, key:, body:, if_match: nil, if_none_match: nil, **_rest)
      @mutex.synchronize do
        @calls << [:put_object, { bucket: bucket, key: key, if_match: if_match, if_none_match: if_none_match }]
        raise HttpError.new(412) if if_none_match == '*' && @objects.key?(key)
        raise HttpError.new(404) if if_match && !@objects.key?(key)
        raise HttpError.new(412) if if_match && if_match != etag(@objects[key])

        @objects[key] = body.dup
        {}
      end
    end

    def list_objects_v2(bucket:, prefix: '', delimiter: nil, continuation_token: nil, **_rest)
      @mutex.synchronize do
        @calls << [:list_objects_v2, { bucket: bucket, prefix: prefix, delimiter: delimiter }]
        contents = @objects.keys.sort.filter_map do |k|
          next unless k.start_with?(prefix)
          next if delimiter == '/' && k[prefix.length..].include?('/')
          next if continuation_token && k <= continuation_token

          Listed.new(k, Time.at(1_800_000_000))
        end
        page = contents.first(@page_size)
        ListResult.new(page, contents.length > page.length ? page.last.key : nil)
      end
    end

    def get_object(bucket:, key:, **_rest)
      @mutex.synchronize do
        @calls << [:get_object, { bucket: bucket, key: key }]
        raise HttpError.new(404) unless @objects.key?(key)

        body = @objects.fetch(key).dup
        GetResult.new(StringIO.new(body), etag(body))
      end
    end

    def delete_objects(bucket:, delete:, **_rest)
      @mutex.synchronize do
        @calls << [:delete_objects, { bucket: bucket }]
        delete[:objects].each { |obj| @objects.delete(obj[:key]) }
        DeleteResult.new([])
      end
    end

    private

    def etag(body)
      %Q("#{Digest::SHA256.hexdigest(body)}")
    end
  end
end
