# frozen_string_literal: true

# Rake tasks for apps that don't use Rails (where the Railtie loads them).
# From a plain Rakefile:
#
#   require 'claude_agent_sdk/tasks'
#
# then `rake claude_agent_sdk:install_cli` (e.g. in a Dockerfile). Only the
# stdlib-only CLIInstaller is loaded, not the whole SDK.
require 'rake'
require_relative 'cli_installer'

load File.expand_path('tasks/claude_agent_sdk.rake', __dir__)
