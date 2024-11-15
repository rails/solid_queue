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
        # Since this is invoked on the main thread, using some form of Async
        # avoids a 35% slowdown (at least when running the test suite).
        #
        # Using Futures for architectural consistency with all the other Async in SolidQueue.
        Concurrent::Promises.future(time) do |timeout|
          if timeout > 0 && queue.pop(timeout:)
            queue.clear # exiting the poll wait guarantees testing for SHUTDOWN before next poll
          end
        end.value
      end

      def queue
        @queue ||= Queue.new
      end
  end
end
