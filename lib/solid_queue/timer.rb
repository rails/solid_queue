# frozen_string_literal: true

module SolidQueue
  module Timer
    extend self

    def wait_until(timeout, condition, &block)
      if timeout > 0
        deadline = monotonic_time_now + timeout

        while monotonic_time_now < deadline && !condition.call
          sleep 0.1
          block.call
        end
      else
        while !condition.call
          sleep 0.5
          block.call
        end
      end
    end

    private
      def monotonic_time_now
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
  end
end
