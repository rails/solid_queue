# frozen_string_literal: true

module SolidQueue::Processes
  module Interruptible
    def wake_up
      interrupt
    end

    private

      def interrupt
        queue << true
      end

      def interruptible_sleep(time)
        # Invoking from the main thread can result in a 35% slowdown (at least when running the test suite).
        # Using some form of Async (Futures) addresses this performance issue.
        Concurrent::Promises.future(time) do |timeout|
          if timeout > 0 && queue.pop(timeout:)
            queue.clear
          end
        end.value
      end

      def queue
        @queue ||= Queue.new
      end
  end
end
