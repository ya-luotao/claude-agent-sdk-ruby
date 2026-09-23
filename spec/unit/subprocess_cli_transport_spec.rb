# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'tmpdir'

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

    # L3: a missing settings file with sandbox set warns and continues with
    # sandbox-only settings (Python parity: logger.warning + empty settings
    # object) instead of raising CLIConnectionError.
    it 'warns and continues with sandbox-only settings when the settings file path does not exist' do
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(
        cli_path: '/usr/bin/claude',
        settings: '/nonexistent/path/settings.json',
        sandbox: ClaudeAgentSDK::SandboxSettings.new(enabled: true)
      )

      transport = described_class.new('hi', options)
      cmd = nil
      expect { cmd = transport.build_command }.to output(/Settings file not found/).to_stderr
      settings_json = cmd[cmd.index('--settings') + 1]
      expect(JSON.parse(settings_json)['sandbox']).to include('enabled' => true)
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

      expect(cmd).to include('--session-id=550e8400-e29b-41d4-a716-446655440000')
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

  describe '#find_cli' do
    # find_cli runs from #initialize, so build the transport WITH a cli_path
    # (skipping discovery) and call the method explicitly.
    subject(:transport) do
      described_class.new('hi', ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))
    end

    let(:tmp_dir) { @tmp_dir }

    around do |example|
      Dir.mktmpdir('find-cli-spec') do |dir|
        @tmp_dir = dir
        example.run
      end
    end

    # Every probe is stubbed by default so the host's real `claude` (and real
    # environment) can never decide the outcome of an ordering example.
    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('CLAUDE_CLI_PATH', nil).and_return(nil)
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:installed_path).and_return(nil)
      allow(Open3).to receive(:capture2).and_call_original
      allow(Open3).to receive(:capture2).with('which', 'claude').and_return(['', nil])
    end

    def executable(name)
      path = File.join(tmp_dir, name)
      File.write(path, "#!/bin/sh\n")
      File.chmod(0o755, path)
      path
    end

    it 'prefers CLAUDE_CLI_PATH over everything else' do
      env_cli = executable('env-claude')
      allow(ENV).to receive(:fetch).with('CLAUDE_CLI_PATH', nil).and_return(env_cli)
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:installed_path).and_return(executable('vendored-claude'))
      allow(Open3).to receive(:capture2).with('which', 'claude').and_return([executable('which-claude'), nil])

      expect(transport.find_cli).to eq(env_cli)
    end

    it 'ignores CLAUDE_CLI_PATH when it does not point at an executable' do
      allow(ENV).to receive(:fetch).with('CLAUDE_CLI_PATH', nil).and_return(File.join(tmp_dir, 'missing'))
      vendored = executable('vendored-claude')
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:installed_path).and_return(vendored)

      expect(transport.find_cli).to eq(vendored)
    end

    it 'absolutizes a relative CLAUDE_CLI_PATH against the current working directory' do
      # The CLI is spawned with `chdir: options.cwd`, where a relative path
      # resolves somewhere else entirely — so find_cli must hand back the
      # absolute path it actually validated.
      executable('rel-claude')
      allow(ENV).to receive(:fetch).with('CLAUDE_CLI_PATH', nil).and_return('rel-claude')
      other_cwd = File.join(tmp_dir, 'elsewhere')
      FileUtils.mkdir_p(other_cwd)
      transport_with_cwd = described_class.new(
        'hi', ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude', cwd: other_cwd)
      )

      Dir.chdir(tmp_dir) do
        expect(transport_with_cwd.find_cli).to eq(File.join(File.realpath(tmp_dir), 'rel-claude'))
      end
    end

    it 'ignores CLAUDE_CLI_PATH pointing at a directory (executable? is true for dirs)' do
      allow(ENV).to receive(:fetch).with('CLAUDE_CLI_PATH', nil).and_return(tmp_dir)
      vendored = executable('vendored-claude')
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:installed_path).and_return(vendored)

      expect(transport.find_cli).to eq(vendored)
    end

    it 'prefers the vendored binary over a `which`-discovered one' do
      vendored = executable('vendored-claude')
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:installed_path).and_return(vendored)
      allow(Open3).to receive(:capture2).with('which', 'claude').and_return([executable('which-claude'), nil])

      expect(transport.find_cli).to eq(vendored)
    end

    it 'falls back to `which` when no override and no vendored binary exist' do
      which_cli = executable('which-claude')
      allow(Open3).to receive(:capture2).with('which', 'claude').and_return(["#{which_cli}\n", nil])

      expect(transport.find_cli).to eq(which_cli)
    end

    it 'tolerates CLIInstaller.installed_path raising' do
      which_cli = executable('which-claude')
      allow(ClaudeAgentSDK::CLIInstaller).to receive(:installed_path).and_raise(Errno::ENOENT)
      allow(Open3).to receive(:capture2).with('which', 'claude').and_return([which_cli, nil])

      expect(transport.find_cli).to eq(which_cli)
    end

    it 'mentions the installer and CLAUDE_CLI_PATH when nothing is found' do
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(a_string_matching(/claude/)).and_return(false)

      expect { transport.find_cli }.to raise_error(
        ClaudeAgentSDK::CLINotFoundError, /CLIInstaller\.install.*CLAUDE_CLI_PATH/m
      )
    end

    context 'with the well-known install locations' do
      around do |example|
        previous_home = ENV.fetch('HOME', nil) # rubocop:disable Style/EnvHome -- raw value; nil when unset
        example.run
      ensure
        previous_home.nil? ? ENV.delete('HOME') : (ENV['HOME'] = previous_home)
      end

      # The one non-home location is host-global; keep the host's real
      # install (if any) from deciding these examples.
      before do
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with('/usr/local/bin/claude').and_return(false)
      end

      def home_install(mode)
        path = File.join(tmp_dir, '.claude', 'local', 'claude')
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#!/bin/sh\n")
        File.chmod(mode, path)
        path
      end

      it 'finds an executable at a home-relative location' do
        ENV['HOME'] = tmp_dir
        path = home_install(0o755)

        expect(transport.find_cli).to eq(path)
      end

      it 'skips a non-executable file so discovery ends in CLINotFoundError (#72)' do
        # Accepting it deferred the failure to spawn as a raw Errno::EACCES,
        # without the install/vendor instructions CLINotFoundError carries.
        ENV['HOME'] = tmp_dir
        home_install(0o644)

        expect { transport.find_cli }.to raise_error(ClaudeAgentSDK::CLINotFoundError)
      end

      it 'skips home-relative locations when the home directory cannot be resolved (#82)' do
        # HOME unset with no passwd entry for the uid (docker --user in a
        # minimal image): Dir.home raises ArgumentError. Stubbed because the
        # host's passwd fallback would otherwise resolve a home.
        ENV.delete('HOME')
        allow(Dir).to receive(:home).and_raise(ArgumentError, "couldn't find home for uid `4242'")

        expect { transport.find_cli }.to raise_error(ClaudeAgentSDK::CLINotFoundError)
      end

      it 'skips home-relative locations when HOME is relative (#82)' do
        # Dir.home returns a relative HOME verbatim; probing under it would
        # validate a path relative to the process cwd and hand back a path the
        # spawn (chdir: options.cwd) resolves somewhere else.
        home_install(0o755)
        ENV['HOME'] = '.'

        Dir.chdir(tmp_dir) do
          expect { transport.find_cli }.to raise_error(ClaudeAgentSDK::CLINotFoundError)
        end
      end
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
      fake_process = instance_double(Process::Waiter, alive?: false, value: instance_double(Process::Status, exitstatus: 0, signaled?: false))
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
      fake_process = instance_double(Process::Waiter, alive?: false, value: instance_double(Process::Status, exitstatus: 0, signaled?: false))
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
      fake_process = instance_double(Process::Waiter, alive?: false, value: status)
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

  describe '#write — cancellation mid-frame poisons the transport (#80)' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }
    # Larger than any pipe buffer (64 KB on Linux and macOS), so a writer with
    # no reader parks INSIDE IO#write with part of the frame already on the
    # pipe — the exact state a cancellation lands in.
    let(:payload) { "{\"type\":\"user\",\"pad\":\"#{'x' * 1_000_000}\"}\n" }

    def wire_pipe(transport, alive: true)
      r, w = IO.pipe
      w.sync = true
      transport.instance_variable_set(:@stdin, w)
      transport.instance_variable_set(:@process, instance_double(Process::Waiter, alive?: alive))
      transport.instance_variable_set(:@ready, true)
      [r, w]
    end

    # Everything currently buffered in the pipe, without blocking.
    def drain(reader)
      bytes = +''
      loop { bytes << reader.read_nonblock(1 << 20) }
    rescue IO::WaitReadable, EOFError
      bytes
    end

    # Async runs a child task until its first suspension point before
    # returning from #async, so the writer is already parked in IO#write on
    # the full pipe when this returns — no sleep needed for ordering.
    def park_reactor_writer(task, transport, payload, caught)
      writer = task.async do
        transport.write(payload)
      rescue Exception => e # rubocop:disable Lint/RescueException -- the cancellation class under test is not a StandardError
        caught << e
        raise
      end
      expect(writer).not_to be_finished
      writer
    end

    it 'marks the transport unusable, re-raises the original cancellation, and fails later writes fast' do
      r, w = wire_pipe(transport)
      caught = []

      Async do |task|
        writer = park_reactor_writer(task, transport, payload, caught)
        writer.stop
        writer.wait

        # The cancellation class itself must propagate (query.rb rescues
        # Async::Stop; converting it would break cancellation), and it is
        # not a StandardError — the old `rescue StandardError` never saw it.
        expect(caught.size).to eq(1)
        expect(caught.first).not_to be_a(StandardError)
        expect(transport.ready?).to be(false)

        # A partial frame really did land: some bytes, but not the whole payload.
        landed = drain(r).bytesize
        expect(landed).to be_between(1, payload.bytesize - 1)

        # Next write from the reactor fails fast without touching the pipe.
        expect { transport.write("{\"type\":\"user\"}\n") }.to raise_error(
          ClaudeAgentSDK::CLIConnectionError,
          /interrupted by #{Regexp.escape(caught.first.class.name)}.*partial frame/
        )
        expect(drain(r)).to be_empty
      ensure
        writer&.stop
      end.wait

      # ...and from a FiberBoundary-style plain thread.
      from_thread = Thread.new do
        transport.write("{\"type\":\"user\"}\n")
      rescue StandardError => e
        e
      end.value
      expect(from_thread).to be_a(ClaudeAgentSDK::CLIConnectionError)
      expect(from_thread.message).to match(/possible partial frame/)
      expect(drain(r)).to be_empty
    ensure
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    it 'poisons on a cooperative inline timeout (InlineCancellation) and still surfaces the timeout' do
      r, w = wire_pipe(transport)
      expired = -> { ClaudeAgentSDK::FiberBoundary::JoinTimeout.new('write timed out') }

      Async do |task|
        expect do
          ClaudeAgentSDK::FiberBoundary.with_cooperative_timeout(task, 0.05, on_timeout: expired) do
            transport.write(payload)
          end
        end.to raise_error(ClaudeAgentSDK::FiberBoundary::JoinTimeout)

        expect(transport.ready?).to be(false)
        expect(drain(r).bytesize).to be_between(1, payload.bytesize - 1)
        expect { transport.write("{}\n") }.to raise_error(
          ClaudeAgentSDK::CLIConnectionError,
          /interrupted by ClaudeAgentSDK::FiberBoundary::InlineCancellation: possible partial frame/
        )
      end.wait
    ensure
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    it 'still converts ordinary IO failures into CLIConnectionError' do
      r, w = wire_pipe(transport)
      w.close

      expect { transport.write("{}\n") }.to raise_error(ClaudeAgentSDK::CLIConnectionError, /Failed to write to process stdin/)
      expect(transport.ready?).to be(false)
    ensure
      r&.close unless r&.closed?
    end

    it 'leaves no in-flight writer registered after a completed write' do
      r, w = wire_pipe(transport)
      transport.write("{}\n")

      expect(transport.instance_variable_get(:@inflight_writers)).to be_empty
      expect(drain(r)).to eq("{}\n")
    ensure
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    it 'keeps concurrent frames from fibers and a thread intact on a lagging reader' do
      # Guards the CRuby property the fix relies on (IO#write is call-atomic
      # on a sync IO), so poisoning only has to handle cancellation.
      r, w = wire_pipe(transport)
      frames = Array.new(3) { |i| "{\"id\":#{i},\"pad\":\"#{i.to_s * 300_000}\"}\n" }
      lines = Queue.new
      reader = Thread.new { 3.times { lines << r.gets } }

      thread_writer = Thread.new { transport.write(frames[2]) }
      Async do |task|
        frames.first(2).map { |frame| task.async { transport.write(frame) } }.each(&:wait)
      end.wait
      thread_writer.join
      reader.join

      received = Array.new(3) { lines.pop }
      expect(received).to match_array(frames)
    ensure
      [r, w].each { |io| io&.close unless io&.closed? } # unblocks any straggler below
      thread_writer&.join(5)
      reader&.join(5)
    end
  end

  describe 'stdin shutdown with a writer parked mid-frame (#80)' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }
    let(:payload) { "{\"pad\":\"#{'x' * 1_000_000}\"}\n" }
    # Deadline for the shutdown call itself. Not a StandardError: the old
    # close/end_input paths `rescue StandardError` around IO#close, so an
    # Async::TimeoutError there was swallowed and a hang looked like a pass.
    let(:hang) { Class.new(Exception) } # rubocop:disable Lint/InheritException

    # The child looks alive while the writer starts (write refuses a dead
    # process) and exited once close runs, so teardown skips the grace wait.
    def wire_pipe(transport)
      r, w = IO.pipe
      w.sync = true
      alive = true
      waiter = instance_double(Process::Waiter)
      allow(waiter).to receive(:alive?) { alive }
      transport.instance_variable_set(:@stdin, w)
      transport.instance_variable_set(:@process, waiter)
      transport.instance_variable_set(:@ready, true)
      [r, w, -> { alive = false }]
    end

    # Async runs a child task until its first suspension point before
    # returning from #async, so the writer is parked in IO#write on the full
    # pipe (the payload exceeds any pipe buffer) when this returns.
    def park_fiber_writer(task, transport, payload, caught)
      writer = task.async do
        transport.write(payload)
      rescue Exception => e # rubocop:disable Lint/RescueException -- whatever wakes it is under test
        caught << e
      end
      expect(writer).not_to be_finished
      writer
    end

    # A FiberBoundary-worker-style plain thread parked in IO#write. Gated on
    # a status condition, not a timer: the only place the writer can block
    # is the fd wait on the full pipe (the stdin lock is uncontended).
    def park_thread_writer(transport, payload, outcome)
      writer = Thread.new do
        transport.write(payload)
        outcome << :completed
      rescue StandardError => e
        outcome << e
      end
      Thread.pass until !writer.alive? || writer.status == 'sleep'
      expect(writer).to be_alive
      writer
    end

    def expect_woken_with_connection_error(writer, caught)
      expect(writer).to be_finished
      expect(caught.size).to eq(1)
      expect(caught.first).to be_a(ClaudeAgentSDK::CLIConnectionError)
      expect(caught.first.message).to include('stdin closed while a write was in progress')
    end

    it '#close wakes a reactor writer parked in IO#write with the documented CLIConnectionError' do
      r, w, child_exited = wire_pipe(transport)
      caught = []

      Async do |task|
        writer = park_fiber_writer(task, transport, payload, caught)

        # Closing the fd does NOT wake a fiber parked in write on the async
        # selector (probed on Ruby 3.2/3.3/3.4) — close has to wake it. The
        # writer gets an IOError like a thread writer would, not Async::Stop:
        # its task (possibly the caller's own) is not cancelled.
        child_exited.call
        task.with_timeout(5, hang) { transport.close }

        expect_woken_with_connection_error(writer, caught)
        expect(w).to be_closed
        expect(transport.instance_variable_get(:@stdin)).to be_nil
        expect(transport.instance_variable_get(:@inflight_writers)).to be_empty
      ensure
        writer&.stop
      end.wait
    ensure
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    # Two fiber writers: the second is queued on IO#write's internal lock
    # behind the first. Waking the lock holder first let its unlock schedule
    # the queued writer (scheduler.unblock); after that writer was woken and
    # unwound, the stale wakeup cut its NEXT suspension short. A sleep
    # after the error exposes it (only a lower bound is asserted, so a slow
    # runner can't make this flaky).
    it '#end_input wakes queued fiber writers without leaving a stale wakeup behind' do
      r, w, = wire_pipe(transport)
      caught = []
      after_error = []

      Async do |task|
        first = park_fiber_writer(task, transport, payload, caught)
        second = task.async do
          transport.write(payload)
        rescue ClaudeAgentSDK::CLIConnectionError => e
          caught << e
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          sleep 0.3
          after_error << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        end
        expect(second).not_to be_finished

        task.with_timeout(5, hang) { transport.end_input }
        second.wait

        expect(first).to be_finished
        expect(caught.size).to eq(2)
        expect(caught).to all(be_a(ClaudeAgentSDK::CLIConnectionError))
        expect(after_error.size).to eq(1)
        expect(after_error.first).to be >= 0.25
      ensure
        first&.stop
        second&.stop
      end.wait
    ensure
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    it '#close returns on the reactor while a plain (FiberBoundary worker) thread is parked in IO#write' do
      r, w, child_exited = wire_pipe(transport)
      outcome = Queue.new
      writer = park_thread_writer(transport, payload, outcome)

      # On Ruby 3.3+/3.4 a reactor-side IO#close waits for threads blocked on
      # the fd via a scheduler sleep the writer's wakeup never resumes —
      # close hung the reactor forever. It must return and unblock the writer.
      child_exited.call
      Async do |task|
        task.with_timeout(5, hang) { transport.close }
      end.wait

      expect(outcome.pop).to be_a(ClaudeAgentSDK::CLIConnectionError)
      expect(w).to be_closed
    ensure
      writer&.join(5)
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    it '#end_input returns on the reactor while a plain thread is parked in IO#write' do
      r, w, = wire_pipe(transport)
      outcome = Queue.new
      writer = park_thread_writer(transport, payload, outcome)

      Async do |task|
        task.with_timeout(5, hang) { transport.end_input }
      end.wait

      expect(outcome.pop).to be_a(ClaudeAgentSDK::CLIConnectionError)
      expect(w).to be_closed
      expect(transport.instance_variable_get(:@stdin)).to be_nil
    ensure
      writer&.join(5)
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    it '#end_input wakes a reactor writer parked in IO#write' do
      r, w, = wire_pipe(transport)
      caught = []

      Async do |task|
        writer = park_fiber_writer(task, transport, payload, caught)
        task.with_timeout(5, hang) { transport.end_input }

        expect_woken_with_connection_error(writer, caught)
        expect(w).to be_closed
      ensure
        writer&.stop
      end.wait
    ensure
      [r, w].each { |io| io&.close unless io&.closed? }
    end

    context 'when the close itself is cancelled before its stdin step' do
      # Cancellation landing in teardown's first suspension point (the
      # stderr-drain join) — #close's ensure must still release the writer.
      before do
        allow(transport).to receive(:teardown_process).and_raise(Async::Stop, 'close cancelled')
      end

      it 'wakes a parked reactor writer and closes stdin from the ensure' do
        r, w, child_exited = wire_pipe(transport)
        caught = []

        Async do |task|
          writer = park_fiber_writer(task, transport, payload, caught)
          child_exited.call
          expect { transport.close }.to raise_error(Async::Stop)

          expect_woken_with_connection_error(writer, caught)
          expect(w).to be_closed
        ensure
          writer&.stop
        end.wait
      ensure
        [r, w].each { |io| io&.close unless io&.closed? }
      end

      it 'does not block on a parked plain-thread writer, and still unblocks it' do
        r, w, child_exited = wire_pipe(transport)
        outcome = Queue.new
        writer = park_thread_writer(transport, payload, outcome)
        child_exited.call

        Async do |task|
          task.with_timeout(5, hang) do
            expect { transport.close }.to raise_error(Async::Stop)
          end
        end.wait

        # The detached helper's close interrupts the writer.
        expect(outcome.pop).to be_a(ClaudeAgentSDK::CLIConnectionError)
      ensure
        writer&.join(5)
        [r, w].each { |io| io&.close unless io&.closed? }
      end
    end
  end

  describe '#read_messages — bounded wait for exit after stdout EOF (#73)' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    before do
      stub_const("#{described_class}::EOF_EXIT_GRACE_SECONDS", 0.2)
      stub_const("#{described_class}::EOF_TERM_GRACE_SECONDS", 0.2)
    end

    # A real child that releases its stdout (EOF for the reader) and then
    # keeps running — the pathological CLI the bound exists for. reopen, not
    # close: IO#close on fd 0-2 leaves the kernel descriptor open. +prelude+
    # runs BEFORE the reopen: the grace period starts at EOF, so setup such
    # as a TERM trap must already be in place on a slow runner.
    def spawn_child(script, prelude: '')
      stdin, stdout, stderr, waiter = Open3.popen3(
        RbConfig.ruby, '--disable-gems', '-e', "#{prelude}STDOUT.reopen(File::NULL); #{script}"
      )
      stdin.close
      transport.instance_variable_set(:@stdout, stdout)
      transport.instance_variable_set(:@process, waiter)
      # As #connect does, so the forced-exit path's deregistration is observable.
      described_class.register_active_process(waiter)
      [stdout, stderr, waiter]
    end

    # Runs read_messages on a thread so an unbounded wait (the bug) fails the
    # example instead of hanging the suite; the value is the raised error.
    def read_to_end(transport)
      @runner = Thread.new do
        transport.read_messages { |m| m }
        nil
      rescue StandardError => e
        e
      end
      expect(@runner.join(10)).not_to be_nil, 'read_messages never returned after stdout EOF'
      @runner.value
    end

    def reap(stdout, stderr, waiter)
      if waiter&.alive?
        begin
          Process.kill('KILL', waiter.pid)
        rescue StandardError
          nil
        end
      end
      waiter&.join(5)
      @runner&.join(5)
      [stdout, stderr].each { |io| io&.close unless io&.closed? }
    end

    it 'escalates TERM then KILL for a child that ignores TERM, surfacing a ProcessError like the signal path' do
      stdout, stderr, waiter = spawn_child('sleep', prelude: 'trap("TERM") {}; ')

      error = read_to_end(transport)
      expect(error).to be_a(ClaudeAgentSDK::ProcessError)
      expect(error.exit_code).to eq(-9)
      expect(error.message).to include('did not exit within 0.2s of closing stdout')
      expect(waiter).not_to be_alive
      expect(described_class.active_processes).not_to include(waiter)
    ensure
      reap(stdout, stderr, waiter)
    end

    it 'TERMs a child that keeps running after stdout EOF and reports the signal' do
      stdout, stderr, waiter = spawn_child('sleep')

      error = read_to_end(transport)
      expect(error).to be_a(ClaudeAgentSDK::ProcessError)
      expect(error.exit_code).to eq(-15)
      expect(waiter).not_to be_alive
    ensure
      reap(stdout, stderr, waiter)
    end

    it 'waits without blocking the reactor when the read loop runs in a task' do
      stdout, stderr, waiter = spawn_child('sleep')
      ticks = 0

      error = nil
      Async do |task|
        ticker = task.async do
          loop do
            ticks += 1
            task.yield
          end
        end
        task.with_timeout(10) do
          transport.read_messages { |m| m }
        rescue ClaudeAgentSDK::ProcessError => e
          error = e
        end
      ensure
        ticker&.stop
      end.wait

      expect(error&.exit_code).to eq(-15)
      expect(ticks).to be > 1
    ensure
      reap(stdout, stderr, waiter)
    end

    # A child stuck in uninterruptible kernel I/O survives even KILL: the last
    # wait is bounded too, and the unreaped child stays in the at-exit
    # registry instead of read_messages blocking forever on #value.
    it 'raises instead of blocking when the child cannot be reaped even after KILL' do
      waiter = instance_double(Process::Waiter, pid: 4242, alive?: true)
      expect(waiter).not_to receive(:value)
      allow(Process).to receive(:kill)
      transport.instance_variable_set(:@stdout, StringIO.new(''))
      transport.instance_variable_set(:@process, waiter)
      described_class.register_active_process(waiter)

      error = read_to_end(transport)

      expect(error).to be_a(ClaudeAgentSDK::ProcessError)
      expect(error.message).to include('could not be reaped even after SIGKILL')
      expect(Process).to have_received(:kill).with('TERM', 4242)
      expect(Process).to have_received(:kill).with('KILL', 4242)
      expect(described_class.active_processes).to include(waiter)
    ensure
      described_class.deregister_active_process(waiter)
    end

    it 'does not signal a child that exits on its own within the grace period' do
      # A generous grace here: interpreter exit + reap must fit inside it even
      # on a slow CI runner, or the example would signal a healthy child.
      stub_const("#{described_class}::EOF_EXIT_GRACE_SECONDS", 5)
      expect(Process).not_to receive(:kill)
      stdout, stderr, waiter = spawn_child('exit 0')

      expect(read_to_end(transport)).to be_nil
    ensure
      reap(stdout, stderr, waiter)
    end
  end

  describe '#read_messages — truncated final frame at clean EOF (#89)' do
    let(:options) { ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude') }
    let(:transport) { described_class.new('hi', options) }

    def wire(stdout)
      status = instance_double(Process::Status, exitstatus: 0, signaled?: false)
      stdout = StringIO.new(stdout) if stdout.is_a?(String)
      transport.instance_variable_set(:@stdout, stdout)
      transport.instance_variable_set(:@process, instance_double(Process::Waiter, alive?: false, value: status))
    end

    it 'raises CLIJSONDecodeError for a newline-less partial frame after delivering the complete ones' do
      wire("{\"type\":\"system\"}\n{\"type\":\"result\",\"sub")

      messages = []
      expect { transport.read_messages { |m| messages << m } }
        .to raise_error(ClaudeAgentSDK::CLIJSONDecodeError) do |e|
          expect(e.line).to eq('{"type":"result","sub')
          expect(e.original_error.message).to include('without a terminating newline')
        end
      expect(messages.map { |m| m[:type] }).to eq(['system'])
    end

    it 'still delivers a complete final frame that lacks its trailing newline' do
      wire("{\"type\":\"system\"}\n{\"type\":\"result\"}")

      messages = []
      expect { transport.read_messages { |m| messages << m } }.not_to raise_error
      expect(messages.map { |m| m[:type] }).to eq(%w[system result])
    end

    it 'ignores whitespace-only trailing bytes' do
      wire("{\"type\":\"system\"}\n  \n\t ")

      messages = []
      expect { transport.read_messages { |m| messages << m } }.not_to raise_error
      expect(messages.map { |m| m[:type] }).to eq(['system'])
    end

    it 'stays silent when close() cuts the read short mid-frame' do
      stdout = instance_double(IO)
      allow(stdout).to receive(:each_line) do |*_args, &blk|
        blk.call('{"type":"result","sub')
        raise IOError, 'stream closed in another thread'
      end
      wire(stdout)

      expect { transport.read_messages { |m| m } }.not_to raise_error
    end

    it 'prefers the process exit error when the CLI died mid-frame' do
      status = instance_double(Process::Status, exitstatus: nil, signaled?: true, termsig: 9)
      transport.instance_variable_set(:@stdout, StringIO.new('{"type":"result","sub'))
      transport.instance_variable_set(:@process, instance_double(Process::Waiter, alive?: false, value: status))

      expect { transport.read_messages { |m| m } }.to raise_error(ClaudeAgentSDK::ProcessError)
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
      waiter = instance_double(Process::Waiter, alive?: false)
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

  describe '#close — cancellation safety (Python #1082 parity)' do
    def bare_transport
      described_class.new('hi', ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude'))
    end

    [false, true].each do |ignore_term|
      it "deregisters a reaped fallback child (ignores TERM: #{ignore_term})" do
        script = "#{"trap('TERM', 'IGNORE');" if ignore_term} STDOUT.sync = true; puts 'ready'; sleep 60"
        stdin, stdout, stderr, waiter = Open3.popen3(RbConfig.ruby, '-e', script)
        expect(stdout.gets).to eq("ready\n")
        described_class.register_active_process(waiter)

        worker = bare_transport.force_terminate_in_background(waiter, grace_seconds: 0.05)
        expect(worker.join(2)).not_to be_nil
        expect(waiter.join(1)).not_to be_nil
        expect(waiter.value.termsig).to eq(Signal.list.fetch(ignore_term ? 'KILL' : 'TERM'))
        expect(described_class.active_processes).not_to include(waiter)
      ensure
        # Always reap real children and join workers before the test ends,
        # including when an assertion fails on the unfixed implementation.
        Process.kill('KILL', waiter.pid) if waiter&.alive?
        waiter&.join
        worker&.join
        [stdin, stdout, stderr].each { |io| io&.close }
      end
    end

    it 'deregisters a child already reaped before fallback begins' do
      waiter = instance_double(Process::Waiter, alive?: false)
      described_class.register_active_process(waiter)
      expect(Process).not_to receive(:kill)
      expect(bare_transport.force_terminate_in_background(waiter)).to be_nil
      expect(described_class.active_processes).not_to include(waiter)
    end

    %i[stderr grace reap].each do |phase|
      it "preserves an outer Async timeout during #{phase} and retains fallback ownership" do
        transport = bare_transport
        waiter = instance_double(Process::Waiter, pid: 4242, alive?: true)
        transport.instance_variable_set(:@process, waiter)
        described_class.register_active_process(waiter)
        # Exercise the real close/teardown boundary without leaving a delayed
        # termination worker holding mocks after the example ends.
        expect(transport).to receive(:force_terminate_in_background).with(waiter)

        Async do |task|
          case phase
          when :stderr
            stderr_task = instance_double(Thread, alive?: true, kill: nil)
            allow(stderr_task).to receive(:join) { task.sleep(10) }
            transport.instance_variable_set(:@stderr_task, stderr_task)
            allow(transport).to receive(:wait_process_with_timeout).and_raise(Async::TimeoutError)
          when :grace
            allow(transport).to receive(:wait_process_with_timeout) { task.sleep(10) }
          when :reap
            allow(transport).to receive(:wait_process_with_timeout).and_raise(Timeout::Error)
            allow(Process).to receive(:kill)
            allow(waiter).to receive(:value) { task.sleep(10) }
          end

          expect { task.with_timeout(0.01) { transport.close } }.to raise_error(Async::TimeoutError)
        end.wait

        expect(described_class.active_processes).to include(waiter)
        expect(transport.instance_variable_get(:@process)).to be_nil
      end
    end

    it 'still TERMs the child when cancellation interrupts the graceful teardown' do
      waiter = instance_double(Process::Waiter, pid: 4242, alive?: true, join: nil)
      transport = bare_transport
      stdin_io = StringIO.new
      stdout_io = StringIO.new
      stderr_io = StringIO.new
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3).and_return([stdin_io, stdout_io, stderr_io, waiter])
      transport.connect

      # Async::Stop at any of teardown's suspension points (task sleep,
      # thread join) abandons the TERM -> KILL escalation; the ensure must
      # still terminate the child. Own and join the worker before mocks expire.
      signals = Queue.new
      allow(Process).to receive(:kill) { |sig, pid| signals << [sig, pid] }
      allow(transport).to receive(:teardown_process).and_raise(Async::Stop)
      worker = nil
      allow(transport).to receive(:force_terminate_in_background).and_wrap_original do |original, process|
        worker = original.call(process, grace_seconds: 0.01)
      end

      expect { transport.close }.to raise_error(Async::Stop)
      expect(signals.pop).to eq(['TERM', 4242])
      # This stub never finishes reaping, so it must retain the safety net.
      expect(described_class.active_processes).to include(waiter)
      expect(transport.instance_variable_get(:@process)).to be_nil

      # The pipes must not leak either: with @process nil a repeat #close
      # returns immediately, and the transport object itself may live on, so
      # the ensure has to both close the IOs and drop the references.
      expect(stdin_io).to be_closed
      expect(stdout_io).to be_closed
      expect(stderr_io).to be_closed
      expect(transport.instance_variable_get(:@stdin)).to be_nil
      expect(transport.instance_variable_get(:@stdout)).to be_nil
      expect(transport.instance_variable_get(:@stderr)).to be_nil
    ensure
      worker&.join
    end

    it 'escalates to KILL but retains ownership when the bounded reap does not finish' do
      waiter = instance_double(Process::Waiter, pid: 4243, alive?: true, join: nil)
      described_class.register_active_process(waiter)
      signals = Queue.new
      allow(Process).to receive(:kill) { |sig, pid| signals << [sig, pid] }

      thread = bare_transport.force_terminate_in_background(waiter, grace_seconds: 0.01)

      expect(signals.pop).to eq(['TERM', 4243])
      thread.join
      expect(signals.pop).to eq(['KILL', 4243])
      expect(described_class.active_processes).to include(waiter)
    ensure
      thread&.join
    end

    %w[TERM KILL].each do |signal|
      it "reaps and deregisters when exit races #{signal}" do
        alive = true
        waiter = instance_double(Process::Waiter, pid: 4244)
        allow(waiter).to receive(:alive?) { alive }
        joins = signal == 'TERM' ? 0 : 1
        allow(waiter).to receive(:join) do
          if joins.positive?
            joins -= 1
            nil
          else
            alive = false
            waiter
          end
        end
        described_class.register_active_process(waiter)
        allow(Process).to receive(:kill)
        allow(Process).to receive(:kill).with(signal, 4244).and_raise(Errno::ESRCH)

        thread = bare_transport.force_terminate_in_background(waiter, grace_seconds: 0.01)
        thread.join
        expect(described_class.active_processes).not_to include(waiter)
      ensure
        thread&.join
      end
    end

    it 'is a no-op for a nil or already-dead process' do
      expect(Process).not_to receive(:kill)
      transport = bare_transport
      expect(transport.force_terminate_in_background(nil)).to be_nil
      expect(transport.force_terminate_in_background(instance_double(Process::Waiter, alive?: false))).to be_nil
    end

    it 'retains ownership without spawning the KILL thread when TERM is not permitted' do
      waiter = instance_double(Process::Waiter, pid: 4245, alive?: true)
      described_class.register_active_process(waiter)
      allow(Process).to receive(:kill).with('TERM', 4245).and_raise(Errno::EPERM)

      expect(bare_transport.force_terminate_in_background(waiter)).to be_nil
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

    # #90: stdout frames and the version probe are scrubbed; stderr must be
    # too, or invalid bytes reach user callbacks and ProcessError#stderr and
    # blow up later encoding work (JSON generation in loggers/exporters).
    it 'scrubs invalid UTF-8 on the drained stderr before it reaches ProcessError' do
      stdout_r, stdout_w, stderr_r, stderr_w = c_locale_pipes
      status = instance_double(Process::Status, exitstatus: 1, signaled?: false)
      waiter = instance_double(Process::Waiter, alive?: false, value: status)
      transport = connect_with_pipes(stdout_r, stderr_r, waiter)

      stderr_w.write("bad \xFF\xFE bytes\n".b)
      stdout_w.close
      stderr_w.close

      expect { transport.read_messages { |m| m } }.to raise_error(ClaudeAgentSDK::ProcessError) do |e|
        expect(e.stderr).to include('bad ', ' bytes')
        expect(e.stderr.valid_encoding?).to be(true)
        expect(e.message.valid_encoding?).to be(true)
      end
    ensure
      [stdout_w, stderr_w, stdout_r, stderr_r].each { |io| io&.close unless io&.closed? }
    end

    it 'scrubs invalid UTF-8 before the stderr callback and ProcessError see it' do
      stdout_r, stdout_w, stderr_r, stderr_w = c_locale_pipes
      status = instance_double(Process::Status, exitstatus: 1, signaled?: false)
      waiter = instance_double(Process::Waiter, alive?: false, value: status)
      lines = Queue.new
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(cli_path: '/usr/bin/claude', stderr: ->(line) { lines << line })
      transport = described_class.new('hi', options)
      allow(transport).to receive(:check_claude_version)
      allow(Open3).to receive(:popen3).and_return([StringIO.new, stdout_r, stderr_r, waiter])
      transport.connect

      stderr_w.write("bad \xFF\xFE bytes\n".b)
      stderr_w.close
      line = lines.pop(timeout: 5) # the callback ran: the stderr thread consumed the line
      stdout_w.close

      expect(line).to include('bad ', ' bytes')
      expect(line.valid_encoding?).to be(true)
      expect { transport.read_messages { |m| m } }.to raise_error(ClaudeAgentSDK::ProcessError) do |e|
        expect(e.stderr.valid_encoding?).to be(true)
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
