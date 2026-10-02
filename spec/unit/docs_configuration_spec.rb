# frozen_string_literal: true

require 'spec_helper'
require 'json'

# docs/configuration.md, "Turning auto-memory off", gives a host two switches
# that keep Claude Code's auto-memory out of its sessions: a variable in `env`
# and a key in `settings`. Either one reaches the CLI only through the
# transport. The default transport applies both itself; a custom transport is
# handed the options and has to pass them on. The page once said that only
# `env` needs passing on and that `settings` travels by itself, so a session
# on a custom transport stayed unisolated without a word of warning.
RSpec.describe 'docs/configuration.md on turning auto-memory off' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:page) { File.read(File.join(root, 'docs/configuration.md')) }
  let(:options_class) { ClaudeAgentSDK::ClaudeAgentOptions }
  let(:switches) { { env: { 'CLAUDE_CODE_DISABLE_AUTO_MEMORY' => '1' }, settings: { autoMemoryEnabled: false } } }

  # A custom transport with the five required methods. It answers control
  # requests and keeps the options the SDK constructed it with.
  let(:transport_class) do
    Class.new do
      class << self
        attr_accessor :options
      end

      def initialize(options, **)
        self.class.options = options
        @frames = Thread::Queue.new
      end

      def connect; end

      def write(data)
        data.each_line do |line|
          frame = JSON.parse(line, symbolize_names: true)
          next unless frame[:type] == 'control_request'

          @frames << { type: 'control_response',
                       response: { subtype: 'success', request_id: frame[:request_id], response: {} } }
        end
      end

      def read_messages
        while (frame = @frames.pop) != :end
          yield frame
        end
      end

      def end_input; end

      def close
        @frames << :end
      end
    end
  end

  # The list items of the section, each on one line. Fenced code is skipped.
  def bullets
    section = page[/^### Turning auto-memory off\n(.*?)^\#{2,3} /m, 1].to_s.gsub(/^```.*?^```\n/m, '')
    section.scan(/^- .*(?:\n {2}\S.*)*/).map { |item| item.gsub(/\s+/, ' ') }
  end

  def command_line(**options)
    ClaudeAgentSDK::CommandBuilder.new('claude', options_class.new(**options)).build
  end

  it 'keeps the default transport and a custom transport apart, and asks the custom one for both switches',
     :aggregate_failures do
    default = bullets.select { |bullet| bullet.include?('`SubprocessCLITransport`') }
    custom = bullets.select { |bullet| bullet.include?('custom transport') }

    expect([default.size, custom.size]).to eq([1, 1])
    expect(default).not_to eq(custom)
    expect(default.first).to include('`env`', '`settings`', '`--settings`')
    expect(custom.first).to include('neither switch reaches that CLI unless the transport passes it through',
                                    '`env`', '`settings`', 'the session is not isolated')
  end

  # What the default transport's half of the page rests on. That the transport
  # puts `env` into the environment of the CLI it starts is pinned by
  # subprocess_cli_transport_spec.rb ("environment variable handling").
  it 'builds settings into the command line as --settings, and nothing for env' do
    with_settings = command_line(settings: switches[:settings])

    expect(with_settings.each_cons(2)).to include(['--settings', '{"autoMemoryEnabled":false}'])
    expect(command_line(env: switches[:env])).to eq(command_line)
  end

  # What the custom transport's half rests on: the SDK constructs the
  # transport with the options and does nothing else with either switch.
  it 'hands a custom transport both switches and applies neither itself' do
    environment = ENV.to_h
    expect(ClaudeAgentSDK::CommandBuilder).not_to receive(:new)

    ClaudeAgentSDK::Client.open(options: options_class.new(**switches), transport_class: transport_class) do |_client|
      nil
    end

    expect(transport_class.options.env).to eq(switches[:env])
    expect(transport_class.options.settings).to eq(switches[:settings])
    expect(ENV.to_h).to eq(environment)
  end
end
