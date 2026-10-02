# frozen_string_literal: true

require 'spec_helper'

# The fail-closed branch of the permission round trip: a can_use_tool
# callback that returns anything but a PermissionResult must not be read as a
# decision. The CLI gets an error control response, never `behavior: allow` —
# `true`, `nil` and a Hash are what a callback written from memory returns,
# and answering any of them with an allow would run the tool unasked.
RSpec.describe ClaudeAgentSDK::Query do
  describe 'a can_use_tool request whose callback does not return a PermissionResult' do
    # The request the CLI sends before a tool call it has no rule for.
    let(:request) do
      { subtype: 'can_use_tool', tool_name: 'Bash', input: { command: 'rm -rf build' },
        permission_suggestions: [{ type: 'addRules', behavior: 'allow', destination: 'session',
                                   rules: [{ toolName: 'Bash', ruleContent: 'rm -rf build' }] }],
        tool_use_id: 'toolu_01A2b3C4d5E6f7G8h9J0kLmN' }
    end

    # Returns the SDK's reply and every frame it wrote during the session.
    def ask_permission(callback)
      options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: callback)
      ScriptedCLI.session(options) do |cli|
        [cli.request(request, request_id: 'req_permission'), cli.received]
      end
    end

    {
      'true' => true,
      'nil' => nil,
      'a Hash shaped like an allow' => { behavior: 'allow', updatedInput: { command: 'rm -rf build' } }
    }.each do |label, returned|
      it "answers #{label} with an error, never an allow" do
        asked = []
        callback = lambda do |tool_name, input, _context|
          asked << [tool_name, input]
          returned
        end

        reply, written = ask_permission(callback)

        expect(asked).to eq([['Bash', { command: 'rm -rf build' }]])
        expect(reply).to include('subtype' => 'error', 'request_id' => 'req_permission')
        expect(reply.fetch('error'))
          .to eq("Tool permission callback must return PermissionResult, got #{returned.class}")
        expect(reply).not_to have_key('response')
        expect(JSON.generate(written)).not_to include('"behavior"')
      end
    end

    # The same request through the same channel, answered by a real
    # PermissionResult: without it, a harness that turned every request into
    # an error would make the examples above pass for the wrong reason.
    it 'answers a PermissionResultAllow with an allow' do
      reply, = ask_permission(->(_tool_name, _input, _context) { ClaudeAgentSDK::PermissionResultAllow.new })

      expect(reply).to include('subtype' => 'success', 'request_id' => 'req_permission')
      expect(reply.fetch('response')).to eq('behavior' => 'allow', 'updatedInput' => { 'command' => 'rm -rf build' })
    end
  end
end
