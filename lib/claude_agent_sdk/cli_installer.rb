# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'uri'
require_relative 'errors'

module ClaudeAgentSDK
  # Downloads a pinned Claude Code CLI binary into a project-local directory.
  #
  # Motivation: the SDK shells out to `claude`, so a deploy artifact is only
  # hermetic if the CLI version is pinned alongside it. Vendoring the ~280MB
  # binary into the gem is a non-starter, so instead a Docker build / bin/setup
  # step calls +install+, and SubprocessCLITransport#find_cli prefers that
  # vendored copy over whatever is on PATH.
  #
  # Mirrors what https://claude.ai/install.sh does: resolve a dist-tag to a
  # concrete version, read the release manifest for the platform's SHA-256,
  # stream the binary down, verify it, then move it into place atomically.
  #
  # Stdlib only (net/http, json, digest, fileutils, rbconfig) — the gem gains
  # no runtime dependency for this.
  #
  # @example Pin a version in bin/setup or a Dockerfile build step
  #   ClaudeAgentSDK::CLIInstaller.install(version: '2.1.220')
  module CLIInstaller
    BASE_URL = 'https://downloads.claude.ai/claude-code-releases'
    # Dist-tags resolved through a GET to BASE_URL/<tag>.
    DIST_TAGS = %w[stable latest].freeze
    # Concrete version, optionally with a pre-release suffix (e.g. 2.1.220-rc1).
    VERSION_PATTERN = /\A\d+\.\d+\.\d+(-\S+)?\z/
    CHECKSUM_PATTERN = /\A[0-9a-f]{64}\z/
    BINARY_NAME = 'claude'
    VERSION_FILE = 'VERSION'
    LOCK_FILE = '.install.lock'
    # Relative to Dir.pwd, resolved at CALL time by .default_dir — an absolute
    # constant would freeze the working directory as of require time, which is
    # wrong for anything that chdirs (Rake tasks, bin/setup, test suites).
    DEFAULT_DIR = File.join('vendor', 'claude')
    # Response caps. The dist-tag endpoints return a bare version string and
    # manifests are a few KB; anything larger is a misrouted response, not
    # something to buffer in memory. (The binary itself streams to disk.)
    VERSION_RESPONSE_LIMIT = 1024
    MANIFEST_RESPONSE_LIMIT = 5 * 1024 * 1024
    METADATA_READ_LIMIT = 4096

    # Maps the running Ruby to a release-manifest platform key
    # (darwin-arm64, darwin-x64, linux-x64, linux-arm64, and the -musl
    # variants). Windows is not supported by this gem.
    module Platform
      class << self
        def detect
          target = ruby_platform.to_s.downcase
          os = detect_os(target)
          arch = detect_arch(target)
          # A Ruby built for x86_64 running under Rosetta 2 reports darwin-x64,
          # but the machine is arm64 — install the native binary.
          arch = 'arm64' if os == 'darwin' && arch == 'x64' && rosetta?
          suffix = os == 'linux' && target.include?('musl') ? '-musl' : ''
          "#{os}-#{arch}#{suffix}"
        end

        private

        def detect_os(target)
          return 'darwin' if target.include?('darwin')
          return 'linux' if target.include?('linux')

          raise CLIInstallError,
                "Unsupported platform #{ruby_platform.inspect} for the Claude Code CLI " \
                '(supported: macOS and Linux; Windows is not supported by this gem)'
        end

        def detect_arch(target)
          case target
          when /aarch64|arm64/ then 'arm64'
          when /x86_64|x64|amd64/ then 'x64'
          else
            raise CLIInstallError,
                  "Unsupported CPU architecture in #{ruby_platform.inspect} (supported: x86_64 and arm64)"
          end
        end

        # Single source of platform truth, and the seam the specs stub.
        # RUBY_PLATFORM carries OS, CPU and libc on CRuby; JRuby reports a
        # bare 'java', so fall back to the RbConfig host description there.
        def ruby_platform
          return RUBY_PLATFORM unless RUBY_PLATFORM == 'java'

          "#{RbConfig::CONFIG['host_os']}-#{RbConfig::CONFIG['host_cpu']}"
        end

        def rosetta?
          stdout, status = Open3.capture2('sysctl', '-n', 'sysctl.proc_translated')
          status.success? && stdout.strip == '1'
        rescue StandardError
          # sysctl missing or not permitted — assume native.
          false
        end
      end
    end

    # HTTPS GET with bounded redirects, timeouts, a response-size cap for text
    # and chunked streaming for the binary. Knows nothing about releases; the
    # specs stub .fetch_text / .download_to wholesale so no HTTP stubbing
    # library is needed.
    module Http
      MAX_REDIRECTS = 5
      OPEN_TIMEOUT_SECONDS = 10
      READ_TIMEOUT_SECONDS = 60

      class << self
        # +limit+ bounds how many bytes are buffered: the caller knows the
        # expected shape of the response, and an unbounded read of a misrouted
        # (or hostile) endpoint is an easy way to exhaust memory.
        def fetch_text(url, limit:)
          with_response(url) do |response|
            body = +''
            response.read_body do |chunk|
              body << chunk
              raise CLIInstallError, "Response from #{url} exceeds the #{limit}-byte limit" if body.bytesize > limit
            end
            body
          end
        end

        # Streams the response to +path+ in chunks — the CLI binary is ~280MB
        # and must never be materialized in memory. O_EXCL: +path+ must not
        # exist, so a pre-planted file or symlink is never written through.
        # +max_bytes+ (the manifest's declared size, when it has one) aborts a
        # response that runs long instead of filling the disk before the
        # checksum gets a chance to reject it.
        def download_to(url, path, max_bytes: nil)
          with_response(url) do |response|
            written = 0
            File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |file|
              response.read_body do |chunk|
                written += chunk.bytesize
                raise CLIInstallError, "Download from #{url} exceeds the expected #{max_bytes} bytes" if over?(written, max_bytes)

                file.write(chunk)
              end
            end
          end
          path
        end

        private

        def over?(written, max_bytes)
          !max_bytes.nil? && written > max_bytes
        end

        def with_response(url, redirects_left = MAX_REDIRECTS, &block)
          uri = url.is_a?(URI::Generic) ? url : URI(url.to_s)
          raise CLIInstallError, "Refusing to fetch non-HTTPS URL: #{uri}" unless uri.is_a?(URI::HTTPS)

          Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                              open_timeout: OPEN_TIMEOUT_SECONDS,
                                              read_timeout: READ_TIMEOUT_SECONDS) do |http|
            http.request(Net::HTTP::Get.new(uri)) do |response|
              # Branch on the status BEFORE touching the body: a redirect or an
              # error page must never be streamed into the target file.
              return block.call(response) if response.is_a?(Net::HTTPSuccess)
              return follow_redirect(uri, response, redirects_left, &block) if response.is_a?(Net::HTTPRedirection)

              raise CLIInstallError, "HTTP #{response.code} #{response.message} for #{uri}"
            end
          end
        rescue CLIInstallError
          raise
        rescue StandardError => e
          raise CLIInstallError, "Failed to fetch #{url}: #{e.class}: #{e.message}"
        end

        def follow_redirect(uri, response, redirects_left, &block)
          raise CLIInstallError, "Too many redirects while fetching #{uri}" if redirects_left <= 0

          location = response['location'].to_s
          raise CLIInstallError, "Redirect from #{uri} is missing a Location header" if location.empty?

          with_response(URI.join(uri.to_s, location), redirects_left - 1, &block)
        end
      end
    end

    # Talks to the release service: dist-tag resolution, manifest lookup and
    # URL construction. Pure remote reads — no filesystem, no state.
    module Release
      class << self
        # 'stable'/'latest' resolve through their endpoint; a concrete version
        # is format-checked and used as-is.
        def resolve_version(version)
          version = version.to_s.strip
          return resolve_dist_tag(version) if DIST_TAGS.include?(version)
          return version if version.match?(VERSION_PATTERN)

          raise CLIInstallError,
                "Invalid Claude Code CLI version #{version.inspect}: " \
                "expected #{DIST_TAGS.join('/')} or a version like '2.1.220'"
        end

        # The manifest's release info for +platform+: the SHA-256 (required,
        # validated as 64 hex chars) and the declared download size (optional
        # — nil when absent or not a positive Integer, in which case the
        # checksum alone vouches for the download).
        def platform_entry(version, platform)
          url = "#{BASE_URL}/#{version}/manifest.json"
          platforms = parse_manifest(Http.fetch_text(url, limit: MANIFEST_RESPONSE_LIMIT), url)['platforms']
          entry = platforms.is_a?(Hash) ? platforms[platform] : nil
          unless entry.is_a?(Hash)
            available = platforms.is_a?(Hash) ? platforms.keys.sort.join(', ') : 'none'
            raise CLIInstallError, "#{url} has no entry for platform #{platform} (available: #{available})"
          end

          checksum = entry['checksum'].to_s.downcase
          raise CLIInstallError, "#{url} has no valid sha256 checksum for #{platform}" unless checksum.match?(CHECKSUM_PATTERN)

          size = entry['size']
          { checksum: checksum, size: size.is_a?(Integer) && size.positive? ? size : nil }
        end

        def binary_url(version, platform)
          "#{BASE_URL}/#{version}/#{platform}/#{BINARY_NAME}"
        end

        private

        # The dist-tag endpoints return a bare version string. Validate it: an
        # HTML error page or a redirect to a login screen would otherwise be
        # pasted straight into the download URLs.
        def resolve_dist_tag(tag)
          url = "#{BASE_URL}/#{tag}"
          body = Http.fetch_text(url, limit: VERSION_RESPONSE_LIMIT).to_s.strip
          return body if body.match?(VERSION_PATTERN)

          raise CLIInstallError, "#{url} did not return a version string (got #{body[0, 80].inspect})"
        end

        def parse_manifest(body, url)
          manifest = JSON.parse(body.to_s)
          raise CLIInstallError, "#{url} is not a JSON object" unless manifest.is_a?(Hash)

          manifest
        rescue JSON::ParserError => e
          raise CLIInstallError, "#{url} returned malformed JSON: #{e.message}"
        end
      end
    end

    # The VERSION file: line 1 the installed version, line 2 the SHA-256 of the
    # binary that was verified at install time. The checksum is what lets the
    # idempotency shortcut trust the vendored binary without a network call —
    # a truncated, swapped or half-written binary no longer looks installed.
    # An older single-line VERSION file simply reads as "no metadata", which
    # triggers a clean reinstall.
    module Metadata
      class << self
        def read(dir)
          path = File.join(dir, VERSION_FILE)
          return nil unless File.file?(path)

          version, checksum = File.read(path, METADATA_READ_LIMIT).to_s.split("\n", 3)
          version = version.to_s.strip
          checksum = checksum.to_s.strip.downcase
          return nil unless version.match?(VERSION_PATTERN) && checksum.match?(CHECKSUM_PATTERN)

          { version: version, checksum: checksum }
        end

        # Atomic: an unpredictable temp name opened O_EXCL, then renamed over
        # the old file. Without this a reader could observe a half-written
        # VERSION, or (worse) the previous version paired with a new binary.
        def write(dir, version, checksum)
          tmp = File.join(dir, "#{VERSION_FILE}.#{SecureRandom.hex(8)}.tmp")
          begin
            File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
              file.write("#{version}\n#{checksum}\n")
            end
            File.rename(tmp, File.join(dir, VERSION_FILE))
          ensure
            FileUtils.rm_f(tmp)
          end
        end
      end
    end

    class << self
      # Absolute path of the default install directory, resolved against the
      # current working directory each time it is asked for.
      def default_dir
        File.expand_path(DEFAULT_DIR, Dir.pwd)
      end

      # Install the CLI into +dir+ and return the absolute path of the binary.
      # +version+ is 'stable', 'latest', or a concrete version like '2.1.220'.
      #
      # Idempotent and safe to run concurrently: an exclusive lock on
      # dir/.install.lock covers the whole check-download-place-record
      # sequence, so parallel boots (Docker layers, `foreman start`, CI matrix
      # jobs sharing a cache) never race each other into a partially written
      # binary — the loser of the race observes a finished install.
      #
      # The shortcut re-hashes the vendored binary (~0.1s for the real 245MB
      # binary) rather than trusting the recorded version alone, and never
      # touches the network: repeat boots must work offline (with a pinned
      # version — a dist-tag has to be re-resolved to be resolved at all).
      #
      # An upgrade never destroys a working install: see #publish.
      def install(version: 'stable', dir: nil)
        dir = File.expand_path(dir || default_dir)
        # Resolved before the lock: it is a read-only GET, and the format check
        # must reject a bad version before anything is created on disk.
        resolved = Release.resolve_version(version)
        binary = File.join(dir, BINARY_NAME)
        FileUtils.mkdir_p(dir)
        with_install_lock(dir) do
          next binary if installed?(dir, resolved)

          platform = Platform.detect
          publish(dir, binary, resolved, platform, Release.platform_entry(resolved, platform))
          binary
        end
      rescue CLIInstallError
        raise
      rescue SystemCallError, IOError => e
        # Filesystem failures (EACCES on the install dir, ENOSPC mid-download,
        # a read-only mount) reach callers as CLIInstallError like every other
        # install failure; `cause` keeps the original for debugging.
        raise CLIInstallError, "Failed to install the Claude Code CLI into #{dir}: #{e.class}: #{e.message}"
      end

      # Path of an already-installed binary, or nil.
      #
      # Deliberately lock-free, because #publish makes the lock unnecessary
      # for readers: the binary only ever changes by a rename of a
      # fully-downloaded, checksum-verified file, so a concurrent reader (this
      # method, or find_cli, or the CLI being spawned) sees either the intact
      # old binary or the intact new one — never a partial file. Taking the
      # install lock here would put every process start behind an in-progress
      # download for no added safety.
      def installed_path(dir: nil)
        path = File.join(File.expand_path(dir || default_dir), BINARY_NAME)
        File.file?(path) && File.executable?(path) ? path : nil
      rescue SystemCallError
        nil
      end

      private

      # Cross-process mutual exclusion for the whole install. flock is
      # advisory and per open file description, so concurrent threads in one
      # process contend here exactly like separate processes do.
      def with_install_lock(dir)
        flags = File::RDWR | File::CREAT
        # Never follow a symlink planted at the lock path.
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(File.join(dir, LOCK_FILE), flags, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          begin
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end

      # True only when the vendored binary is byte-for-byte the one recorded
      # by a previous install of this exact version. No network access.
      def installed?(dir, version)
        binary = installed_path(dir: dir)
        return false unless binary

        recorded = Metadata.read(dir)
        return false unless recorded && recorded[:version] == version

        Digest::SHA256.file(binary).hexdigest == recorded[:checksum]
      rescue SystemCallError
        false
      end

      # Download, verify, record, then swap the binary in — in that order.
      #
      # The rename is deliberately LAST, because it is the only step with no
      # possible failure after it. That ordering is what keeps a failed
      # upgrade from destroying a working install:
      #
      #   * download/checksum/metadata failure → the old binary and its old
      #     metadata are untouched; the install that was already there keeps
      #     working, and nothing is left behind but the (removed) temp file.
      #   * rename failure or a crash right before it → the old binary is
      #     still intact and runnable; the metadata already names the new
      #     version, whose checksum the old binary cannot match, so the next
      #     install sees "not installed" and redoes it cleanly.
      #
      # (The reverse order — rename then record — briefly published a binary
      # nothing vouched for, and a metadata failure then had to delete the
      # freshly renamed file, taking the previous working install with it.)
      def publish(dir, binary, version, platform, entry)
        tmp = "#{binary}.download.#{SecureRandom.hex(8)}"
        begin
          fetch_verified(version, platform, entry, tmp)
          Metadata.write(dir, version, entry[:checksum])
          File.rename(tmp, binary)
        ensure
          FileUtils.rm_f(tmp)
        end
      end

      # Download to an unpredictable sibling temp name (same filesystem, so the
      # rename is atomic; O_EXCL, so a pre-planted path or symlink cannot be
      # written through), bounded by the manifest's declared size, then verify
      # and chmod. Leaves the file at +tmp+ for #publish to swap in.
      def fetch_verified(version, platform, entry, tmp)
        url = Release.binary_url(version, platform)
        Http.download_to(url, tmp, max_bytes: entry[:size])
        actual = Digest::SHA256.file(tmp).hexdigest
        expected = entry[:checksum]
        raise CLIInstallError, "Checksum mismatch for #{url}: expected #{expected}, got #{actual}" if actual != expected

        File.chmod(0o755, tmp)
      end
    end
  end
end
