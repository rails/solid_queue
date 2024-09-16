# frozen_string_literal: true

module SolidQueue
  module Processes
    class ProcessExitError < RuntimeError
      def initialize(status)
        message = "Process pid=#{status.pid} exited unexpectedly."
        if status.exitstatus.present?
          message += " Exited with status #{status.exitstatus}."
        end

        if status.signaled?
          message += " Received unhandled signal #{status.termsig}."
        end

        super(message)
      end
    end
  end
end
