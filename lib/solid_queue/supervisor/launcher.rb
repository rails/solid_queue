# frozen_string_literal: true

module SolidQueue
  class Supervisor::Launcher
    MAX_RESTART_DELAY = 60

    def initialize(configuration)
      @configuration = configuration
      @current_restart_attempt = 0
    end

    def start
      SolidQueue.on_start { @current_restart_attempt = 0 } # reset after successful start

      begin
        SolidQueue::Supervisor.new(@configuration).tap(&:start)
      rescue StandardError => error
        if should_attempt_restart?
          @current_restart_attempt += 1
          delay = [ 2 ** @current_restart_attempt, MAX_RESTART_DELAY ].min

          SolidQueue.instrument(:supervisor_restart, delay: delay, attempt: @current_restart_attempt)
          sleep delay
          retry
        else
          SolidQueue.instrument(:supervisor_restart_failure, error: error)
          raise
        end
      end
    end

    private

      def should_attempt_restart?
        SolidQueue.max_restart_attempts.nil? || @current_restart_attempt < SolidQueue.max_restart_attempts
      end
  end
end
