# frozen_string_literal: true

# claude_agent_sdk:* tasks. Loaded by ClaudeAgentSDK::Railtie in Rails apps
# and by `require 'claude_agent_sdk/tasks'` from a plain Rakefile. Guarded
# because Rake appends the actions of a task defined twice — an app that
# does both would otherwise install twice.
unless Rake::Task.task_defined?('claude_agent_sdk:install_cli')
  namespace :claude_agent_sdk do
    desc 'Install the Claude Code CLI into vendor/claude: the version this gem is tested with, ' \
         'or CLAUDE_CLI_VERSION=x.y.z / stable / latest'
    task :install_cli do
      # Install where discovery looks. An explicitly set CLIInstaller.root
      # (config/application.rb, the Rakefile) wins: nil dir means
      # CLIInstaller.default_dir, i.e. <root>/vendor/claude. Otherwise, under
      # Rails, anchor to the app root instead of the process cwd — the same
      # root the Railtie gives discovery at boot. The app is not booted here
      # (no :environment dependency, so this runs in a Docker build without
      # credentials), so that initializer has not run. Resolved when the
      # task runs.
      unless ClaudeAgentSDK::CLIInstaller.root
        root = Rails.root if defined?(Rails) && Rails.respond_to?(:root)
        dir = root&.join('vendor', 'claude')&.to_s
      end
      # Not the conventional rake `VERSION`: Rails' own db:migrate uses it and
      # build environments often export it for the app's version or git SHA.
      version = ENV.fetch('CLAUDE_CLI_VERSION', '').strip

      path = if version.empty?
               ClaudeAgentSDK::CLIInstaller.install_pinned(dir: dir)
             else
               ClaudeAgentSDK::CLIInstaller.install(version: version, dir: dir)
             end
      label = version.empty? ? ClaudeAgentSDK::CLIInstaller::PINNED_CLI_VERSION : version
      puts "Claude Code CLI (#{label}) installed at #{path}"
    end
  end
end
