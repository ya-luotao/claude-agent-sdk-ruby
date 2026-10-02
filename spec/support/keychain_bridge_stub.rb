# frozen_string_literal: true

# Store-backed resume bridges the macOS Keychain: unless the caller
# authenticates through the environment, materialization runs
# `security find-generic-password` for the config dir's entry. An example that
# reaches SessionResume.materialize_resume_session without stubbing that —
# any example pairing a session_store with resume — would read the developer's
# real credentials on macOS, copy them into a temp dir and depend on the state
# of the local Keychain.
#
# So the bridge is off for every example by default. The examples that test
# the bridge itself opt in with `keychain: true`, on the example or its group,
# and replace the layer below it (capture_with_timeout) instead: see
# spec/unit/session_resume_keychain_spec.rb, which also pins this default.
RSpec.configure do |config|
  config.before do |example|
    next if example.metadata[:keychain]

    allow(ClaudeAgentSDK::SessionResume).to receive(:read_keychain_credentials).and_return(nil)
  end
end
