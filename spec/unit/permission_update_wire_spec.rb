# frozen_string_literal: true

require 'spec_helper'
require 'async'
require 'json'

# The CLI validates the updatedPermissions array of a can_use_tool reply as
# one unit. CLI 2.1.286: a rule is { toolName: string, ruleContent?: string }
# (absent, never null) and every update needs a destination. One entry that
# does not fit and the whole array is dropped, with nothing but a line in the
# CLI's debug log — the tool call is still allowed, the "always allow" never
# sticks, and the callback is asked again on every call.
RSpec.describe ClaudeAgentSDK::PermissionUpdate do
  # The suggestion the CLI builds for a tool it allows as a whole (WebSearch,
  # every MCP tool): a rule without ruleContent.
  whole_tool_suggestion = {
    type: 'addRules',
    rules: [{ toolName: 'WebSearch' }],
    behavior: 'allow',
    destination: 'localSettings'
  }.freeze

  describe '#to_h' do
    it 'leaves ruleContent out of a rule that has no content' do
      update = described_class.new(
        type: 'addRules', behavior: 'allow', destination: 'session',
        rules: [ClaudeAgentSDK::PermissionRuleValue.new(tool_name: 'WebSearch')]
      )

      expect(update.to_h).to eq(
        type: 'addRules', destination: 'session', rules: [{ toolName: 'WebSearch' }], behavior: 'allow'
      )
    end

    it 'keeps ruleContent for a rule that has content, an empty String included' do
      update = described_class.new(
        type: 'replaceRules', behavior: 'deny', destination: 'projectSettings',
        rules: [{ tool_name: 'Bash', rule_content: 'git push:*' }, { tool_name: 'Read', rule_content: '' },
                { tool_name: 'mcp__docs__search' }]
      )

      expect(update.to_h[:rules]).to eq(
        [{ toolName: 'Bash', ruleContent: 'git push:*' }, { toolName: 'Read', ruleContent: '' },
         { toolName: 'mcp__docs__search' }]
      )
    end

    it 'round-trips the suggestion the CLI sends for a whole-tool rule' do
      hydrated = described_class.from_hash(whole_tool_suggestion)

      expect(hydrated.rules.first.rule_content).to be_nil
      expect(hydrated.to_h).to eq(whole_tool_suggestion)
      expect(JSON.generate(hydrated.to_h)).not_to include('ruleContent', 'null')
    end

    {
      'addRules' => { behavior: 'allow', rules: [{ tool_name: 'Bash', rule_content: 'ls' }] },
      'replaceRules' => { behavior: 'ask', rules: [{ tool_name: 'Write' }] },
      'removeRules' => { behavior: 'deny', rules: [{ tool_name: 'WebFetch' }] },
      'setMode' => { mode: 'acceptEdits' },
      'addDirectories' => { directories: ['/work/shared'] },
      'removeDirectories' => { directories: ['/work/shared'] }
    }.each do |type, fields|
      it "sends #{type} without a destination to the session" do
        update = described_class.new(type: type, **fields)

        expect(update.destination).to be_nil
        expect(update.to_h[:destination]).to eq('session')
      end
    end

    it 'keeps the destination the update names' do
      sent = ClaudeAgentSDK::PERMISSION_UPDATE_DESTINATIONS.map do |destination|
        described_class.new(type: 'setMode', mode: 'plan', destination: destination).to_h[:destination]
      end

      expect(sent).to eq(ClaudeAgentSDK::PERMISSION_UPDATE_DESTINATIONS)
    end

    it 'leaves an update without a type as it was' do
      expect(described_class.new.to_h).to eq(type: nil)
      expect(described_class.new(destination: 'userSettings').to_h).to eq(type: nil, destination: 'userSettings')
    end
  end

  # The documented loop: hand context.suggestions back as updated_permissions.
  describe 'echoed back through can_use_tool' do
    # A can_use_tool request as CLI 2.1.286 writes it (recorded; the temporary
    # directory is shortened), as the transport hands it to Query.
    def can_use_tool_request(suggestions)
      request = JSON.parse(<<~FRAME, symbolize_names: true)
        {"type":"control_request","request_id":"59125456-7f10-41d7-8f57-31700867e194","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch lane-e-probe.txt","description":"Create empty file lane-e-probe.txt"},"description":"Create empty file lane-e-probe.txt","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch lane-e-probe.txt"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/private/var/folders/3y/T/lane-e-20261002"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}],"blocked_path":"/private/var/folders/3y/T/lane-e-20261002/lane-e-probe.txt","tool_use_id":"toolu_01NzfL6jnh8N6VM4uxq7ZjMX"}}
      FRAME
      request[:request][:permission_suggestions] = suggestions if suggestions
      request
    end

    # Answers the request by allowing the call with every suggestion, and
    # gives back the one line the SDK wrote to the CLI.
    def reply_line(suggestions = nil)
      writes = []
      transport = instance_double(ClaudeAgentSDK::Transport)
      allow(transport).to receive(:write) { |data| writes << data }
      always_allow = lambda do |_tool_name, _input, context|
        ClaudeAgentSDK::PermissionResultAllow.new(updated_permissions: context.suggestions)
      end
      query = ClaudeAgentSDK::Query.new(transport: transport, is_streaming_mode: true, can_use_tool: always_allow)

      Async { query.send(:handle_control_request, can_use_tool_request(suggestions)) }.wait

      expect(writes.size).to eq(1)
      writes.first
    end

    def updated_permissions(line)
      JSON.parse(line, symbolize_names: true).dig(:response, :response, :updatedPermissions)
    end

    it 'returns the suggestions of a recorded request unchanged' do
      sent = can_use_tool_request(nil).dig(:request, :permission_suggestions)

      expect(sent.map { |suggestion| suggestion[:type] }).to eq(%w[addRules addDirectories setMode])
      expect(updated_permissions(reply_line)).to eq(sent)
    end

    it 'returns a whole-tool rule without a null ruleContent' do
      line = reply_line([whole_tool_suggestion])

      expect(updated_permissions(line)).to eq([whole_tool_suggestion])
      expect(line).not_to include('ruleContent', 'null')
    end

    it 'writes no null into an array that mixes rules with and without content' do
      suggestions = can_use_tool_request(nil).dig(:request, :permission_suggestions) + [whole_tool_suggestion]
      line = reply_line(suggestions)

      expect(updated_permissions(line)).to eq(suggestions)
      expect(line).not_to include('null')
    end
  end
end
