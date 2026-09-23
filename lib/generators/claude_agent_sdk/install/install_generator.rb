# frozen_string_literal: true

require 'rails/generators'

module ClaudeAgentSDK
  module Generators
    # `bin/rails generate claude_agent_sdk:install` — writes the initializer,
    # ignores the vendored CLI, and prints the next steps. Lives under
    # lib/generators/ so Rails' generator lookup finds it by namespace.
    class InstallGenerator < ::Rails::Generators::Base
      # Explicit: Thor derives the namespace by snake-casing the class path,
      # which turns ClaudeAgentSDK into "claude_agent_s_d_k".
      namespace 'claude_agent_sdk:install'
      source_root File.expand_path('templates', __dir__)

      desc 'Creates config/initializers/claude_agent_sdk.rb and git-ignores the vendored Claude Code CLI.'

      GITIGNORE_ENTRY = '/vendor/claude/'
      # Spellings that already ignore the vendored CLI directory.
      GITIGNORE_PATTERN = %r{\A/?vendor/claude/?\z}

      def create_initializer
        template 'claude_agent_sdk.rb.tt', 'config/initializers/claude_agent_sdk.rb'
      end

      def ignore_vendored_cli
        path = File.join(destination_root, '.gitignore')
        entry = "# Claude Code CLI vendored by `bin/rails claude_agent_sdk:install_cli`\n#{GITIGNORE_ENTRY}\n"
        return create_file('.gitignore', entry) unless File.exist?(path)

        content = File.read(path)
        if content.each_line.any? { |line| line.strip.match?(GITIGNORE_PATTERN) }
          say_status :identical, '.gitignore (already ignores vendor/claude)', :blue
        else
          append_to_file '.gitignore', gitignore_separator(content) + entry
        end
      end

      def show_next_steps
        say <<~MSG

          Next steps:
            1. Install the Claude Code CLI this gem is tested with into vendor/claude
               (run it in your Dockerfile / bin/setup as well):
                 bin/rails claude_agent_sdk:install_cli
            2. Provide credentials to the CLI, e.g. ANTHROPIC_API_KEY in the environment.
            3. Review config/initializers/claude_agent_sdk.rb.

          Rails guide: https://github.com/ya-luotao/claude-agent-sdk-ruby/blob/main/docs/rails.md
        MSG
      end

      private

      # Start the appended block on its own line, after a blank one.
      def gitignore_separator(content)
        return '' if content.empty?

        content.end_with?("\n") ? "\n" : "\n\n"
      end
    end
  end
end
