# frozen_string_literal: true

require 'spec_helper'
require 'net/http'
require 'stringio'

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
end
