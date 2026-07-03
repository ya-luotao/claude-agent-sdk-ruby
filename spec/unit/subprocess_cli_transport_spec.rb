# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe ClaudeAgentSDK::SubprocessCLITransport do
  # The active-process registry is class-level mutable state shared across the
  # whole suite. Several #connect specs register a stubbed Process::Waiter and
  # never call #close, so clear it between examples to keep the at_exit handler
  # (and other specs) from observing leaked test doubles.
  after { described_class.active_processes.clear }

  describe '#build_command' do
    it 'passes a string system_prompt via --system-prompt' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: 'You are a helpful assistant'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt', 'You are a helpful assistant')
    end

    it 'passes a preset system_prompt via --append-system-prompt only (no --system-prompt)' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: { type: 'preset', preset: 'claude_code', append: 'Extra instructions' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--system-prompt')
      expect(cmd).to include('--append-system-prompt', 'Extra instructions')
    end

    it 'supports SystemPromptPreset objects' do
      preset = ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code', append: 'Extra')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: preset
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--system-prompt')
      expect(cmd).to include('--append-system-prompt', 'Extra')
    end

    it 'passes empty system prompt when nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--system-prompt')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('')
    end

    it 'always uses --input-format stream-json' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--input-format', 'stream-json')
    end

    it 'omits --setting-sources when setting_sources is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--setting-sources')
    end

    it 'emits --setting-sources joined by commas when set' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        setting_sources: %w[user project]
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--setting-sources', 'user,project')
    end

    it 'does not include --agents in CLI args' do
      agent = ClaudeAgentSDK::AgentDefinition.new(
        description: 'Test agent',
        prompt: 'You are helpful'
      )
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        agents: { test: agent }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--agents')
    end

    it 'passes valid extra_args flags as --flag value' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        extra_args: { 'debug-to-stderr' => nil, 'custom-flag' => 'value' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--debug-to-stderr')
      expect(cmd).to include('--custom-flag', 'value')
    end

    it 'rejects extra_args keys that contain spaces or invalid characters' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        extra_args: { 'permission-mode bypassPermissions' => nil }
      )

      transport = described_class.new('hi', options)

      expect { transport.build_command }.to raise_error(ArgumentError, /Invalid extra_args flag name/)
    end

    it 'rejects extra_args keys that are empty or start with --' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        extra_args: { '--permission-mode' => 'bypassPermissions' }
      )

      transport = described_class.new('hi', options)

      expect { transport.build_command }.to raise_error(ArgumentError, /Invalid extra_args flag name/)
    end

    it 'passes --thinking adaptive for ThinkingConfigAdaptive' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('adaptive')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'passes --max-thinking-tokens for ThinkingConfigEnabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigEnabled.new(budget_tokens: 50_000)
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--max-thinking-tokens')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('50000')
      expect(cmd).not_to include('--thinking')
    end

    it 'passes --thinking disabled for ThinkingConfigDisabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigDisabled.new
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('disabled')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'thinking takes precedence over deprecated max_thinking_tokens' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        thinking: ClaudeAgentSDK::ThinkingConfigAdaptive.new,
        max_thinking_tokens: 99_999
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--thinking')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('adaptive')
      expect(cmd).not_to include('--max-thinking-tokens')
    end

    it 'falls back to max_thinking_tokens when thinking is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        max_thinking_tokens: 20_000
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--max-thinking-tokens')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('20000')
    end

    it 'passes --effort flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'high'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'high')
    end

    it 'passes --effort max' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'max'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'max')
    end

    it 'passes --effort xhigh' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 'xhigh'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', 'xhigh')
    end

    it 'omits --effort when effort is nil' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: nil
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--effort')
    end

    it 'forwards an Integer effort verbatim' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        effort: 8000
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--effort', '8000')
    end

    it 'maps tools preset objects to the CLI default tool set' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        tools: ClaudeAgentSDK::ToolsPreset.new(preset: 'claude_code')
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      idx = cmd.index('--tools')
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq('default')
    end

    it 'uses plugin directories instead of --plugins JSON' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        plugins: [ClaudeAgentSDK::SdkPluginConfig.new(path: '/tmp/plugin')]
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--plugin-dir', '/tmp/plugin')
      expect(cmd).not_to include('--plugins')
    end

    it 'merges sandbox settings into settings loaded from a file path' do
      Tempfile.create(['claude-settings', '.json']) do |file|
        file.write(JSON.generate({ permissions: { allow: ['Bash(ls:*)'] } }))
        file.flush

        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          cli_path: '/usr/bin/claude',
          settings: file.path,
          sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
        )

        transport = described_class.new('hi', options)
        cmd = transport.build_command

        idx = cmd.index('--settings')
        expect(idx).not_to be_nil

        merged_settings = JSON.parse(cmd[idx + 1])
        expect(merged_settings).to eq(
          'permissions' => { 'allow' => ['Bash(ls:*)'] },
          'sandbox' => { 'enabled' => true }
        )
      end
    end

    it 'raises when settings file path contains invalid JSON and sandbox is enabled' do
      Tempfile.create(['claude-settings', '.json']) do |file|
        file.write('not valid json {{{')
        file.flush

        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          cli_path: '/usr/bin/claude',
          settings: file.path,
          sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
        )

        transport = described_class.new('hi', options)
        expect { transport.build_command }.to raise_error(JSON::ParserError)
      end
    end

    it 'raises when settings file path does not exist and sandbox is enabled' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        settings: '/nonexistent/path/settings.json',
        sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
      )

      transport = described_class.new('hi', options)
      expect { transport.build_command }.to raise_error(ClaudeAgentSDK::CLIConnectionError, /Settings file not found/)
    end

    it 'passes --system-prompt-file for SystemPromptFile objects' do
      prompt_file = ClaudeAgentSDK::SystemPromptFile.new(path: '/tmp/prompt.txt')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: prompt_file
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt-file', '/tmp/prompt.txt')
      expect(cmd).not_to include('--system-prompt')
    end

    it 'passes --system-prompt-file for Hash with type: file' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        system_prompt: { type: 'file', path: '/tmp/prompt.txt' }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--system-prompt-file', '/tmp/prompt.txt')
    end

    it 'passes --session-id flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        session_id: '550e8400-e29b-41d4-a716-446655440000'
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--session-id', '550e8400-e29b-41d4-a716-446655440000')
    end

    it 'passes --task-budget from TaskBudget object' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: ClaudeAgentSDK::TaskBudget.new(total: 50_000)
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '50000')
    end

    it 'passes --task-budget from Hash with symbol keys' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: { total: 30_000 }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '30000')
    end

    it 'passes --task-budget from Hash with string keys' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        task_budget: { 'total' => 25_000 }
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).to include('--task-budget', '25000')
    end

    it 'does not add the deprecated enable-file-checkpointing flag' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        enable_file_checkpointing: true
      )

      transport = described_class.new('hi', options)
      cmd = transport.build_command

      expect(cmd).not_to include('--enable-file-checkpointing')
    end
  end

  describe '#read_messages — oversized line memory bound (M15)' do
    it 'yields bounded chunks for oversized lines instead of allocating the whole line' do
      spy = Class.new do
        attr_reader :max_chunk

        def initialize(io)
          @io = io
          @max_chunk = 0
        end

        def set_encoding(*) = self

        def each_line(*args, &blk)
          @io.each_line(*args) do |chunk|
            @max_chunk = [@max_chunk, chunk.bytesize].max
            blk.call(chunk)
          end
        end
      end

      oversized = "{\"type\":\"x\",\"data\":\"#{'a' * 8192}\"}\n"
      stdout = spy.new(StringIO.new(oversized))
      status = instance_double(Process::Status, exitstatus: 0, signaled?: false)
      waiter = instance_double(Process::Waiter, alive?: false, value: status)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude', max_buffer_size: 1024)
      transport = described_class.new('hi', options)
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3).and_return([StringIO.new, stdout, StringIO.new, waiter])
      transport.connect

      expect { transport.read_messages { |m| m } }.to raise_error(ClaudeAgentSDK::CLIJSONDecodeError)
      # limit 1025 + a few bytes of multibyte slack — never the full 8KB line
      expect(stdout.max_chunk).to be <= 1032
    ensure
      transport&.close
    end

    it 'accumulates multi-line (pretty-printed) JSON and parses it once complete' do
      # The chunked-read rewrite only had failure-path coverage for the
      # accumulation machinery; this pins the success path the json_buffer
      # exists for: one JSON object split across multiple newline-terminated
      # lines parses byte-identically, including a continuation line whose
      # LEADING whitespace is part of the message (position-aware handling
      # must not strip it into invalid JSON).
      lines = %({"type":"assistant",\n  "data":"with  interior  spaces"}\n)
      status = instance_double(Process::Status, exitstatus: 0, signaled?: false)
      waiter = instance_double(Process::Waiter, alive?: false, value: status)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')
      transport = described_class.new('hi', options)
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3)
        .and_return([StringIO.new, StringIO.new(lines), StringIO.new, waiter])
      transport.connect

      messages = []
      transport.read_messages { |m| messages << m }

      expect(messages.length).to eq(1)
      expect(messages.first[:data]).to eq('with  interior  spaces')
    ensure
      transport&.close
    end

    it 'raises (never silently drops whitespace) for a line just over the cap' do
      # A whitespace run straddling the chunk boundary of a barely-over-cap
      # line: a per-chunk strip shrank the first chunk back under the cap and
      # the line PARSED with the interior spaces deleted — silent corruption.
      max = 1024
      prefix = %({"type":"x","data":")
      pad = 'a' * (max + 1 - prefix.bytesize - 15)
      line = "#{prefix}#{pad}#{' ' * 30}tail\"}\n"
      expect(line.bytesize).to be_between(max + 2, max + 40)

      status = instance_double(Process::Status, exitstatus: 0, signaled?: false)
      waiter = instance_double(Process::Waiter, alive?: false, value: status)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude', max_buffer_size: max)
      transport = described_class.new('hi', options)
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3)
        .and_return([StringIO.new, StringIO.new(line), StringIO.new, waiter])
      transport.connect

      messages = []
      expect { transport.read_messages { |m| messages << m } }
        .to raise_error(ClaudeAgentSDK::CLIJSONDecodeError)
      expect(messages).to be_empty
    ensure
      transport&.close
    end
  end

  describe '#end_input locking' do
    it 'respects @stdin_mutex (deterministic lock-hold test)' do
      transport = described_class.new('hi', ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))
      r, w = IO.pipe
      transport.instance_variable_set(:@stdin, w)
      mutex = transport.instance_variable_get(:@stdin_mutex)

      mutex.lock
      worker = Thread.new { transport.end_input }
      sleep 0.05
      # Pre-fix: end_input ignored the held mutex — stdin already nil/closed here.
      expect(transport.instance_variable_get(:@stdin)).to equal(w)
      expect(w.closed?).to be(false)

      mutex.unlock
      expect(worker.join(1)).not_to be_nil
      expect(transport.instance_variable_get(:@stdin)).to be_nil
      expect(w.closed?).to be(true)
    ensure
      mutex.unlock if mutex&.owned?
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    it 'is idempotent' do
      transport = described_class.new('hi', ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))
      expect { 2.times { transport.end_input } }.not_to raise_error
    end
  end

  describe 'user option (spawn :uid)' do
    def connect_capturing_opts(options)
      transport = described_class.new('hi', options)
      allow(transport).to receive(:check_claude_version)
      captured_opts = nil
      stdin = instance_double(IO, close: nil)
      allow(Open3).to receive(:popen3) do |_env, *rest|
        captured_opts = rest.last.is_a?(Hash) ? rest.last : {}
        [stdin, instance_double(IO, set_encoding: nil), instance_double(IO, set_encoding: nil),
         instance_double(Process::Waiter)]
      end
      transport.connect
      captured_opts
    end

    it 'passes options.user as the spawn :uid option (String or Integer)' do
      opts = connect_capturing_opts(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude',
                                                                           user: 'claude-runner'))
      expect(opts[:uid]).to eq('claude-runner')

      opts = connect_capturing_opts(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude', user: 1001))
      expect(opts[:uid]).to eq(1001)
    end

    it 'omits :uid when user is nil (uid: nil raises TypeError in spawn)' do
      opts = connect_capturing_opts(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))
      expect(opts).not_to have_key(:uid)
    end
  end

  describe 'OTel trace context propagation' do
    around do |example|
      saved = %w[TRACEPARENT TRACESTATE BAGGAGE].to_h { |k| [k, ENV.fetch(k, nil)] }
      saved.each_key { |k| ENV.delete(k) }
      example.run
    ensure
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end

    def connect_and_capture_env(options)
      transport = described_class.new('hi', options)
      allow(transport).to receive(:check_claude_version)
      captured_env = nil
      stdin = instance_double(IO)
      allow(stdin).to receive(:close)
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO, set_encoding: nil), instance_double(IO, set_encoding: nil),
         instance_double(Process::Waiter)]
      end
      transport.connect
      captured_env
    end

    def stub_otel_propagation(carrier_content)
      propagation = double('propagation')
      allow(propagation).to receive(:inject) { |carrier| carrier.merge!(carrier_content) }
      stub_const('OpenTelemetry', double('OpenTelemetry', propagation: propagation))
    end

    it 'injects TRACEPARENT (uppercased) when a span is active' do
      stub_otel_propagation('traceparent' => '00-aaaa-bbbb-01', 'tracestate' => 'vendor=1')
      env = connect_and_capture_env(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))

      expect(env['TRACEPARENT']).to eq('00-aaaa-bbbb-01')
      expect(env['TRACESTATE']).to eq('vendor=1')
    end

    it 'scrubs stale inherited TRACESTATE when the fresh carrier has none' do
      ENV['TRACEPARENT'] = '00-stale-stale-00'
      ENV['TRACESTATE'] = 'stale=1'
      stub_otel_propagation('traceparent' => '00-aaaa-bbbb-01')
      env = connect_and_capture_env(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))

      expect(env['TRACEPARENT']).to eq('00-aaaa-bbbb-01')
      # nil actively unsets through the spawn overlay
      expect(env).to have_key('TRACESTATE')
      expect(env['TRACESTATE']).to be_nil
    end

    it 'never overrides explicit options.env keys' do
      stub_otel_propagation('traceparent' => '00-aaaa-bbbb-01', 'tracestate' => 'vendor=1')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude', env: { 'TRACEPARENT' => '00-user-user-01' }
      )
      env = connect_and_capture_env(options)

      expect(env['TRACEPARENT']).to eq('00-user-user-01')
      expect(env['TRACESTATE']).to eq('vendor=1')
    end

    it 'preserves inherited W3C env for a baggage-only carrier' do
      ENV['TRACEPARENT'] = '00-inherited-inherited-01'
      stub_otel_propagation('baggage' => 'k=v')
      env = connect_and_capture_env(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))

      expect(env['TRACEPARENT']).to eq('00-inherited-inherited-01')
      expect(env).not_to have_key('BAGGAGE')
    end

    it 'forwards all carrier keys (e.g. BAGGAGE) when a span is active' do
      stub_otel_propagation('traceparent' => '00-aaaa-bbbb-01', 'baggage' => 'tenant=acme')
      env = connect_and_capture_env(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))

      expect(env['BAGGAGE']).to eq('tenant=acme')
    end

    it 'is a no-op without OpenTelemetry loaded' do
      hide_const('OpenTelemetry')
      env = connect_and_capture_env(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))

      expect(env).not_to have_key('TRACEPARENT')
    end

    it 'never breaks connect when the propagator raises' do
      propagation = double('propagation')
      allow(propagation).to receive(:inject).and_raise(NotImplementedError, 'abstract propagator')
      stub_const('OpenTelemetry', double('OpenTelemetry', propagation: propagation))

      expect do
        connect_and_capture_env(ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))
      end.not_to raise_error
    end
  end

  describe '#check_claude_version' do
    around do |example|
      previous = ENV.fetch('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK', nil)
      ENV.delete('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK')
      example.run
    ensure
      if previous
        ENV['CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'] = previous
      else
        ENV.delete('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK')
      end
    end

    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    # Real pipes so the drainer thread reads to EOF like production.
    def fake_version_probe(output)
      stdin_r, stdin_w = IO.pipe
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      out_w.binmode
      out_w.write(output)
      [out_w, err_w, stdin_r].each(&:close)
      waiter = instance_double(Process::Waiter, alive?: false, pid: 4242)
      [stdin_w, out_r, err_r, waiter]
    end

    it 'probes via arg-vector popen3 (no shell)' do
      expect(Open3).to receive(:popen3).with('/usr/bin/claude', '-v')
                                       .and_return(fake_version_probe("2.1.22 (Claude Code)\n"))

      expect { transport.check_claude_version }.not_to output.to_stderr
    end

    it 'skips the probe entirely when CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK is set' do
      ENV['CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'] = '1'
      expect(Open3).not_to receive(:popen3)

      expect { transport.check_claude_version }.not_to output.to_stderr
    end

    it "skips for any non-empty value, including '0' (Python truthiness parity)" do
      ENV['CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'] = '0'
      expect(Open3).not_to receive(:popen3)

      transport.check_claude_version
    end

    it 'does not skip for an empty string' do
      ENV['CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'] = ''
      expect(Open3).to receive(:popen3).with('/usr/bin/claude', '-v')
                                       .and_return(fake_version_probe("2.1.22 (Claude Code)\n"))

      transport.check_claude_version
    end

    it 'gives up silently when the probe hangs past the deadline' do
      stub_const("#{described_class}::VERSION_CHECK_TIMEOUT_SECONDS", 0.2)
      # Pipes whose write ends stay open: the drainer never reaches EOF,
      # exactly like a wedged `claude -v`.
      stdin_r, stdin_w = IO.pipe
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      waiter = instance_double(Process::Waiter, alive?: false, pid: 4242)
      allow(Open3).to receive(:popen3).and_return([stdin_w, out_r, err_r, waiter])

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { transport.check_claude_version }.not_to raise_error
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 2
    ensure
      [stdin_r, out_w, err_w].each { |io| io&.close unless io&.closed? }
    end

    it 'warns (with the cli path) for unsupported versions' do
      allow(Open3).to receive(:popen3)
        .and_return(fake_version_probe("1.0.0 (Claude Code)\n"))

      expect { transport.check_claude_version }
        .to output(%r{1\.0\.0 at /usr/bin/claude is unsupported}).to_stderr
    end
  end

  describe '#wait_process_with_timeout' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    it 'returns the process value when the process exits within the timeout' do
      process = double('Process::Waiter', pid: 1234)
      allow(process).to receive(:alive?).and_return(true, false)
      allow(process).to receive(:value).and_return(:exited)

      transport.instance_variable_set(:@process, process)

      expect(transport.send(:wait_process_with_timeout, 1)).to eq(:exited)
    end

    it 'raises Timeout::Error when the process stays alive past the deadline' do
      process = double('Process::Waiter', pid: 1234)
      allow(process).to receive(:alive?).and_return(true)

      transport.instance_variable_set(:@process, process)

      expect { transport.send(:wait_process_with_timeout, 0.1) }.to raise_error(Timeout::Error)
    end
  end

  describe 'environment variable handling' do
    it 'converts symbol keys in env to strings for spawn compatibility' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        env: { SYMBOL_KEY: 'value', 'STRING_KEY' => 'value2', 'CLAUDE_CODE_ENTRYPOINT' => 'sdk-rb' }
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO, set_encoding: nil), instance_double(IO, set_encoding: nil),
         instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['SYMBOL_KEY']).to eq('value')
      expect(captured_env['STRING_KEY']).to eq('value2')
      expect(captured_env.key?(:SYMBOL_KEY)).to be false
      expect(captured_env['CLAUDE_CODE_ENTRYPOINT']).to eq('sdk-rb')
    end

    it 'overrides an inherited CLAUDE_CODE_ENTRYPOINT with sdk-rb' do
      previous = ENV.fetch('CLAUDE_CODE_ENTRYPOINT', nil)
      ENV['CLAUDE_CODE_ENTRYPOINT'] = 'cli' # ambient value inside a Claude Code terminal
      transport = described_class.new('hi', ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))

      stdin = instance_double(IO, close: nil)
      captured_env = nil
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO, set_encoding: nil), instance_double(IO, set_encoding: nil),
         instance_double(Process::Waiter)]
      end

      transport.connect

      # Pre-fix ||= let the inherited 'cli' win, mis-attributing telemetry.
      expect(captured_env['CLAUDE_CODE_ENTRYPOINT']).to eq('sdk-rb')
    ensure
      if previous
        ENV['CLAUDE_CODE_ENTRYPOINT'] = previous
      else
        ENV.delete('CLAUDE_CODE_ENTRYPOINT')
      end
    end

    it 'never lets options.env override CLAUDE_AGENT_SDK_VERSION' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude', env: { 'CLAUDE_AGENT_SDK_VERSION' => 'fake' }
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO, close: nil)
      captured_env = nil
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO, set_encoding: nil), instance_double(IO, set_encoding: nil),
         instance_double(Process::Waiter)]
      end

      transport.connect

      expect(captured_env['CLAUDE_AGENT_SDK_VERSION']).to eq(ClaudeAgentSDK::VERSION)
    end

    it 'preserves a caller-provided CLAUDE_CODE_ENTRYPOINT value' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        env: { 'CLAUDE_CODE_ENTRYPOINT' => 'custom-entrypoint' }
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO, set_encoding: nil), instance_double(IO, set_encoding: nil),
         instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['CLAUDE_CODE_ENTRYPOINT']).to eq('custom-entrypoint')
    end

    it 'enables SDK file checkpointing via environment variable' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        enable_file_checkpointing: true
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO, set_encoding: nil), instance_double(IO, set_encoding: nil),
         instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      expect(captured_env['CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING']).to eq('true')
    end

    it 'does not set FGTS env var even when partial messages are requested' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        include_partial_messages: true
      )
      transport = described_class.new('hi', options)

      stdin = instance_double(IO)
      captured_env = nil
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3) do |env, *_args|
        captured_env = env
        [stdin, instance_double(IO, set_encoding: nil), instance_double(IO, set_encoding: nil),
         instance_double(Process::Waiter)]
      end
      allow(stdin).to receive(:close)

      transport.connect

      # FGTS env var was reverted in Python SDK v0.1.48 due to 400 errors on proxies/Bedrock/Vertex
      expect(captured_env).not_to have_key('CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING')
    end
  end

  describe '#read_messages — non-JSON line robustness' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    # Regression: the CLI occasionally writes non-JSON debug text to stdout
    # (e.g. `[SandboxDebug]` prefixes, ANSI escapes). Without the start-with-{
    # guard those lines would be appended into json_buffer, poisoning every
    # subsequent parse until the 1 MB cap raised CLIJSONDecodeError and
    # killed the entire session.
    it 'skips stdout lines that do not start with { when json_buffer is empty' do
      stdout = StringIO.new(
        "[SandboxDebug] starting up\n" \
        "{\"type\":\"system\",\"subtype\":\"init\"}\n" \
        "stray warning line\n" \
        "{\"type\":\"result\",\"subtype\":\"success\"}\n"
      )
      fake_process = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0, signaled?: false))
      transport.instance_variable_set(:@stdout, stdout)
      transport.instance_variable_set(:@process, fake_process)

      messages = []
      transport.read_messages { |m| messages << m }

      expect(messages.map { |m| m[:type] }).to eq(%w[system result])
    end
  end

  describe '#read_messages — invalid UTF-8 robustness' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    def wire_stdout(text)
      fake_process = instance_double(Process::Waiter, value: instance_double(Process::Status, exitstatus: 0, signaled?: false))
      transport.instance_variable_set(:@stdout, StringIO.new(text))
      transport.instance_variable_set(:@process, fake_process)
    end

    # Regression: stdout is UTF-8-tagged, so a single line carrying invalid
    # bytes made line.strip raise Encoding::CompatibilityError, aborting the
    # stream and dropping every already-buffered valid frame (including a
    # trailing result). The version-probe path already scrubbed; the read
    # loop must too.
    it 'survives a stray line with invalid UTF-8 bytes and keeps delivering later frames' do
      wire_stdout(
        "{\"type\":\"system\",\"subtype\":\"init\"}\n" \
        "stray \xFF binary noise\n" \
        "{\"type\":\"result\",\"subtype\":\"success\"}\n"
      )
      messages = []
      transport.read_messages { |m| messages << m }

      expect(messages.map { |m| m[:type] }).to eq(%w[system result])
    end

    it 'scrubs invalid bytes inside a JSON frame instead of raising mid-stream' do
      wire_stdout("{\"type\":\"system\",\"note\":\"caf\xE9\"}\n")
      messages = []
      transport.read_messages { |m| messages << m }

      expect(messages.length).to eq(1)
      expect(messages.first[:note]).to start_with('caf')
    end
  end

  describe '#read_messages — signal-terminated CLI (H2)' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    def wire(stdout_text, status)
      fake_process = instance_double(Process::Waiter, value: status)
      transport.instance_variable_set(:@stdout, StringIO.new(stdout_text))
      transport.instance_variable_set(:@process, fake_process)
    end

    # Regression: exitstatus is nil for a signal death (OOM-kill SIGKILL,
    # SIGSEGV, ...), so `returncode && returncode != 0` was false and the
    # consumer saw a normal end-of-stream — a TRUNCATED response reported as
    # clean success. Python raises with a negative returncode.
    it 'raises ProcessError with the signal number instead of reporting clean success' do
      wire("{\"type\":\"system\",\"subtype\":\"init\"}\n",
           instance_double(Process::Status, exitstatus: nil, signaled?: true, termsig: 9))

      messages = []
      expect { transport.read_messages { |m| messages << m } }
        .to raise_error(ClaudeAgentSDK::ProcessError) do |e|
          expect(e.message).to include('terminated by signal 9')
          expect(e.exit_code).to eq(-9) # Python subprocess returncode parity
        end
      expect(messages.map { |m| m[:type] }).to eq(['system']) # buffered frames still delivered first
    end

    it 'still treats a clean exit 0 as success' do
      wire("{\"type\":\"result\",\"subtype\":\"success\"}\n",
           instance_double(Process::Status, exitstatus: 0, signaled?: false))

      messages = []
      expect { transport.read_messages { |m| messages << m } }.not_to raise_error
      expect(messages.length).to eq(1)
    end
  end

  describe '#write — close-while-writing does not deadlock' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    # Regression for Codex P2: write previously held @stdin_mutex across the
    # blocking IO call. If a full pipe buffer made @stdin.write block, close()
    # could not acquire the same mutex and disconnect would hang.
    # Now mutex only guards reference snapshot, so close() can always proceed.
    it 'lets close() acquire the lock even while a write is blocked on a full pipe' do
      r, w = IO.pipe
      fake_process = instance_double(Process::Waiter)
      allow(fake_process).to receive(:alive?).and_return(true)
      transport.instance_variable_set(:@stdin, w)
      transport.instance_variable_set(:@process, fake_process)
      transport.instance_variable_set(:@ready, true)

      # Block in @stdin.write by filling the pipe and never reading r.
      writer = Thread.new do
        transport.write('x' * 200_000)
      rescue StandardError
        # write() raises CLIConnectionError once the stream is closed; expected.
      end

      # Give writer a moment to start blocking inside @stdin.write.
      sleep 0.05

      # The mutex must NOT be held by the writer at this point — verify by
      # calling write() from this thread; if the mutex were held, this
      # would itself block. Instead, we use Mutex#try_lock semantics via
      # snapshot under timeout: just call close-like teardown.
      stdin_mutex = transport.instance_variable_get(:@stdin_mutex)
      acquired = false
      Thread.new do
        stdin_mutex.synchronize { acquired = true }
      end.join(1)
      expect(acquired).to be true

      # Cleanup
      w.close
      r.close
      writer.join(1)
    end
  end

  describe '#read_messages — process double-wait handling' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    # Regression: if close() reaped the process while read_messages was
    # winding down, @process.value would raise Errno::ECHILD on the second
    # waitpid and the exception leaked out of read_messages.
    it 'tolerates Errno::ECHILD from @process.value (process already waited)' do
      stdout = StringIO.new("{\"type\":\"system\"}\n")
      waiter = instance_double(Process::Waiter)
      allow(waiter).to receive(:value).and_raise(Errno::ECHILD)
      transport.instance_variable_set(:@stdout, stdout)
      transport.instance_variable_set(:@process, waiter)

      expect { transport.read_messages { |m| m } }.not_to raise_error
    end
  end

  describe 'active-process registry (at_exit cleanup)' do
    it 'registers and deregisters a process by identity' do
      waiter = instance_double(Process::Waiter)

      described_class.register_active_process(waiter)
      expect(described_class.active_processes).to include(waiter)

      described_class.deregister_active_process(waiter)
      expect(described_class.active_processes).not_to include(waiter)
    end

    it 'is a no-op when given nil and dedupes repeated registrations' do
      waiter = instance_double(Process::Waiter)

      described_class.register_active_process(nil)
      described_class.register_active_process(waiter)
      described_class.register_active_process(waiter)

      expect(described_class.active_processes.size).to eq(1)
    end

    it 'kill_active_processes SIGTERMs only live processes, then clears the registry' do
      live = instance_double(Process::Waiter, pid: 4242, alive?: true)
      dead = instance_double(Process::Waiter, pid: 4243, alive?: false)
      described_class.register_active_process(live)
      described_class.register_active_process(dead)

      # A single positive expectation also asserts the dead process is skipped:
      # any kill('TERM', 4243) would surface as an unexpected-arguments failure.
      expect(Process).to receive(:kill).with('TERM', 4242)

      described_class.kill_active_processes
      expect(described_class.active_processes).to be_empty
    end

    it 'swallows errors from a dead pid so interpreter shutdown is never interrupted' do
      stale = instance_double(Process::Waiter, pid: 9999, alive?: true)
      described_class.register_active_process(stale)
      allow(Process).to receive(:kill).with('TERM', 9999).and_raise(Errno::ESRCH)

      expect { described_class.kill_active_processes }.not_to raise_error
      expect(described_class.active_processes).to be_empty
    end

    it 'connect registers the spawned process and close deregisters it' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')
      transport = described_class.new('hi', options)

      # Real StringIOs so the stderr-drain thread (#each_line) and #close work
      # without per-method stubs. alive?: false lets #close skip the wait/kill.
      waiter = instance_double(Process::Waiter, alive?: false)
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3).and_return([StringIO.new, StringIO.new, StringIO.new, waiter])

      transport.connect
      expect(described_class.active_processes).to include(waiter)

      transport.close
      expect(described_class.active_processes).not_to include(waiter)
    end

    it 'deregisters the process when read_messages reaps it, without waiting for #close' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')
      transport = described_class.new('hi', options)

      # read_messages drains stdout to EOF, then reaps via @process.value; the
      # reaped child must drop out of the registry even though #close is never
      # called (e.g. a Client abandoned without #disconnect).
      status = instance_double(Process::Status, exitstatus: 0, signaled?: false)
      waiter = instance_double(Process::Waiter, value: status, alive?: false)
      stdout = StringIO.new(%({"type":"system","subtype":"init"}\n))
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3).and_return([StringIO.new, stdout, StringIO.new, waiter])

      transport.connect
      expect(described_class.active_processes).to include(waiter)

      transport.read_messages { |m| m }
      expect(described_class.active_processes).not_to include(waiter)
    end

    it 'shares one registry across subclasses (constants, not per-class ivars)' do
      subclass = Class.new(described_class)
      waiter = instance_double(Process::Waiter)

      # A class-instance-variable registry would be nil on the subclass, so this
      # would raise NoMethodError on a nil mutex mid-#connect (orphaning the
      # spawned child). Constants resolve up the ancestor chain, so it is shared.
      expect { subclass.register_active_process(waiter) }.not_to raise_error
      expect(subclass.active_processes).to equal(described_class.active_processes)
      expect(described_class.active_processes).to include(waiter)
    end
  end
  describe '#connect — pipe encoding (locale independence)' do
    # popen3 pipes inherit Encoding.default_external (US-ASCII under
    # LANG=C/LC_ALL=C). Instead of mutating the locale, pre-tag real pipe
    # read ends US-ASCII — exactly what popen3 produces under LANG=C —
    # which is deterministic on UTF-8 CI runners.
    def c_locale_pipes
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      stdout_r.set_encoding(Encoding::US_ASCII)
      stderr_r.set_encoding(Encoding::US_ASCII)
      [stdout_r, stdout_w, stderr_r, stderr_w]
    end

    def connect_with_pipes(stdout_r, stderr_r, waiter)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')
      transport = described_class.new('hi', options)
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3).and_return([StringIO.new, stdout_r, stderr_r, waiter])
      transport.connect
      transport
    end

    it 'tags stdout and stderr pipes UTF-8 regardless of the inherited locale encoding' do
      stdout_r, stdout_w, stderr_r, stderr_w = c_locale_pipes
      connect_with_pipes(stdout_r, stderr_r, instance_double(Process::Waiter, alive?: false))

      expect(stdout_r.external_encoding).to eq(Encoding::UTF_8)
      expect(stderr_r.external_encoding).to eq(Encoding::UTF_8)
    ensure
      [stdout_w, stderr_w, stdout_r, stderr_r].each { |io| io&.close unless io&.closed? }
    end

    it 'reads multibyte CLI output through a C-locale-tagged pipe' do
      stdout_r, stdout_w, stderr_r, stderr_w = c_locale_pipes
      status = instance_double(Process::Status, exitstatus: 0, signaled?: false)
      waiter = instance_double(Process::Waiter, alive?: false, value: status)
      transport = connect_with_pipes(stdout_r, stderr_r, waiter)

      stdout_w.write(%({"type":"assistant","message":{"content":[{"type":"text","text":"héllo 好"}]},"session_id":"s1"}\n))
      stdout_w.close
      stderr_w.close

      messages = []
      transport.read_messages { |m| messages << m }

      text = messages.first.dig(:message, :content, 0, :text)
      expect(text).to eq('héllo 好')
      expect(text.encoding).to eq(Encoding::UTF_8)
    ensure
      [stdout_w, stderr_w, stdout_r, stderr_r].each { |io| io&.close unless io&.closed? }
    end

    it 'surfaces multibyte stderr in ProcessError' do
      stdout_r, stdout_w, stderr_r, stderr_w = c_locale_pipes
      status = instance_double(Process::Status, exitstatus: 1, signaled?: false)
      waiter = instance_double(Process::Waiter, alive?: false, value: status)
      transport = connect_with_pipes(stdout_r, stderr_r, waiter)

      stderr_w.write("Fehler: héllo 好\n")
      stdout_w.close
      stderr_w.close

      expect { transport.read_messages { |m| m } }.to raise_error(ClaudeAgentSDK::ProcessError) do |e|
        expect(e.stderr).to include('héllo 好')
        expect(e.stderr.valid_encoding?).to be(true)
        expect(e.stderr.encoding).to eq(Encoding::UTF_8)
      end
    ensure
      [stdout_w, stderr_w, stdout_r, stderr_r].each { |io| io&.close unless io&.closed? }
    end

    it 'still warns about unsupported versions when -v output carries non-ASCII bytes' do
      # Shield from an ambient CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK, which
      # would silently skip the probe and fail the stderr expectation.
      previous_skip = ENV.fetch('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK', nil)
      ENV.delete('CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK')
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude')
      transport = described_class.new('hi', options)
      stdin_r, stdin_w = IO.pipe
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      out_w.binmode
      out_w.write("1.0.0 — héllo\n".b)
      out_r.set_encoding(Encoding::US_ASCII)
      [out_w, err_w, stdin_r].each(&:close)
      waiter = instance_double(Process::Waiter, alive?: false, pid: 4242)
      allow(Open3).to receive(:popen3).and_return([stdin_w, out_r, err_r, waiter])

      expect { transport.check_claude_version }.to output(/unsupported/).to_stderr
    ensure
      ENV['CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK'] = previous_skip if previous_skip
    end
  end
end
