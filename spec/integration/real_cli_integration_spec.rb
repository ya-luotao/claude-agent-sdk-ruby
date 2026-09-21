# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'tmpdir'

RSpec.describe 'Real Claude CLI Integration', :integration do
  # Gated by RUN_INTEGRATION (see spec_helper.rb). These spawn the real `claude`
  # CLI and make live, budget-capped API calls, so they self-skip when the CLI is
  # not on PATH or no ANTHROPIC_API_KEY is set — RUN_INTEGRATION=1 stays green on
  # a machine without the CLI or credentials.
  before do
    skip 'Claude CLI is not available on PATH' unless system('command -v claude >/dev/null 2>&1')
    skip 'ANTHROPIC_API_KEY is required for real CLI integration tests' if ENV['ANTHROPIC_API_KEY'].to_s.empty?
  end

  def run_one_shot_query(prompt:, options:)
    seen_result = nil

    ClaudeAgentSDK.query(prompt: prompt, options: options) do |message|
      seen_result = message if message.is_a?(ClaudeAgentSDK::ResultMessage)
    end

    expect(seen_result).to be_a(ClaudeAgentSDK::ResultMessage)
    expect(seen_result.is_error).to eq(false)
    seen_result
  end

  it 'completes a minimal one-shot query through Claude CLI' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      max_turns: 1,
      max_budget_usd: 0.02,
      tools: []
    )

    run_one_shot_query(prompt: 'Reply with exactly: OK', options: options)
  end

  it 'invokes PreToolUse hooks for one-shot query() calls through Claude CLI' do
    hook_invocations = []
    hook_fn = lambda do |input, tool_use_id, _context|
      hook_invocations << {
        hook_event_name: input.hook_event_name,
        tool_name: input.tool_name,
        tool_use_id: input.tool_use_id || tool_use_id
      }
      {}
    end

    matcher = ClaudeAgentSDK::HookMatcher.new(
      matcher: 'Bash',
      hooks: [hook_fn]
    )

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code'),
      permission_mode: 'bypassPermissions',
      allowed_tools: ['Bash'],
      tools: ['Bash'],
      max_turns: 3,
      max_budget_usd: 0.05,
      hooks: { 'PreToolUse' => [matcher] }
    )

    run_one_shot_query(
      prompt: "Use the Bash tool exactly once to run: printf 'ruby-hook-test'. After the command completes, reply with exactly HOOK_OK.",
      options: options
    )

    expect(hook_invocations).not_to be_empty
    expect(hook_invocations.any? { |invocation| invocation[:tool_name] == 'Bash' }).to eq(true)
    expect(hook_invocations.any? { |invocation| invocation[:tool_use_id] }).to eq(true)
  end

  it 'invokes SDK MCP tools for one-shot query() calls through Claude CLI' do
    executions = []

    echo_tool = ClaudeAgentSDK.create_tool('echo', 'Echo back the provided text', { text: :string }) do |args|
      executions << args
      { content: [{ type: 'text', text: "Echo: #{args[:text]}" }] }
    end

    server = ClaudeAgentSDK.create_sdk_mcp_server(
      name: 'test',
      version: '1.0.0',
      tools: [echo_tool]
    )

    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      system_prompt: ClaudeAgentSDK::SystemPromptPreset.new(preset: 'claude_code'),
      permission_mode: 'bypassPermissions',
      max_turns: 3,
      max_budget_usd: 0.05,
      mcp_servers: { test: server },
      allowed_tools: ['mcp__test__echo']
    )

    run_one_shot_query(
      prompt: "Call the mcp__test__echo tool once with text 'ruby real cli mcp'. After the tool returns, reply with exactly MCP_OK.",
      options: options
    )

    expect(executions).not_to be_empty
    expect(executions.first[:text]).to eq('ruby real cli mcp')
  end

  # can_use_tool is served over the control protocol: the CLI writes the
  # permission request to stdout and blocks until the verdict comes back on
  # stdin. Both of these fail against the real CLI without the stdin-lifecycle
  # fix — a String prompt used to be refused outright, and an Enumerator
  # prompt closed stdin when its input ran out, so the CLI reported
  # "Stream closed". permission_mode 'default' keeps the ladder on "ask" so
  # the callback is actually consulted regardless of the host's settings.
  describe 'can_use_tool over the control protocol' do
    def permission_options(cwd)
      ClaudeAgentSDK::ClaudeAgentOptions.new(
        can_use_tool: @callback,
        cwd: cwd,
        permission_mode: 'default',
        max_turns: 10,
        max_budget_usd: 0.5
      )
    end

    before do
      @granted = []
      @callback = lambda do |tool_name, _input, _context|
        @granted << tool_name
        ClaudeAgentSDK::PermissionResultAllow.new
      end
    end

    # The invariant, independent of which tool the model reaches for: the CLI
    # asked for permission at least once (so the control_request arrived),
    # and the run still reached a non-error result (asserted by
    # run_one_shot_query) — which it cannot do if the verdict never got back
    # over stdin, since the CLI then fails the tool call with "Stream closed".
    # Whether the file lands is up to the model and deliberately not asserted;
    # the unit specs pin the exact wire exchange.
    def expect_permission_round_trip
      expect(@granted).not_to be_empty, 'expected the CLI to ask can_use_tool at least once'
    end

    it 'answers the permission request for a String prompt' do
      Dir.mktmpdir('cas-permission') do |dir|
        run_one_shot_query(
          prompt: 'Create a file named ok.txt containing exactly: hello',
          options: permission_options(dir)
        )

        expect_permission_round_trip
      end
    end

    it 'answers the permission request for an Enumerator prompt' do
      Dir.mktmpdir('cas-permission') do |dir|
        prompt = ClaudeAgentSDK::Streaming.from_array(
          ['Create a file named ok.txt containing exactly: hello']
        )

        run_one_shot_query(prompt: prompt, options: permission_options(dir))

        expect_permission_round_trip
      end
    end
  end

  # A run that trips a terminal guard ends with an is_error result followed by
  # a deliberate non-zero exit; the SDK must surface that as a typed
  # ResultError carrying the CLI's own text, not a bare "exit code 1". The
  # budget cap is the cheapest deterministic trigger — it fires on the very
  # first turn, so this costs a cent and never depends on how many turns the
  # model chooses to take.
  it 'raises a typed ResultError when the CLI exits after an error result' do
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      permission_mode: 'bypassPermissions',
      max_budget_usd: 0.01
    )

    error = nil
    begin
      ClaudeAgentSDK.query(
        prompt: 'Run `ls` with the Bash tool, then summarize what you saw.',
        options: options
      ) { |_message| nil }
    rescue ClaudeAgentSDK::ResultError => e
      error = e
    end

    expect(error).to be_a(ClaudeAgentSDK::ResultError)
    expect(error).to be_a(ClaudeAgentSDK::ProcessError)
    expect(error.message).to include('Claude Code returned an error result:')
    expect(error.message).not_to include('error result: success')
    expect(error.subtype).to eq('error_max_budget_usd')
    expect(error.errors).not_to be_empty
    expect(error.exit_code).to eq(1)
    expect(error.original_error).to be_a(ClaudeAgentSDK::ProcessError)
  end

  it 'initializes Client and returns server info' do
    Async do
      client = ClaudeAgentSDK::Client.new
      begin
        client.connect
        info = client.get_server_info

        expect(info).to be_a(Hash)
        expect(info).not_to eq({})
      ensure
        client.disconnect
      end
    end.wait
  end

  describe 'subagent contracts' do
    # Keep CLI settings/transcripts disposable and let the public disk reader
    # resolve the same config directory as the subprocess. No auth is copied.
    around do |example|
      previous_config_dir = ENV.fetch('CLAUDE_CONFIG_DIR', nil)
      Dir.mktmpdir('cas-subagents') do |directory|
        @project_dir = File.join(directory, 'project')
        FileUtils.mkdir_p(@project_dir)
        ENV['CLAUDE_CONFIG_DIR'] = File.join(directory, 'config')
        example.run
      end
    ensure
      if previous_config_dir
        ENV['CLAUDE_CONFIG_DIR'] = previous_config_dir
      else
        ENV.delete('CLAUDE_CONFIG_DIR')
      end
    end

    def subagent_options(**overrides)
      ClaudeAgentSDK::ClaudeAgentOptions.new(
        cwd: @project_dir, setting_sources: [], tools: ['Agent'], allowed_tools: ['Agent'],
        max_turns: 8, max_budget_usd: 0.5, forward_subagent_text: true, **overrides
      )
    end

    it 'correlates two foreground agents, forwarded text, and disk metadata without equating IDs' do
      inputs = []
      hook = lambda do |input, _tool_id, _context|
        inputs << input
        {}
      end
      agents = %w[alpha beta].to_h do |name|
        [name, ClaudeAgentSDK::AgentDefinition.new(description: "The #{name} reporter",
                                                   prompt: "Reply with exactly: #{name.upcase}_REPORT", tools: [])]
      end
      options = subagent_options(
        agents: agents,
        hooks: %w[SubagentStart SubagentStop].to_h do |event|
          [event, [ClaudeAgentSDK::HookMatcher.new(hooks: [hook])]]
        end
      )
      messages = []
      Async do |task|
        client = ClaudeAgentSDK::Client.new(options: options)
        begin
          task.with_timeout(120) do
            client.connect
            client.query('Call alpha and beta once each as foreground agents, not in the background. ' \
                         'Ask each for its report, then summarize both reports.')
            client.receive_response { |message| messages << message }
          end
        ensure
          client.disconnect
        end
      end.wait

      result = messages.grep(ClaudeAgentSDK::ResultMessage).last
      expect(result).not_to be_nil
      expect(result.is_error).to be false
      starts = inputs.grep(ClaudeAgentSDK::SubagentStartHookInput)
      stops = inputs.grep(ClaudeAgentSDK::SubagentStopHookInput)
      expect(starts.map(&:agent_type)).to contain_exactly('alpha', 'beta')
      expect(starts.map(&:agent_id).uniq.size).to eq(2)
      expect(stops.map(&:agent_id)).to match_array(starts.map(&:agent_id))
      parent_calls = messages.grep(ClaudeAgentSDK::AssistantMessage)
                             .select { |message| message.parent_tool_use_id.nil? }
                             .flat_map(&:content).grep(ClaudeAgentSDK::ToolUseBlock)
                             .select { |block| block.name == 'Agent' }.map(&:id)
      tool_ids = starts.map do |input|
        expect(input.session_id).to eq(result.session_id)
        metadata = ClaudeAgentSDK.get_subagent_metadata(session_id: result.session_id,
                                                        agent_id: input.agent_id, directory: @project_dir)
        expect(metadata).to include('agentType' => input.agent_type)
        tool_id = metadata.fetch('toolUseId')
        expect(parent_calls).to include(tool_id)
        child_text = messages.grep(ClaudeAgentSDK::AssistantMessage)
                             .select { |message| message.parent_tool_use_id == tool_id }.map(&:text).join
        expect(child_text).to include("#{input.agent_type.upcase}_REPORT")
        tool_id
      end
      expect(tool_ids.uniq.size).to eq(2)
    end

    it 'invalidates a subagent permission request on interrupt before disconnect' do
      pending = Thread::Queue.new
      permission = lambda do |tool_name, _input, context|
        if tool_name == 'Bash' && context.agent_id
          pending << context
          context.signal.wait
        end
        ClaudeAgentSDK::PermissionResultDeny.new(message: 'Test does not execute shell commands')
      end
      options = subagent_options(
        permission_mode: 'default', can_use_tool: permission,
        agents: { 'worker' => ClaudeAgentSDK::AgentDefinition.new(
          description: 'Permission test worker', tools: ['Bash'],
          prompt: 'Use Bash exactly once to run printf permission_probe. Do not use any other tools.'
        ) }
      )
      Async do |task|
        client = ClaudeAgentSDK::Client.new(options: options)
        begin
          task.with_timeout(120) do
            client.connect
            client.query('Call worker once in the foreground to perform its permission probe.')
            context = pending.pop
            expect(context.request_id).not_to be_empty
            expect(context.tool_use_id).not_to be_empty
            expect(context.signal.cancelled?).to be false
            client.interrupt
            # This must happen before ensure disconnect; otherwise we would
            # merely be testing SDK teardown, not the CLI's cancellation.
            expect(context.signal.wait(timeout: 15)).to be true
          end
        ensure
          client.disconnect
        end
      end.wait
    end

    %i[complete stop].each do |action|
      it "observes a background agent #{action} after the parent result" do
        # A local tool gate guarantees the child is still working at the first
        # parent result; no sleeps or guesses about model latency are needed.
        entered = Thread::Queue.new
        release = Thread::Queue.new
        started = Thread::Queue.new
        parent_result = Thread::Queue.new
        gate = ClaudeAgentSDK.create_tool('wait', 'Wait for the test harness to release you', {}) do |_args|
          entered << true
          raise 'test gate expired or closed' unless release.pop(timeout: 120)

          { content: [{ type: 'text', text: 'GATE_RELEASED' }] }
        end
        server = ClaudeAgentSDK.create_sdk_mcp_server(name: 'gate', tools: [gate])
        options = subagent_options(
          allowed_tools: %w[Agent mcp__gate__wait], mcp_servers: { 'gate' => server },
          agents: { 'worker' => ClaudeAgentSDK::AgentDefinition.new(
            description: 'Background test worker', background: true, tools: ['mcp__gate__wait'],
            prompt: 'Call mcp__gate__wait exactly once. After it returns, reply GATE_RELEASED.'
          ) }
        )
        messages = []
        task_id = nil
        terminal = nil
        Async do |task|
          client = ClaudeAgentSDK::Client.new(options: options)
          controller = nil
          begin
            task.with_timeout(120) do
              client.connect
              client.query('Start worker in the background. Do not wait for it, stop it, or call its tool yourself. ' \
                           'Reply STARTED immediately after launching it.')
              controller = task.async do
                child = started.pop
                entered.pop
                parent_result.pop
                action == :stop ? client.stop_task(child.task_id) : release.push(true)
              end
              client.receive_messages do |message|
                messages << message
                if message.is_a?(ClaudeAgentSDK::TaskStartedMessage) && message.task_type == 'local_agent'
                  task_id = message.task_id
                  started << message
                elsif message.is_a?(ClaudeAgentSDK::ResultMessage)
                  parent_result << message
                elsif message.is_a?(ClaudeAgentSDK::TaskUpdatedMessage) || message.is_a?(ClaudeAgentSDK::TaskNotificationMessage)
                  if message.task_id == task_id && ClaudeAgentSDK::TERMINAL_TASK_STATUSES.include?(message.status)
                    terminal = message
                    break
                  end
                end
              end
              controller.wait
            end
          ensure
            release.close # release any worker even when the assertion/protocol fails
            controller&.stop
            client.disconnect
          end
        end.wait
        expect(terminal).not_to be_nil
        expect(action == :stop ? %w[killed stopped] : ['completed']).to include(terminal.status)
        result_index = messages.index { |message| message.is_a?(ClaudeAgentSDK::ResultMessage) }
        expect(result_index).not_to be_nil
        expect(result_index).to be < messages.index(terminal)
        expect(messages[result_index].is_error).to be false
      end
    end
  end
end
