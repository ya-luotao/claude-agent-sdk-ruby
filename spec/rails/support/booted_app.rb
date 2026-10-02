# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'

module ClaudeAgentSDKRailsSpec
  # Observations made inside a real, booted Rails application.
  #
  # The spec process's own application (rails_helper.rb) is never
  # initialized: its executor has none of the hooks Rails registers at boot,
  # Rails.logger is nil, and the isolation level is whatever the process
  # started with. What an SDK callback sees of its caller's state depends on
  # all three, so specs about that state read it from a child process that
  # boots an application first (booted_app_child.rb), once per configuration.
  module BootedApp
    CHILD = File.expand_path('booted_app_child.rb', __dir__)
    LIB = File.expand_path('../../../lib', __dir__)
    RESULT = 'BOOTED_APP_RESULT '
    # A hang guard, not a synchronization point: nothing in the child waits
    # on a clock, so a healthy run ends in a second or two on an idle machine.
    LIMIT_SECONDS = 600

    @results = {}
    @lock = Mutex.new

    # What the child observed, as parsed JSON (String keys).
    #
    # @param reloading [Boolean] config.enable_reloading — development (true)
    #   or production (false)
    # @param isolation [Symbol] ActiveSupport::IsolatedExecutionState.isolation_level
    def self.observe(reloading:, isolation:)
      @lock.synchronize { @results[[reloading, isolation]] ||= run(reloading: reloading, isolation: isolation) }
    end

    def self.run(reloading:, isolation:)
      env = { 'RAILS_ENV' => reloading ? 'development' : 'production', 'BOOTED_APP_ISOLATION' => isolation.to_s }
      out, err, status = capture(env, RbConfig.ruby, '-I', LIB, CHILD)
      line = out.lines.reverse.find { |candidate| candidate.start_with?(RESULT) }
      return JSON.parse(line.delete_prefix(RESULT)) if status.success? && line

      raise "booted app (#{env}) failed with #{status.inspect}:\n#{err}\n#{out}"
    end
    private_class_method :run

    def self.capture(env, *command)
      Open3.popen3(env, *command) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        readers = [stdout, stderr].map { |io| Thread.new { io.read } }
        Process.kill('KILL', wait_thread.pid) unless wait_thread.join(LIMIT_SECONDS)
        [*readers.map(&:value), wait_thread.value]
      end
    end
    private_class_method :capture
  end
end
