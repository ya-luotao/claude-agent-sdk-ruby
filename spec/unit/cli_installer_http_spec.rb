# frozen_string_literal: true

require 'spec_helper'
require 'net/http'
require 'stringio'
require 'tmpdir'

# CLIInstaller::Http itself. The other installer specs replace
# Http.fetch_text / Http.download_to wholesale; here the only seam is
# Net::HTTP.start, so everything above the socket is the real code: proxy
# resolution, the HTTPS-only check, redirects, status handling and body
# streaming. Responses are real Net::HTTPResponse objects, parsed from the raw
# bytes a server would send — stdlib only, no HTTP stubbing library.
RSpec.describe ClaudeAgentSDK::CLIInstaller::Http do
  proxy_variables = %w[http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY].freeze

  # The proxy settings of whoever runs the suite must not leak into an
  # example, and what an example sets must not leak out.
  around do |example|
    saved = proxy_variables.to_h { |name| [name, ENV.fetch(name, nil)] }
    proxy_variables.each { |name| ENV.delete(name) }
    example.run
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  # One entry per Net::HTTP.start call, in order: where it connected, the
  # explicit proxy arguments (none = Net::HTTP's own environment lookup), the
  # session options, and the request sent over it.
  let(:connections) { [] }

  def raw_response(status, headers = {}, body = '')
    head = { 'Content-Length' => body.bytesize }.merge(headers).map { |name, value| "#{name}: #{value}\r\n" }.join
    "HTTP/1.1 #{status}\r\n#{head}\r\n#{body}"
  end

  # Answers the n-th connection with the n-th raw response, read the way
  # Net::HTTP#transport_request reads one off the socket.
  def stub_connections(*raw_responses)
    allow(Net::HTTP).to receive(:start) do |address, port, *proxy, **options, &session|
      raw = raw_responses.shift or raise "unexpected connection to #{address}"
      connection = { address: address, port: port, proxy: proxy, options: options }
      connections << connection
      session.call(connection_answering(raw, connection))
    end
  end

  def connection_answering(raw, connection)
    http = Object.new
    http.define_singleton_method(:request) do |request, &handler|
      connection[:request] = request
      socket = Net::BufferedIO.new(StringIO.new(raw))
      response = Net::HTTPResponse.read_new(socket)
      response.decode_content = request.decode_content
      response.reading_body(socket, request.response_body_permitted?) { handler.call(response) }
    end
    http
  end

  describe 'proxy selection' do
    # TEST-NET-1 literals: URI#find_proxy resolves the host before applying
    # no_proxy, and a literal resolves without DNS. (Not a loopback address —
    # find_proxy never proxies those.)
    let(:url) { 'https://192.0.2.1/claude-code-releases/stable' }
    let(:version_response) { raw_response('200 OK', { 'Content-Type' => 'text/plain' }, "2.1.285\n") }

    def proxy_used_for(url)
      stub_connections(version_response)
      expect(described_class.fetch_text(url, limit: 1024)).to eq("2.1.285\n")
      connections.last[:proxy]
    end

    it 'connects through the proxy HTTPS_PROXY names' do
      ENV['HTTPS_PROXY'] = 'http://proxy.corp.example:3128'

      expect(proxy_used_for(url)).to eq(['proxy.corp.example', 3128, nil, nil])
      expect(connections.last).to include(address: '192.0.2.1', port: 443)
    end

    it 'reads the lowercase https_proxy too' do
      ENV['https_proxy'] = 'http://proxy.corp.example:3128'

      expect(proxy_used_for(url)).to eq(['proxy.corp.example', 3128, nil, nil])
    end

    it 'passes the proxy credentials, percent-decoded' do
      ENV['HTTPS_PROXY'] = 'http://alice:p%40ss%3Aword@proxy.corp.example:3128'

      expect(proxy_used_for(url)).to eq(['proxy.corp.example', 3128, 'alice', 'p@ss:word'])
    end

    it 'unbrackets an IPv6 proxy address and defaults the port' do
      ENV['HTTPS_PROXY'] = 'http://[2001:db8::10]'

      expect(proxy_used_for(url)).to eq(['2001:db8::10', 80, nil, nil])
    end

    it 'passes no proxy when NO_PROXY lists the host' do
      ENV['HTTPS_PROXY'] = 'http://proxy.corp.example:3128'
      ENV['NO_PROXY'] = 'localhost,192.0.2.1'

      expect(proxy_used_for(url)).to eq([])
    end

    it 'passes no proxy when nothing is set' do
      expect(proxy_used_for(url)).to eq([])
    end

    it 'leaves an environment that only sets http_proxy to Net::HTTP, as before' do
      # No explicit arguments: Net::HTTP's own lookup reads http_proxy, which
      # is how the installer reached a proxy before it read HTTPS_PROXY.
      ENV['http_proxy'] = 'http://proxy.corp.example:3128'

      expect(proxy_used_for(url)).to eq([])
    end

    it 'does not consult ALL_PROXY' do
      ENV['ALL_PROXY'] = 'http://proxy.corp.example:3128'

      expect(proxy_used_for(url)).to eq([])
    end

    it 'resolves the proxy again for every redirect hop' do
      ENV['HTTPS_PROXY'] = 'http://proxy.corp.example:3128'
      ENV['NO_PROXY'] = '192.0.2.99'
      stub_connections(raw_response('302 Found', { 'Location' => 'https://192.0.2.99/claude' }),
                       raw_response('200 OK', {}, 'binary'))

      expect(described_class.fetch_text(url, limit: 1024)).to eq('binary')
      expect(connections.map { |c| [c[:address], c[:proxy]] })
        .to eq([['192.0.2.1', ['proxy.corp.example', 3128, nil, nil]], ['192.0.2.99', []]])
    end

    # Values that were ignored while the installer did not read HTTPS_PROXY at
    # all, and that Net::HTTP could not use as an HTTP proxy anyway. Passing
    # them on would turn a download that works directly into a failure.
    ['proxy.corp.example:3128', '127.0.0.1:3128', 'socks5://127.0.0.1:1080',
     'https://proxy.corp.example', 'http://proxy with spaces:3128', 'http://:3128'].each do |value|
      it "still ignores HTTPS_PROXY=#{value}, which is not an http:// proxy URL" do
        ENV['HTTPS_PROXY'] = value

        expect(proxy_used_for(url)).to eq([])
      end
    end
  end

  # With no proxy variable set, find_proxy answers before resolving anything,
  # so these can name the real release host.
  let(:release_url) { 'https://downloads.claude.ai/claude-code-releases/2.1.285/darwin-arm64/claude' }

  def redirect_to(location, body = '')
    raw_response('302 Found', { 'Location' => location }, body)
  end

  describe 'the HTTPS-only rule' do
    it 'refuses an http:// URL before opening any connection' do
      expect(Net::HTTP).not_to receive(:start)

      expect { described_class.fetch_text('http://downloads.claude.ai/claude-code-releases/stable', limit: 1024) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError,
                        'Refusing to fetch non-HTTPS URL: http://downloads.claude.ai/claude-code-releases/stable')
    end

    it 'refuses a redirect from https to http without following it' do
      stub_connections(redirect_to('http://mirror.example/claude'), raw_response('200 OK', {}, 'plaintext'))

      expect { described_class.fetch_text(release_url, limit: 1024) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, 'Refusing to fetch non-HTTPS URL: http://mirror.example/claude')
      expect(connections.map { |c| c[:address] }).to eq(['downloads.claude.ai'])
    end

    it 'opens every connection with TLS and peer verification, on the first hop and after a redirect' do
      # use_ssl: true is what puts TLS on the wire: Net::HTTP would speak TLS
      # to the host of an http:// URL too. The scheme check above keeps
      # HTTP-shaped URLs out; it is not what encrypts the transfer.
      stub_connections(redirect_to('https://cdn.example/claude'), raw_response('200 OK', {}, 'binary'))

      described_class.fetch_text(release_url, limit: 1024)

      expect(connections.map { |c| [c[:address], c[:port]] }).to eq([['downloads.claude.ai', 443], ['cdn.example', 443]])
      expect(connections.map { |c| c[:options] }).to all(
        eq(use_ssl: true, open_timeout: described_class::OPEN_TIMEOUT_SECONDS,
           read_timeout: described_class::READ_TIMEOUT_SECONDS)
      )
    end
  end

  describe 'redirects' do
    it 'sends a GET for the URL and returns what the block makes of the response' do
      stub_connections(raw_response('200 OK', { 'Content-Type' => 'text/plain' }, "2.1.285\n"))

      expect(described_class.fetch_text('https://downloads.claude.ai/claude-code-releases/stable', limit: 1024))
        .to eq("2.1.285\n")
      request = connections.first[:request]
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq('/claude-code-releases/stable')
      expect(request['host']).to eq('downloads.claude.ai')
    end

    it 'follows up to five redirects' do
      hops = (1..5).map { |n| redirect_to("https://hop#{n}.example/claude") }
      stub_connections(*hops, raw_response('200 OK', {}, 'binary'))

      expect(described_class.fetch_text(release_url, limit: 1024)).to eq('binary')
      expect(connections.map { |c| c[:address] })
        .to eq(%w[downloads.claude.ai hop1.example hop2.example hop3.example hop4.example hop5.example])
    end

    it 'raises "Too many redirects" on the sixth, after exactly six requests' do
      hops = (1..8).map { |n| redirect_to("https://hop#{n}.example/claude") }
      stub_connections(*hops)

      expect { described_class.fetch_text(release_url, limit: 1024) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError,
                        'Too many redirects while fetching https://hop5.example/claude')
      expect(connections.size).to eq(6)
    end

    it 'resolves a relative Location against the URL that sent it' do
      stub_connections(redirect_to('/mirror/2.1.285/claude'), raw_response('200 OK', {}, 'binary'))

      described_class.fetch_text(release_url, limit: 1024)

      expect(connections.last[:address]).to eq('downloads.claude.ai')
      expect(connections.last[:request].path).to eq('/mirror/2.1.285/claude')
    end

    it 'raises on a redirect without a Location header' do
      stub_connections(raw_response('302 Found'))

      expect { described_class.fetch_text(release_url, limit: 1024) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, "Redirect from #{release_url} is missing a Location header")
    end
  end

  describe 'failures' do
    it 'raises with the status line of a 404' do
      stub_connections(raw_response('404 Not Found', { 'Content-Type' => 'application/xml' }, '<Error>NoSuchKey</Error>'))

      expect { described_class.fetch_text(release_url, limit: 1024) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, "HTTP 404 Not Found for #{release_url}")
    end

    it 'wraps a SocketError in CLIInstallError, keeping it as the cause' do
      allow(Net::HTTP).to receive(:start).and_raise(
        SocketError, 'getaddrinfo: nodename nor servname provided, or not known'
      )

      expect { described_class.fetch_text(release_url, limit: 1024) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError) { |error|
          expect(error.message).to eq(
            "Failed to fetch #{release_url}: SocketError: getaddrinfo: nodename nor servname provided, or not known"
          )
          expect(error.cause).to be_a(SocketError)
        }
    end

    it 'lets a CLIInstallError from the body handler through unwrapped' do
      stub_connections(raw_response('200 OK', {}, 'x' * 2048))

      expect { described_class.fetch_text(release_url, limit: 1024) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, "Response from #{release_url} exceeds the 1024-byte limit")
    end
  end

  describe 'what reaches the target file' do
    around do |example|
      Dir.mktmpdir('cli-installer-http') do |dir|
        @target = File.join(dir, 'claude.download.0123456789abcdef')
        example.run
      end
    end

    let(:target) { @target }

    it 'streams only the final 200 body, never a redirect body' do
      chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" \
                "6\r\nbinary\r\n7\r\n-bytes!\r\n0\r\n\r\n"
      stub_connections(redirect_to('https://cdn.example/claude', '<html>Moved</html>'), chunked)

      expect(described_class.download_to(release_url, target, max_bytes: 13)).to eq(target)
      expect(File.binread(target)).to eq('binary-bytes!')
    end

    it 'creates no file for an error page' do
      stub_connections(raw_response('503 Service Unavailable', {}, '<html>Try again later</html>'))

      expect { described_class.download_to(release_url, target) }
        .to raise_error(ClaudeAgentSDK::CLIInstallError, "HTTP 503 Service Unavailable for #{release_url}")
      expect(File.exist?(target)).to be false
    end
  end
end
