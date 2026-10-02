# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'pp'
require 'uri'

# Options objects and MCP server configs end up in logs, so Type#inspect
# filters every attribute that can carry a credential: env and headers, and
# also settings, extra_args, a stdio server's args, the URL of an HTTP / SSE
# server, the raw Hash server configs inside mcp_servers, and the server
# configs the CLI echoes back in mcp_status. Filtering is for display only:
# nothing sent to the CLI changes.
RSpec.describe 'Type#inspect credential filtering' do
  let(:secret) { 'sk-ant-api03-SECRET0123' }

  # The mcp_status frame CLI 2.1.287 sends for an http, an sse and a stdio
  # server that failed to connect (a handshake without a model turn). Each
  # config comes back with its headers, full url and args; the stdio env is
  # left out. The CLI redacts the url in its own error text only.
  let(:status_frame) do
    {
      mcpServers: [
        {
          name: 'api', status: 'failed',
          error: 'SdkHttpError dialing http://127.0.0.1:9[redacted]?key=REDACTED (CLIENT_HTTP_NOT_IMPLEMENTED)',
          config: {
            type: 'http', url: "http://127.0.0.1:9/mcp?key=#{secret}", headers: { Authorization: "Bearer #{secret}" }
          },
          scope: 'dynamic', source: 'dynamic'
        },
        {
          name: 'events', status: 'failed', error: 'Error dialing http://127.0.0.1:9[redacted]?key=REDACTED',
          config: { type: 'sse', url: "http://127.0.0.1:9/sse?key=#{secret}", headers: { 'X-Api-Key': secret } },
          scope: 'dynamic', source: 'dynamic'
        },
        {
          name: 'fs', status: 'failed', error: 'Connection closed',
          config: { type: 'stdio', command: '/usr/bin/true', args: ['--token', secret] },
          scope: 'dynamic', source: 'dynamic'
        }
      ]
    }
  end

  # url template (%s is the secret) => what #inspect shows for it
  url_rows = {
    'a token in the query string' => ['https://mcp.example.com/v1/mcp?api_key=%s', 'https://mcp.example.com/[FILTERED]'],
    'credentials in the userinfo' => ['https://deploy:%s@mcp.example.com/v1/mcp', 'https://mcp.example.com/[FILTERED]'],
    'an "@" inside the password' => ['https://deploy:p@ss%s@mcp.example.com/', 'https://mcp.example.com/[FILTERED]'],
    'a token in the path' => ['https://mcp.example.com/s/%s/mcp', 'https://mcp.example.com/[FILTERED]'],
    'a token in the fragment' => ['https://mcp.example.com/mcp#%s', 'https://mcp.example.com/[FILTERED]'],
    'a port' => ['http://localhost:8080/sse?token=%s', 'http://localhost:8080/[FILTERED]'],
    'an IPv6 host' => ['https://[::1]:8443/mcp?token=%s', 'https://[::1]:8443/[FILTERED]'],
    'a WebSocket scheme' => ['wss://mcp.example.com/ws?token=%s', 'wss://mcp.example.com/[FILTERED]'],
    'nothing after the host' => ['https://mcp.example.com', 'https://mcp.example.com/[FILTERED]'],
    'no scheme' => ['mcp.example.com/mcp?token=%s', '[FILTERED]'],
    'a scheme other than http(s) or ws(s)' => ['%s://mcp.example.com/mcp', '[FILTERED]'],
    'no host' => ['https://deploy:%s@/mcp', '[FILTERED]'],
    'a port that is not a number' => ['https://mcp.example.com:%s/mcp', '[FILTERED]'],
    'a backslash after the host' => ['https://mcp.example.com\\%s/mcp', '[FILTERED]'],
    'a backslash before an "@"' => ['https://mcp.example.com\\@%s/mcp', '[FILTERED]'],
    'a line break after the host' => ["https://mcp.example.com\n%s/mcp", '[FILTERED]'],
    'a leading space' => [' https://mcp.example.com/mcp?token=%s', '[FILTERED]']
  }.freeze

  describe ClaudeAgentSDK::ClaudeAgentOptions do
    it 'still filters env values and keeps the variable names' do
      rendered = described_class.new(env: { 'ANTHROPIC_API_KEY' => secret }).inspect

      expect(rendered).to include('env={"ANTHROPIC_API_KEY" => "[FILTERED]"}')
      expect(rendered).not_to include('SECRET')
    end

    it 'filters settings given as a JSON String' do
      [{ env: { ANTHROPIC_API_KEY: secret } }, { apiKeyHelper: "echo #{secret}" }].each do |settings|
        rendered = described_class.new(settings: JSON.generate(settings)).inspect

        expect(rendered).to include('settings="[FILTERED]"')
        expect(rendered).not_to include('SECRET')
      end
    end

    it 'filters the values of settings given as a Hash and keeps its keys' do
      settings = { env: { ANTHROPIC_API_KEY: secret }, apiKeyHelper: "echo #{secret}" }
      rendered = described_class.new(settings: settings).inspect

      expect(rendered).to include('settings={env: "[FILTERED]", apiKeyHelper: "[FILTERED]"}')
      expect(rendered).not_to include('SECRET')
    end

    it 'filters a settings file path as well: any String is replaced' do
      rendered = described_class.new(settings: '/etc/claude/settings.json').inspect

      expect(rendered).to include('settings="[FILTERED]"')
      expect(rendered).not_to include('/etc/claude')
    end

    it 'filters extra_args values and keeps the flag names' do
      rendered = described_class.new(extra_args: { 'api-key' => secret, 'debug-to-stderr' => nil }).inspect

      expect(rendered).to include('extra_args={"api-key" => "[FILTERED]", "debug-to-stderr" => "[FILTERED]"}')
      expect(rendered).not_to include('SECRET')
    end

    it 'leaves the empty defaults as they are' do
      rendered = described_class.new.inspect

      expect(rendered).to include(' env={}').and include(' extra_args={}').and include(' mcp_servers={}')
      expect(rendered).not_to include('settings=')
    end

    it 'filters mcp_servers given as a String: the JSON of a config, or the path to one' do
      json = JSON.generate(mcpServers: { gh: { command: 'npx', env: { TOKEN: secret } } })

      [json, '/etc/claude/mcp.json'].each do |mcp_servers|
        rendered = described_class.new(mcp_servers: mcp_servers).inspect

        expect(rendered).to include(' mcp_servers="[FILTERED]"')
        expect(rendered).not_to include('SECRET')
        expect(rendered).not_to include('/etc/claude')
      end
    end

    describe 'raw Hash server configs in mcp_servers' do
      it 'shows type and command of a stdio config and filters args and env' do
        options = described_class.new(
          mcp_servers: {
            github: {
              type: 'stdio', command: 'npx',
              args: ['-y', '@modelcontextprotocol/server-github', '--token', secret],
              env: { 'GITHUB_PERSONAL_ACCESS_TOKEN' => secret }
            }
          }
        )

        expect(options.inspect)
          .to include('mcp_servers={github: {type: "stdio", command: "npx", args: "[FILTERED]", env: "[FILTERED]"}}')
        expect(options.inspect).not_to include('SECRET')
      end

      it 'shows type and host of an http config and filters headers' do
        options = described_class.new(
          mcp_servers: {
            api: {
              type: 'http', url: "https://mcp.example.com/v1/mcp?api_key=#{secret}",
              headers: { 'Authorization' => "Bearer #{secret}" }
            }
          }
        )

        expect(options.inspect).to include(
          'mcp_servers={api: {type: "http", url: "https://mcp.example.com/[FILTERED]", headers: "[FILTERED]"}}'
        )
        expect(options.inspect).not_to include('SECRET')
      end

      # A String is printed at any nesting depth, so this one was never
      # covered by the nesting limit that happened to hide env and headers.
      it 'filters a key it does not know, whatever the value' do
        options = described_class.new(
          mcp_servers: {
            api: {
              type: 'sse', url: 'https://mcp.example.com/sse',
              headersHelper: "/usr/local/bin/mcp-headers --token #{secret}", oauth: { clientSecret: secret }
            }
          }
        )

        expect(options.inspect).to include(
          'mcp_servers={api: {type: "sse", url: "https://mcp.example.com/[FILTERED]", ' \
          'headersHelper: "[FILTERED]", oauth: "[FILTERED]"}}'
        )
        expect(options.inspect).not_to include('SECRET')
      end

      it 'reads a String-keyed config the same way' do
        options = described_class.new(
          mcp_servers: {
            'api' => {
              'type' => 'http', 'url' => "https://mcp.example.com/mcp?key=#{secret}",
              'headers' => { 'Authorization' => "Bearer #{secret}" }
            }
          }
        )

        expect(options.inspect).to include(
          'mcp_servers={"api" => {"type" => "http", "url" => "https://mcp.example.com/[FILTERED]", ' \
          '"headers" => "[FILTERED]"}}'
        )
        expect(options.inspect).not_to include('SECRET')
      end

      it 'keeps showing an SDK server config: type, name and instance' do
        server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'calc', tools: [])
        rendered = described_class.new(mcp_servers: { calc: server }).inspect

        expect(rendered)
          .to include('mcp_servers={calc: {type: "sdk", name: "calc", instance: #<ClaudeAgentSDK::SdkMcpServer>}}')
      end

      it 'leaves a typed config to its own filtering' do
        config = ClaudeAgentSDK::McpStdioServerConfig.new(
          command: 'mcp-files', args: ["--token=#{secret}"], env: { 'TOKEN' => secret }
        )
        rendered = described_class.new(mcp_servers: { files: config }).inspect

        expect(rendered).to include('mcp_servers={files: #<ClaudeAgentSDK::McpStdioServerConfig command="mcp-files" ' \
                                    'args="[FILTERED]" env={…(1)} type="stdio">}')
        expect(rendered).not_to include('SECRET')
      end

      url_rows.each do |label, (template, shown)|
        it "shows scheme and host of a url with #{label}" do
          url = format(template, secret)
          rendered = described_class.new(mcp_servers: { api: { type: 'http', url: url } }).inspect

          expect(rendered).to include(%(mcp_servers={api: {type: "http", url: "#{shown}"}}))
          expect(rendered).not_to include('SECRET')
        end
      end
    end

    it 'filters the same way through #to_s, interpolation and pp' do
      options = described_class.new(
        settings: { apiKeyHelper: "echo #{secret}" }, extra_args: { 'api-key' => secret },
        mcp_servers: { api: { type: 'http', url: "https://mcp.example.com/mcp?key=#{secret}" } }
      )

      [options.to_s, "#{options}", PP.pp(options, +'')].each do |rendered| # rubocop:disable Style/RedundantInterpolation
        expect(rendered).to include('settings={apiKeyHelper: "[FILTERED]"}')
        expect(rendered).not_to include('SECRET')
      end
    end
  end

  describe ClaudeAgentSDK::McpStdioServerConfig do
    it 'filters args, which carry flags such as --api-key' do
      config = described_class.new(command: 'npx', args: ['-y', 'mcp-remote', "--api-key=#{secret}"])

      expect(config.inspect).to eq('#<ClaudeAgentSDK::McpStdioServerConfig command="npx" args="[FILTERED]" type="stdio">')
    end

    it 'still filters env values and keeps the variable names' do
      config = described_class.new(command: 'npx', env: { 'GITHUB_PERSONAL_ACCESS_TOKEN' => secret })

      expect(config.inspect).to eq('#<ClaudeAgentSDK::McpStdioServerConfig command="npx" ' \
                                   'env={"GITHUB_PERSONAL_ACCESS_TOKEN" => "[FILTERED]"} type="stdio">')
    end
  end

  [ClaudeAgentSDK::McpHttpServerConfig, ClaudeAgentSDK::McpSSEServerConfig].each do |klass|
    describe klass do
      let(:type) { klass.new.type }

      it 'still filters header values and keeps the header names' do
        config = klass.new(url: 'https://mcp.example.com/mcp', headers: { 'Authorization' => "Bearer #{secret}" })

        expect(config.inspect).to eq(%(#<#{klass.name} url="https://mcp.example.com/[FILTERED]" ) +
                                     %(headers={"Authorization" => "[FILTERED]"} type="#{type}">))
      end

      url_rows.each do |label, (template, shown)|
        it "shows scheme and host of a url with #{label}" do
          config = klass.new(url: format(template, secret))

          expect(config.inspect).to eq(%(#<#{klass.name} url="#{shown}" type="#{type}">))
        end
      end

      it 'filters a url that is not a String', rbs_incompatible: 'plants a URI where the signature says String' do
        config = klass.new(url: URI("https://mcp.example.com/mcp?key=#{secret}"))

        expect(config.inspect).to eq(%(#<#{klass.name} url="[FILTERED]" type="#{type}">))
      end
    end
  end

  # McpStatusResponse.parse(client.mcp_status) is the typed view of that
  # frame: printing one of its servers must not print what its config holds.
  describe ClaudeAgentSDK::McpServerStatus do
    let(:servers) { ClaudeAgentSDK::McpStatusResponse.parse(status_frame).mcp_servers }

    it 'shows type and host of an echoed http config and filters headers' do
      expect(servers[0].inspect).to eq(
        '#<ClaudeAgentSDK::McpServerStatus name="api" status="failed" ' \
        'error="SdkHttpError dialing http://127.0.0.1:9[redacted]?key=REDACTED (CLIENT_HTTP_NOT_"…(+12 chars) ' \
        'config={type: "http", url: "http://127.0.0.1:9/[FILTERED]", headers: "[FILTERED]"} scope="dynamic">'
      )
    end

    it 'shows type and host of an echoed sse config and filters headers' do
      expect(servers[1].inspect).to eq(
        '#<ClaudeAgentSDK::McpServerStatus name="events" status="failed" ' \
        'error="Error dialing http://127.0.0.1:9[redacted]?key=REDACTED" ' \
        'config={type: "sse", url: "http://127.0.0.1:9/[FILTERED]", headers: "[FILTERED]"} scope="dynamic">'
      )
    end

    it 'shows type and command of an echoed stdio config and filters args' do
      expect(servers[2].inspect).to eq(
        '#<ClaudeAgentSDK::McpServerStatus name="fs" status="failed" error="Connection closed" ' \
        'config={type: "stdio", command: "/usr/bin/true", args: "[FILTERED]"} scope="dynamic">'
      )
    end

    it 'filters the same way through #to_s, interpolation and pp' do
      servers.each do |server|
        [server.to_s, "#{server}", PP.pp(server, +'')].each do |rendered| # rubocop:disable Style/RedundantInterpolation
          expect(rendered).to include('[FILTERED]')
          expect(rendered).not_to include('SECRET')
        end
      end
    end

    it 'still collapses the configs inside a McpStatusResponse' do
      rendered = ClaudeAgentSDK::McpStatusResponse.parse(status_frame).inspect

      expect(rendered.scan('config={…(3)}').size).to eq(3)
      expect(rendered).not_to include('SECRET')
    end
  end

  # What the CLI receives is built from the attributes and #to_h, never from
  # #inspect: the filters above change no byte of it.
  describe 'the wire form' do
    let(:stdio) do
      ClaudeAgentSDK::McpStdioServerConfig.new(command: 'mcp-files', args: ["--token=#{secret}"],
                                               env: { 'TOKEN' => secret })
    end
    let(:sse) do
      ClaudeAgentSDK::McpSSEServerConfig.new(url: "https://deploy:#{secret}@sse.example.com/events",
                                             headers: { 'X-Api-Key' => secret })
    end
    let(:http) do
      ClaudeAgentSDK::McpHttpServerConfig.new(url: "https://mcp.example.com/s/#{secret}/mcp",
                                              headers: { 'Authorization' => "Bearer #{secret}" })
    end
    let(:options) do
      ClaudeAgentSDK::ClaudeAgentOptions.new(
        env: { 'ANTHROPIC_API_KEY' => secret },
        settings: { env: { ANTHROPIC_API_KEY: secret }, apiKeyHelper: "echo #{secret}" },
        extra_args: { 'api-key' => secret, 'debug-to-stderr' => nil },
        mcp_servers: {
          github: {
            type: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-github', '--token', secret],
            env: { 'GITHUB_PERSONAL_ACCESS_TOKEN' => secret }
          },
          api: {
            type: 'http', url: "https://mcp.example.com/v1/mcp?api_key=#{secret}",
            headers: { 'Authorization' => "Bearer #{secret}" }
          },
          files: stdio, events: sse, docs: http
        }
      )
    end

    def command_line(options)
      ClaudeAgentSDK::CommandBuilder.new('claude', options).build
    end

    it 'builds the same command line before and after #inspect, credentials included' do
      before = command_line(options)
      options.inspect
      options.to_s
      argv = command_line(options)

      expect(argv).to eq(before)
      expect(argv[argv.index('--settings') + 1])
        .to eq(%({"env":{"ANTHROPIC_API_KEY":"#{secret}"},"apiKeyHelper":"echo #{secret}"}))
      expect(argv[argv.index('--mcp-config') + 1]).to eq(
        [
          '{"mcpServers":{',
          '"github":{"type":"stdio","command":"npx",',
          %("args":["-y","@modelcontextprotocol/server-github","--token","#{secret}"],),
          %("env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"#{secret}"}},),
          %("api":{"type":"http","url":"https://mcp.example.com/v1/mcp?api_key=#{secret}",),
          %("headers":{"Authorization":"Bearer #{secret}"}},),
          %("files":{"type":"stdio","command":"mcp-files","args":["--token=#{secret}"],"env":{"TOKEN":"#{secret}"}},),
          %("events":{"type":"sse","url":"https://deploy:#{secret}@sse.example.com/events",),
          %("headers":{"X-Api-Key":"#{secret}"}},),
          %("docs":{"type":"http","url":"https://mcp.example.com/s/#{secret}/mcp",),
          %("headers":{"Authorization":"Bearer #{secret}"}}}})
        ].join
      )
      expect(argv.each_cons(2)).to include(['--api-key', secret])
      expect(argv).to include('--debug-to-stderr')
    end

    it 'leaves every #to_h and every attribute as it was' do
      [options, stdio, sse, http].each(&:inspect)

      expect(stdio.to_h).to eq(type: 'stdio', command: 'mcp-files', args: ["--token=#{secret}"],
                               env: { 'TOKEN' => secret })
      expect(sse.to_h).to eq(type: 'sse', url: "https://deploy:#{secret}@sse.example.com/events",
                             headers: { 'X-Api-Key' => secret })
      expect(http.to_h).to eq(type: 'http', url: "https://mcp.example.com/s/#{secret}/mcp",
                              headers: { 'Authorization' => "Bearer #{secret}" })
      expect(options.env).to eq('ANTHROPIC_API_KEY' => secret)
      expect(options.settings).to eq(env: { ANTHROPIC_API_KEY: secret }, apiKeyHelper: "echo #{secret}")
      expect(options.extra_args).to eq('api-key' => secret, 'debug-to-stderr' => nil)
      expect(options.mcp_servers[:api]).to eq(type: 'http', url: "https://mcp.example.com/v1/mcp?api_key=#{secret}",
                                              headers: { 'Authorization' => "Bearer #{secret}" })
      expect(options.mcp_servers[:github][:env]).to eq('GITHUB_PERSONAL_ACCESS_TOKEN' => secret)
    end

    it 'passes mcp_servers given as a String to --mcp-config as it is' do
      json = JSON.generate(mcpServers: { gh: { command: 'npx', env: { TOKEN: secret } } })
      string_options = ClaudeAgentSDK::ClaudeAgentOptions.new(mcp_servers: json)
      before = command_line(string_options)
      string_options.inspect
      string_options.to_s

      expect(command_line(string_options)).to eq(before)
      expect(before.each_cons(2))
        .to include(['--mcp-config', %({"mcpServers":{"gh":{"command":"npx","env":{"TOKEN":"#{secret}"}}}})])
      expect(string_options.mcp_servers).to equal(json)
    end

    # A parsed mcp_status frame is never sent anywhere; what must not change
    # is what the application reads from it.
    it 'leaves the configs of a parsed mcp_status frame as the CLI sent them' do
      response = ClaudeAgentSDK::McpStatusResponse.parse(status_frame)
      response.inspect
      response.mcp_servers.each(&:inspect)

      expect(response.mcp_servers.map(&:config)).to eq(
        [
          { type: 'http', url: "http://127.0.0.1:9/mcp?key=#{secret}", headers: { Authorization: "Bearer #{secret}" } },
          { type: 'sse', url: "http://127.0.0.1:9/sse?key=#{secret}", headers: { 'X-Api-Key': secret } },
          { type: 'stdio', command: '/usr/bin/true', args: ['--token', secret] }
        ]
      )
      expect(response.mcp_servers.first.config).to equal(status_frame[:mcpServers].first[:config])
    end
  end
end
