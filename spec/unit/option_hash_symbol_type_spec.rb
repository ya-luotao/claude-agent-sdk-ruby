# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'json'

# system_prompt, tools and output_format take a Hash tagged with a `type`.
# The tag was compared with String literals, so the Ruby spelling
# `type: :preset` matched no branch:
#
#   tools: { type: :preset, preset: :claude_code }       sent the Hash's JSON
#                                                        text as a tool NAME,
#                                                        so the session had no
#                                                        tools at all
#   system_prompt: { type: :custom, prompt: '...' }      sent no flag: the
#                                                        prompt was dropped
#   output_format: { type: :json_schema, schema: ... }   sent the wrapper as
#                                                        the schema, which the
#                                                        CLI rejects
#
# and a Hash with `type` under one key style and `schema` under the other
# turned structured output off. The same Hashes with a String tag worked, and
# other options (thinking, MCP server configs) already took a Symbol tag.
RSpec.describe 'an option Hash tagged with a Symbol type' do
  # The command line built for these options.
  def argv(**options)
    ClaudeAgentSDK::CommandBuilder.new('/usr/bin/claude', ClaudeAgentSDK::ClaudeAgentOptions.new(**options)).build
  end

  # The value that follows +flag+ on that command line (nil without the flag).
  def flag_value(cmd, flag)
    index = cmd.index(flag)
    index && cmd[index + 1]
  end

  schema = {
    type: 'object',
    properties: {
      verdict: { type: 'string', enum: %w[approve reject] },
      reasons: { type: 'array', items: { type: 'string' } }
    },
    required: ['verdict']
  }.freeze

  # option => { form => [the Hash with a String tag, the same Hash in other spellings] }
  forms = {
    system_prompt: {
      'a custom prompt' => [
        { type: 'custom', prompt: 'You are a terse reviewer.' },
        {
          'a Symbol type' => { type: :custom, prompt: 'You are a terse reviewer.' },
          'a Symbol type under String keys' => { 'type' => :custom, 'prompt' => 'You are a terse reviewer.' }
        }
      ],
      'a prompt file' => [
        { type: 'file', path: 'prompts/reviewer.md' },
        {
          'a Symbol type' => { type: :file, path: 'prompts/reviewer.md' },
          'a Symbol type under String keys' => { 'type' => :file, 'path' => 'prompts/reviewer.md' }
        }
      ],
      'the preset with an appended prompt' => [
        { type: 'preset', preset: 'claude_code', append: 'Answer in one paragraph.' },
        {
          'a Symbol type and preset' => { type: :preset, preset: :claude_code, append: 'Answer in one paragraph.' },
          'a Symbol type and preset under String keys' => {
            'type' => :preset, 'preset' => :claude_code, 'append' => 'Answer in one paragraph.'
          }
        }
      ]
    },
    tools: {
      'the preset' => [
        { type: 'preset', preset: 'claude_code' },
        {
          'a Symbol type and preset' => { type: :preset, preset: :claude_code },
          'a Symbol type and preset under String keys' => { 'type' => :preset, 'preset' => :claude_code }
        }
      ]
    },
    output_format: {
      'a JSON schema' => [
        { type: 'json_schema', schema: schema },
        {
          'a Symbol type' => { type: :json_schema, schema: schema },
          'a Symbol type under String keys' => { 'type' => :json_schema, 'schema' => schema },
          'a String-keyed type and a Symbol-keyed schema' => { 'type' => 'json_schema', schema: schema },
          'a Symbol-keyed type and a String-keyed schema' => { type: 'json_schema', 'schema' => schema },
          'a Symbol type and a String-keyed schema' => { type: :json_schema, 'schema' => schema }
        }
      ]
    }
  }.freeze

  describe 'the command line' do
    it 'carries the custom prompt, the prompt file, the appended prompt, the tools preset and the schema ' \
       'for a String type' do
      custom, file, preset = forms.fetch(:system_prompt).values.map(&:first)
      tools = forms.dig(:tools, 'the preset').first
      output_format = forms.dig(:output_format, 'a JSON schema').first

      expect(flag_value(argv(system_prompt: custom), '--system-prompt')).to eq('You are a terse reviewer.')
      expect(flag_value(argv(system_prompt: file), '--system-prompt-file')).to eq('prompts/reviewer.md')
      expect(flag_value(argv(system_prompt: preset), '--append-system-prompt')).to eq('Answer in one paragraph.')
      expect(argv(system_prompt: preset)).not_to include('--system-prompt')
      expect(flag_value(argv(tools: tools), '--tools')).to eq('default')
      expect(JSON.parse(flag_value(argv(output_format: output_format), '--json-schema'))).to eq(JSON.parse(JSON.generate(schema)))
    end

    forms.each do |option, by_form|
      by_form.each do |form, (string_typed, spellings)|
        spellings.each do |spelling, hash|
          it "is the same for #{option} given as #{form} with #{spelling}" do
            expect(argv(option => hash)).to eq(argv(option => string_typed))
          end
        end
      end
    end

    it 'is the one the typed classes build' do
      typed = {
        system_prompt: [
          ClaudeAgentSDK::SystemPromptCustom.new(prompt: 'You are a terse reviewer.'),
          ClaudeAgentSDK::SystemPromptFile.new(path: 'prompts/reviewer.md'),
          ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', append: 'Answer in one paragraph.')
        ],
        tools: [ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code')]
      }
      symbol_typed = {
        system_prompt: forms.fetch(:system_prompt).values.map { |(_string_typed, spellings)| spellings.values.first },
        tools: [forms.dig(:tools, 'the preset').last.values.first]
      }

      built = symbol_typed.to_h { |option, hashes| [option, hashes.map { |hash| argv(option => hash) }] }

      expect(built).to eq(typed.to_h { |option, values| [option, values.map { |value| argv(option => value) }] })
    end

    # A custom prompt without its text must not fall through to the default
    # Claude Code prompt; the String spelling already raised here.
    it 'rejects a custom system prompt without a prompt, whichever way the type is written' do
      errors = [{ type: 'custom' }, { type: :custom }, { 'type' => :custom, 'snapshot' => false }].map do |system_prompt|
        argv(system_prompt: system_prompt)
      rescue ArgumentError => e
        e.message
      end

      expect(errors).to eq(["system_prompt of type 'custom' requires a :prompt String"] * 3)
    end
  end

  # plugins: entries carry a `type` too ('local', or 'plugin', its older
  # name). A Symbol there was refused: "Unsupported plugin type: :local".
  describe 'a plugin Hash' do
    it 'builds the same command line with a Symbol type' do
      string_typed = argv(plugins: [{ type: 'local', path: '/srv/app/plugins/review' }])
      symbol_typed = [
        { type: :local, path: '/srv/app/plugins/review' },
        { 'type' => :local, 'path' => '/srv/app/plugins/review' },
        { type: :plugin, path: '/srv/app/plugins/review' }
      ].map { |plugin| argv(plugins: [plugin]) }

      expect(flag_value(string_typed, '--plugin-dir')).to eq('/srv/app/plugins/review')
      expect(symbol_typed).to eq([string_typed] * 3)
    end

    it 'still refuses a type that is not a plugin type, naming it as written' do
      messages = [{ type: 'remote', path: '/x' }, { type: :remote, path: '/x' }, { path: '/x' }].map do |plugin|
        argv(plugins: [plugin])
      rescue ArgumentError => e
        e.message
      end

      expect(messages).to eq(['Unsupported plugin type: "remote"', 'Unsupported plugin type: :remote',
                              'Unsupported plugin type: nil'])
    end
  end

  describe 'a type the SDK does not know' do
    it 'still sends no system prompt flag at all' do
      [{ type: 'bogus', prompt: 'x' }, { type: :bogus, prompt: 'x' }, { prompt: 'x' }, { type: nil }].each do |system_prompt|
        expect(argv(system_prompt: system_prompt))
          .not_to include('--system-prompt', '--system-prompt-file', '--append-system-prompt')
      end
    end

    it 'still sends a tools Hash as JSON text' do
      expect([{ type: 'bogus', names: ['Read'] }, { type: :bogus, names: ['Read'] }, { names: ['Read'] }]
        .map { |tools| flag_value(argv(tools: tools), '--tools') })
        .to eq(['{"type":"bogus","names":["Read"]}', '{"type":"bogus","names":["Read"]}', '{"names":["Read"]}'])
    end

    it 'still sends an output_format Hash as the schema itself' do
      bare_schema = { type: 'object', properties: { verdict: { type: 'string' } } }

      expect([bare_schema, bare_schema.merge(type: :object), { 'type' => 'text' }]
        .map { |output_format| flag_value(argv(output_format: output_format), '--json-schema') })
        .to eq([JSON.generate(bare_schema), JSON.generate(bare_schema), '{"type":"text"}'])
    end
  end

  # exclude_dynamic_sections and snapshot travel on the initialize request,
  # not on the command line, and are read off the same Hash. End to end
  # through the real control protocol: a fake Transport records each control
  # request as the CLI's JSON parser sees it and answers it.
  describe 'the initialize request' do
    let(:transport_class) do
      Class.new(ClaudeAgentSDK::Transport) do
        def initialize(_options, requests:)
          super()
          @requests = requests
          @queue = Thread::Queue.new
        end

        def connect = @ready = true
        def ready? = @ready
        def end_input; end
        def close = @queue.push(:eof)

        def write(data)
          message = JSON.parse(data, symbolize_names: true)
          return unless message[:type] == 'control_request'

          @requests << JSON.parse(data).fetch('request')
          response = { subtype: 'success', request_id: message[:request_id], response: {} }
          @queue.push({ type: 'control_response', response: response })
        end

        def read_messages
          loop do
            message = @queue.pop
            break if message == :eof

            yield message
          end
        end
      end
    end

    # What a session with this system prompt asks for on initialize.
    def prompt_fields_on_the_wire(system_prompt)
      requests = []
      Sync do
        client = ClaudeAgentSDK::Client.new(
          options: ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: system_prompt),
          transport_class: transport_class, transport_args: { requests: requests }
        )
        client.connect
      ensure
        client&.disconnect
      end
      requests.find { |request| request['subtype'] == 'initialize' }.slice('excludeDynamicSections', 'systemPromptSnapshot')
    end

    {
      'the preset' => [
        { type: 'preset', preset: 'claude_code', exclude_dynamic_sections: true, snapshot: false },
        { 'excludeDynamicSections' => true, 'systemPromptSnapshot' => false },
        {
          'a Symbol type' => { type: :preset, preset: :claude_code, exclude_dynamic_sections: true, snapshot: false },
          'a Symbol type under String keys' => {
            'type' => :preset, 'preset' => :claude_code, 'exclude_dynamic_sections' => true, 'snapshot' => false
          }
        }
      ],
      'a custom prompt' => [
        { type: 'custom', prompt: 'You are a terse reviewer.', snapshot: false },
        { 'systemPromptSnapshot' => false },
        {
          'a Symbol type' => { type: :custom, prompt: 'You are a terse reviewer.', snapshot: false },
          'a Symbol type under String keys' => {
            'type' => :custom, 'prompt' => 'You are a terse reviewer.', 'snapshot' => false
          }
        }
      ]
    }.each do |form, (string_typed, fields, spellings)|
      it "carries the prompt fields of #{form} with a String type" do
        expect(prompt_fields_on_the_wire(string_typed)).to eq(fields)
      end

      spellings.each do |spelling, hash|
        it "carries the same fields for #{form} with #{spelling}" do
          expect(prompt_fields_on_the_wire(hash)).to eq(fields)
        end
      end
    end

    it 'still carries neither field for a prompt file or a type the SDK does not know' do
      prompts = [
        { type: 'file', path: 'prompts/reviewer.md', snapshot: false, exclude_dynamic_sections: true },
        { type: :file, path: 'prompts/reviewer.md', snapshot: false, exclude_dynamic_sections: true },
        { type: :bogus, snapshot: false, exclude_dynamic_sections: true },
        { snapshot: false, exclude_dynamic_sections: true }
      ]

      expect(prompts.map { |system_prompt| prompt_fields_on_the_wire(system_prompt) }).to eq([{}] * 4)
    end

    it 'still leaves exclude_dynamic_sections to the preset: a custom prompt does not carry it' do
      prompts = [
        { type: 'custom', prompt: 'You are a terse reviewer.', exclude_dynamic_sections: true },
        { type: :custom, prompt: 'You are a terse reviewer.', exclude_dynamic_sections: true }
      ]

      expect(prompts.map { |system_prompt| prompt_fields_on_the_wire(system_prompt) }).to eq([{}] * 2)
    end
  end
end
