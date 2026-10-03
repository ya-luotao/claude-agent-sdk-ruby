# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

# The `sandbox:` option is folded into the --settings value so that it can
# override a sandbox section the settings already carry (`sandbox: false`
# against settings that enable it). Settings read from JSON (a JSON String, a
# settings file, a Hash from JSON.parse) spell that section with a String
# key; the option was stored under a Symbol key next to it, so the generated
# JSON had the key twice. json 2.x emits both, and the override only works as
# long as the CLI's parser keeps the last one; json 3.x raises
# JSON::GeneratorError out of connect. The examples count the key in the
# argument text, so they fail on either json major.
RSpec.describe ClaudeAgentSDK::CommandBuilder do
  settings_document = {
    'permissions' => { 'deny' => ['WebFetch'] },
    'sandbox' => { 'enabled' => true, 'network' => { 'allowedDomains' => ['example.com'] } }
  }.freeze

  # The forms `settings:` may take, each yielding one that carries the
  # document above.
  settings_sources = {
    'a JSON String' => ->(&use) { use.call(JSON.generate(settings_document)) },
    'a String-keyed Hash' => ->(&use) { use.call(JSON.parse(JSON.generate(settings_document))) },
    'a Symbol-keyed Hash' => ->(&use) { use.call(JSON.parse(JSON.generate(settings_document), symbolize_names: true)) },
    'a Hash with the section under both key types' => lambda { |&use|
      use.call(JSON.parse(JSON.generate(settings_document)).merge(sandbox: { enabled: true }))
    },
    'the path of a settings file' => lambda { |&use|
      Dir.mktmpdir('settings-sandbox') do |dir|
        path = File.join(dir, 'settings.json')
        File.write(path, JSON.generate(settings_document))
        use.call(path)
      end
    }
  }.freeze

  # A value of the `sandbox:` option, and the section the CLI must receive.
  sandbox_options = {
    'false' => [false, false],
    'a Hash' => [{ enabled: false }, { 'enabled' => false }],
    'a SandboxSettings' => [
      ClaudeAgentSDK::SandboxSettings.new(enabled: true, excluded_commands: ['git']),
      { 'enabled' => true, 'excludedCommands' => ['git'] }
    ]
  }.freeze

  # The --settings argument built for these options.
  def settings_argument(**options)
    cmd = described_class.new('/usr/bin/claude', ClaudeAgentSDK::ClaudeAgentOptions.new(**options)).build
    cmd[cmd.index('--settings') + 1]
  end

  settings_sources.each do |source, with_settings|
    sandbox_options.each do |option, (sandbox, section)|
      it "writes the sandbox key once for settings given as #{source} and sandbox: #{option}" do
        with_settings.call do |settings|
          argument = settings_argument(settings: settings, sandbox: sandbox)

          expect(argument.scan('"sandbox"').size).to eq(1)
          expect(JSON.parse(argument)).to eq('permissions' => { 'deny' => ['WebFetch'] }, 'sandbox' => section)
        end
      end
    end
  end

  it 'leaves the settings Hash the caller passed untouched' do
    settings = JSON.parse(JSON.generate(settings_document))

    settings_argument(settings: settings, sandbox: false)

    expect(settings).to eq(settings_document)
  end

  it 'keeps the sandbox section of the settings when the sandbox option is not set' do
    argument = settings_argument(settings: JSON.parse(JSON.generate(settings_document)))

    expect(JSON.parse(argument)).to eq(settings_document)
  end
end
