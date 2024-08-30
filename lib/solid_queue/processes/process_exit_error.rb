# frozen_string_literal: true

module SolidQueue
  module Processes
    class ProcessExitError < RuntimeError
      def initialize(status)
        message = case
        when status.exitstatus.present? then "Process pid=#{status.pid} exited with status #{status.  exitstatus}"
        when status.signaled? then "Process pid=#{status.pid} received unhandled signal #{status. termsig}"
        else "Process pid=#{status.pid} exited unexpectedly"
        end

        super(message)
      end
    end
  end
end
