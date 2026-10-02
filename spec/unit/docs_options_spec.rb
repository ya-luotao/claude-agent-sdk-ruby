# frozen_string_literal: true

require 'spec_helper'
require 'json'

# docs/options.md is the reference for ClaudeAgentOptions: one table row per
# public attribute, with the option's type, its default and what it turns
# into. Every cell is checked against the code, so that a row with a made-up
# type, default, flag or initialize field fails:
#
#   Type      the constructor's keyword type in sig/
#   Default   a bare ClaudeAgentOptions.new, and a marker in the cell where an
#             explicit nil does not give that default
#   Sent ...  for sample values of the option: the flags CommandBuilder adds,
#             the initialize fields a Client sends, and the variables the
#             transport puts into the CLI's environment
RSpec.describe 'docs/options.md' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:page_path) { File.join(root, 'docs/options.md') }
  let(:page) { File.exist?(page_path) ? File.read(page_path) : '' }
  let(:options_class) { ClaudeAgentSDK::ClaudeAgentOptions }

  # What a Default cell says when an explicit nil does not give the default.
  let(:explicit_nil_marker) { 'explicit `nil` stays `nil`' }

  # The values each option is tried with: { option: value }, or
  # [context, { option: value }] where the option needs another one set.
  let(:samples) do
    sdk = ClaudeAgentSDK
    first, second, third = %w[0 1 2].map { |digit| "550e8400-e29b-41d4-a716-44665544000#{digit}" }
    callback = ->(*) {}
    {
      'system_prompt' => [{ system_prompt: 'Be brief.' },
                          { system_prompt: sdk::SystemPromptFile.new(path: '/srv/app/prompt.md') },
                          { system_prompt: sdk::SystemPromptCustom.new(prompt: 'Be brief.', snapshot: true) },
                          { system_prompt: sdk::SystemPromptPreset.new(preset: 'claude_code', append: 'Be brief.',
                                                                       exclude_dynamic_sections: true) }],
      'model' => [{ model: 'claude-sonnet-5-5' }],
      'fallback_model' => [{ fallback_model: 'claude-haiku-4-5' }],
      'advisor_model' => [{ advisor_model: 'claude-opus-5-5' }],
      'max_turns' => [{ max_turns: 3 }],
      'max_budget_usd' => [{ max_budget_usd: 0.5 }],
      'task_budget' => [{ task_budget: { total: 50_000 } }],
      'thinking' => [{ thinking: sdk::ThinkingConfigAdaptive.new },
                     { thinking: sdk::ThinkingConfigAdaptive.new(display: 'summarized') },
                     { thinking: sdk::ThinkingConfigEnabled.new(budget_tokens: 2000) },
                     { thinking: sdk::ThinkingConfigDisabled.new }],
      'effort' => [{ effort: 'high' }],
      'max_thinking_tokens' => [{ max_thinking_tokens: 2000 }],
      'betas' => [{ betas: ['context-1m-2025-08-07'] }],
      'output_format' => [{ output_format: { type: 'json_schema', schema: { type: 'object' } } }],
      'tools' => [{ tools: ['Read'] }, { tools: [] }, { tools: sdk::ToolsPreset.new(preset: 'claude_code') }],
      'allowed_tools' => [{ allowed_tools: ['Read'] }],
      'disallowed_tools' => [{ disallowed_tools: ['Bash'] }],
      'permission_mode' => [{ permission_mode: 'acceptEdits' }],
      'can_use_tool' => [{ can_use_tool: callback }],
      'permission_prompt_tool_name' => [{ permission_prompt_tool_name: 'mcp__permissions__ask' }],
      'hooks' => [{ hooks: { 'PreToolUse' => [sdk::HookMatcher.new(matcher: 'Bash', hooks: [callback])] } }],
      'skills' => [{ skills: 'all' }, { skills: ['pdf'] }],
      'sandbox' => [{ sandbox: { enabled: true } }],
      'mcp_servers' => [{ mcp_servers: { docs: { type: 'http', url: 'https://example.com/mcp' } } }],
      'strict_mcp_config' => [{ strict_mcp_config: true }],
      'agents' => [{ agents: { reviewer: sdk::AgentDefinition.new(description: 'Reviews code',
                                                                  prompt: 'Review the diff.') } }],
      'plugins' => [{ plugins: [{ type: 'local', path: '/srv/app/plugin' }] }],
      'settings' => [{ settings: { 'autoMemoryEnabled' => false } }],
      'setting_sources' => [{ setting_sources: ['project'] }, { setting_sources: [] }],
      'add_dirs' => [{ add_dirs: ['/srv/shared'] }],
      'bare' => [{ bare: true }],
      'verbatim_prompts' => [{ verbatim_prompts: true }],
      'resume' => [{ resume: first }],
      'continue_conversation' => [{ continue_conversation: true }],
      'fork_session' => [{ fork_session: true }],
      'session_id' => [{ session_id: first }],
      'resume_session_at' => [[{ resume: first }, { resume_session_at: second }]],
      'resume_drops_turn' => [[{ resume: first, resume_session_at: second }, { resume_drops_turn: third }]],
      'enable_file_checkpointing' => [{ enable_file_checkpointing: true }],
      'session_store' => [{ session_store: sdk::InMemorySessionStore.new }],
      'session_store_flush' => [{ session_store_flush: 'eager' }],
      'load_timeout_ms' => [{ load_timeout_ms: 1000 }],
      'include_partial_messages' => [{ include_partial_messages: true }],
      'include_hook_events' => [{ include_hook_events: true }],
      'forward_subagent_text' => [{ forward_subagent_text: true }],
      'agent_progress_summaries' => [{ agent_progress_summaries: true }, { agent_progress_summaries: false }],
      'cli_path' => [{ cli_path: '/opt/claude/bin/claude' }],
      'cwd' => [{ cwd: '/srv/app' }],
      'env' => [{ env: { 'ANTHROPIC_BASE_URL' => 'https://proxy.example.com' } }],
      'user' => [{ user: 'deploy' }],
      # The flag names are the caller's; the page writes them as `--<flag>`.
      'extra_args' => [{ extra_args: { 'any-flag' => 'value', 'any-switch' => nil } }],
      'stderr' => [{ stderr: callback }],
      'debug_stderr' => [{ debug_stderr: $stderr }],
      'max_buffer_size' => [{ max_buffer_size: 2_000_000 }],
      'observers' => [{ observers: [Object.new.extend(sdk::Observer)] }],
      'callback_scheduling' => [{ callback_scheduling: 'inline' }],
      'callback_wrapper' => [{ callback_wrapper: :call.to_proc }]
    }
  end

  # The fields of the initialize request each option sets; the options that
  # are not listed set none. Hand-written, and checked against the code below.
  let(:initialize_fields) do
    { 'system_prompt' => %w[excludeDynamicSections systemPromptSnapshot], 'hooks' => %w[hooks],
      'agents' => %w[agents], 'skills' => %w[skills], 'forward_subagent_text' => %w[forwardSubagentText],
      'agent_progress_summaries' => %w[agentProgressSummaries] }
  end

  # A stand-in for the CLI that answers every control request and keeps the
  # requests it was sent.
  let(:recording_transport_class) do
    Class.new do
      def self.requests
        @requests ||= []
      end

      def initialize(*)
        @frames = Thread::Queue.new
      end

      def connect; end

      def write(data)
        data.each_line do |line|
          frame = JSON.parse(line, symbolize_names: true)
          next unless frame[:type] == 'control_request'

          self.class.requests << frame[:request]
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

  # The page documents a bare ClaudeAgentOptions.new, so no configured
  # defaults may be left over from another example.
  around do |example|
    ClaudeAgentSDK.reset_configuration
    example.run
  ensure
    ClaudeAgentSDK.reset_configuration
  end

  # Attributes whose declaration carries a YARD `@api private` tag are not
  # public API (CONTRIBUTING.md, "What is public API") and need no entry.
  def private_attributes(source)
    declaration = /((?:^[ \t]*#.*\n)+)[ \t]*attr_(?:accessor|reader|writer)[ \t]+((?::\w+,?\s*)+)/
    source.scan(declaration).flat_map do |comment, names|
      comment.match?(/^\s*#\s*@api private\s*$/) ? names.scan(/:(\w+)/).flatten : []
    end
  end

  def public_attributes
    source = File.read(File.join(root, 'lib/claude_agent_sdk/types/options.rb'))
    options_class.attribute_names - private_attributes(source)
  end

  # The cells of a Markdown table row. An escaped pipe (`\|`) is part of its cell.
  def cells(line)
    parts = line.split(/(?<!\\)\|/, -1).map(&:strip)
    parts.size > 2 && parts.first.empty? && parts.last.empty? ? parts[1..-2] : []
  end

  # The rows of the option tables, as { name:, type:, default:, sent: }: the
  # rows with four cells whose first one is a name in backticks.
  def table_rows
    page.each_line(chomp: true).filter_map do |line|
      row = cells(line)
      next unless row.size == 4 && (name = row[0][/\A`(\w+)`\z/, 1])

      { name: name, type: row[1][/\A`(.*)`\z/, 1].to_s.gsub('\|', '|'), default: row[2], sent: row[3] }
    end
  end

  def rows
    table_rows.select { |row| public_attributes.include?(row[:name]) }
  end

  # The constructor's keyword types in sig/, the way the page writes them:
  # without the optional mark, and without the parentheses around a union.
  def constructor_types
    sig = File.read(File.join(root, 'sig/claude_agent_sdk/types/options.rbs'))
    keywords = sig[/^  class ClaudeAgentOptions\b.*?^ *def initialize: \(\n(.*?)^ *\) -> void/m, 1].to_s
    keywords.scan(/^ *\?(\w+): (.+?),?$/).to_h { |name, type| [name, unparenthesized(type.delete_suffix('?'))] }
  end

  def unparenthesized(type)
    inner = type[/\A\((.*)\)\z/, 1]
    inner && balanced?(inner) ? inner : type
  end

  def balanced?(text)
    depth = 0
    text.each_char do |char|
      depth += { '(' => 1, ')' => -1 }.fetch(char, 0)
      return false if depth.negative?
    end
    depth.zero?
  end

  def sample_pairs(name)
    samples.fetch(name, []).map { |sample| sample.is_a?(Array) ? sample : [{}, sample] }
  end

  def command_line(options)
    ClaudeAgentSDK::CommandBuilder.new('claude', ClaudeAgentSDK.configure_can_use_tool(options)).build
  end

  # The command line as [flag, value] pairs; `--flag=value` counts as one pair.
  def flag_pairs(options)
    arguments = command_line(options).drop(1)
    arguments.each_with_index.filter_map do |argument, index|
      next unless argument.start_with?('--')

      flag, value = argument.split('=', 2)
      following = arguments[index + 1]
      value ||= following unless following.nil? || following.start_with?('--')
      [flag, value]
    end
  end

  # The flags whose presence or value the sample changes.
  def flags_changed_by(context, sample)
    without = flag_pairs(options_class.new(**context))
    with = flag_pairs(options_class.new(**context, **sample))
    (without | with).reject { |pair| without.count(pair) == with.count(pair) }.map(&:first)
  end

  def flags_sent_for(name)
    flags = sample_pairs(name).flat_map { |context, sample| flags_changed_by(context, sample) }
    (name == 'extra_args' ? flags.map { '--<flag>' } : flags).uniq.sort
  end

  # The flags a cell names in its code spans: `--flag`, `--flag <value>`,
  # `--flag=<value>`.
  def flags_in(cell)
    cell.scan(/`([^`]*)`/).flatten.flat_map { |code| code.scan(/(?<![\w-])--(?:<flag>|[a-z][\w-]*)/i) }.uniq.sort
  end

  # The [flag, value] pairs a cell gives with a literal value, such as
  # `--tools default` or `--tools ""`, and not with a <placeholder>.
  def literal_pairs_in(cell)
    cell.scan(/`(--[a-z][\w-]*) ([^`<]+)`/i).map { |flag, value| [flag, value == '""' ? '' : value] }
  end

  def pairs_sent_for(name)
    sample_pairs(name).flat_map { |context, sample| flag_pairs(options_class.new(**context, **sample)) }
  end

  # The fields of the initialize request a Client sends for these options,
  # beyond the bare request ({ subtype:, hooks: nil, agents: nil }).
  def initialize_fields_sent(options)
    transport_class = recording_transport_class
    transport_class.requests.clear
    ClaudeAgentSDK::Client.open(options: options, transport_class: transport_class) { |_client| nil }
    request = transport_class.requests.find { |candidate| candidate[:subtype] == 'initialize' }
    request.except(:subtype).compact.keys.map(&:to_s)
  end

  it 'has one table row for every public ClaudeAgentOptions attribute, and for nothing else' do
    expect(public_attributes.size).to be >= 55
    expect(table_rows.map { |row| row[:name] }).to match_array(public_attributes)
  end

  it 'recognizes an attribute tagged @api private as not needing an entry' do
    source = <<~RUBY
      class ClaudeAgentOptions < Type
        attr_accessor :model, :cwd

        # Where the transport keeps its scratch files.
        #
        # @api private
        attr_accessor :scratch_dir,
                      :scratch_mode

        # Deliver every prompt as written.
        attr_reader :verbatim_prompts
      end
    RUBY

    expect(private_attributes(source)).to eq(%w[scratch_dir scratch_mode])
  end

  it 'gives every option the type its constructor keyword has in sig/' do
    wrong = rows.filter_map do |row|
      accepted = constructor_types[row[:name]]
      "#{row[:name]}: documented #{row[:type].inspect}, constructor #{accepted.inspect}" unless row[:type] == accepted
    end

    expect(wrong).to eq([])
  end

  it 'explains each type alias in the Type column with the members of its definition in sig/' do
    sig = Dir[File.join(root, 'sig/**/*.rbs')].map { |file| File.read(file) }.join("\n")
    aliases = rows.flat_map { |row| row[:type].scan(/(?<![:\w"])[a-z]\w*/) }.uniq - %w[bool untyped]
    wrong = aliases.filter_map do |name|
      definition = sig[/^ *type #{name} = (.*?)\n *\n/m, 1].to_s
      members = definition.gsub(/\[[^\]]*\]/, '').scan(/[A-Z]\w*/)
      explanation = page.each_line.map { |line| cells(line) }.find { |row| row.first == "`#{name}`" }.to_a.last.to_s
      documented = explanation.scan(/`([A-Z]\w*)`/).flatten + explanation.scan(/\bHash\b/).uniq
      "#{name}: documented #{documented.sort.inspect}, defined #{members.sort.inspect}" unless documented.sort == members.sort
    end

    expect(aliases).not_to be_empty
    expect(wrong).to eq([])
  end

  it 'gives every option the default a bare ClaudeAgentOptions.new has' do
    wrong = rows.filter_map do |row|
      actual = options_class.new.public_send(row[:name]).inspect
      documented = row[:default][/\A`([^`]*)`/, 1]
      "#{row[:name]}: documented #{documented.inspect}, actual #{actual.inspect}" unless documented == actual
    end

    expect(wrong).to eq([])
  end

  it 'marks exactly the options whose explicit nil stays nil, which still act as false' do
    stays_nil = public_attributes.reject do |name|
      options_class.new(name.to_sym => nil).public_send(name) == options_class.new.public_send(name)
    end
    marked = rows.select { |row| row[:default].include?(explicit_nil_marker) }.map { |row| row[:name] }
    changes_the_command_line = public_attributes.reject do |name|
      command_line(options_class.new(name.to_sym => nil)) == command_line(options_class.new)
    end

    expect(marked).to match_array(stays_nil)
    expect(stays_nil.map { |name| options_class.new(name.to_sym => nil).public_send(name) }.uniq).to eq([nil])
    expect(stays_nil.map { |name| options_class.new(name.to_sym => nil).public_send(:"#{name}?") }.uniq).to eq([false])
    expect(changes_the_command_line).to eq([])
  end

  # The table under "Leaving an option out, and passing nil".
  it 'resolves a left-out option, an explicit nil and a value the way the page tabulates it' do
    without_defaults = options_class.new(env: nil, fork_session: nil)
    ClaudeAgentSDK.configure do |config|
      config.default_options = { env: { 'A' => '1' }, fork_session: true, model: 'claude-opus-5-5' }
    end
    left_out = options_class.new
    with_nil = options_class.new(env: nil, fork_session: nil, model: nil, include_partial_messages: nil)
    with_value = options_class.new(env: { 'B' => '2' }, fork_session: false, model: 'claude-haiku-4-5')

    expect([without_defaults.env, without_defaults.fork_session]).to eq([{}, nil])
    expect([left_out.env, left_out.fork_session, left_out.model]).to eq([{ 'A' => '1' }, true, 'claude-opus-5-5'])
    expect([with_nil.env, with_nil.fork_session, with_nil.model]).to eq([{ 'A' => '1' }, true, 'claude-opus-5-5'])
    expect(with_nil.include_partial_messages).to be_nil # no default is configured for it
    expect([with_value.env, with_value.fork_session, with_value.model])
      .to eq([{ 'A' => '1', 'B' => '2' }, false, 'claude-haiku-4-5'])
  end

  it 'stores a String callback_scheduling as its Symbol, as the row says' do
    sent = rows.find { |row| row[:name] == 'callback_scheduling' }.to_h.fetch(:sent, '')

    expect(options_class.new(callback_scheduling: 'inline').callback_scheduling).to be(:inline)
    expect(options_class.new(callback_scheduling: 'thread').callback_scheduling).to be(:thread)
    expect(sent).to include('A String is stored as its Symbol')
  end

  it 'names, for every option, the flags CommandBuilder sends for it and no other' do
    wrong = rows.filter_map do |row|
      documented = flags_in(row[:sent])
      sent = flags_sent_for(row[:name])
      "#{row[:name]}: documented #{documented.inspect}, sent #{sent.inspect}" unless documented == sent
    end

    expect(samples.keys).to match_array(public_attributes)
    expect(wrong).to eq([])
  end

  it 'gives a flag a literal value only where CommandBuilder sends that value' do
    literal = rows.flat_map { |row| literal_pairs_in(row[:sent]).map { |pair| [row[:name], pair] } }
    wrong = literal.filter_map do |name, pair|
      "#{name}: #{pair.join(' ').inspect} is not sent for any of its samples" unless pairs_sent_for(name).include?(pair)
    end

    expect(literal.size).to be >= 5
    expect(wrong).to eq([])
  end

  it 'names, for every option, the initialize fields it sets and no other' do
    wrong = rows.filter_map do |row|
      documented = row[:sent].scan(/`initialize\.(\w+)`/).flatten.sort
      sent = initialize_fields.fetch(row[:name], []).sort
      "#{row[:name]}: documented #{documented.inspect}, sent #{sent.inspect}" unless documented == sent
    end

    expect(wrong).to eq([])
  end

  # initialize_fields is hand-written, so it is checked twice: each entry
  # against the request a Client sends for the option's samples, and all of
  # them together against the fields Query can put into that request.
  it 'expects the initialize fields a Client sends, and Query has no others' do
    sent = initialize_fields.keys.to_h do |name|
      requests = sample_pairs(name).map { |context, sample| options_class.new(**context, **sample) }
      [name, requests.flat_map { |options| initialize_fields_sent(options) }.uniq.sort]
    end
    query = File.read(File.join(root, 'lib/claude_agent_sdk/query.rb'))
    request = query[/^ *request = \{\n *subtype: 'initialize',\n(.*?)send_control_request\(request\)/m, 1].to_s
    known_to_query = request.scan(/^ *(\w+): /).flatten + request.scan(/request\[:(\w+)\]/).flatten

    expect(initialize_fields_sent(options_class.new)).to eq([])
    expect(sent).to eq(initialize_fields.transform_values(&:sort))
    expect(known_to_query).to match_array(initialize_fields.values.flatten)
  end

  # The transport builds the CLI's environment only while it starts the CLI,
  # so the variables it sets for an option are read from its source.
  it 'names, for every option, the environment variables the transport sets for it and no other' do
    transport = File.read(File.join(root, 'lib/claude_agent_sdk/subprocess_cli_transport.rb'))
    set_for = transport.scan(/process_env\['(\w+)'\] = '\w+' if @options\.(\w+)/)
                       .group_by(&:last).transform_values { |pairs| pairs.map(&:first) }
    wrong = rows.filter_map do |row|
      documented = row[:sent].scan(/`([A-Z][A-Z0-9_]+)=[^`]*`/).flatten
      set = set_for.fetch(row[:name], [])
      "#{row[:name]}: documented #{documented.inspect}, set #{set.inspect}" unless documented == set
    end

    expect(set_for).not_to be_empty
    expect(wrong).to eq([])
  end

  it 'is linked from the README documentation table' do
    readme = File.read(File.join(root, 'README.md'))

    expect(readme).to match(%r{\]\([^)]*docs/options\.md\)})
  end
end
