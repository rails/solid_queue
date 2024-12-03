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

      # Sleeps for 'time'.  Can be interrupted asynchronously and return early via wake_up.
      # @param time [Numeric] the time to sleep. 0 returns immediately.
      # @return [true, nil]
      # * returns `true` if an interrupt was requested via #wake_up between the
      #   last call to `interruptible_sleep` and now, resulting in an early return.
      # * returns `nil` if it slept the full `time` and was not interrupted.
      def interruptible_sleep(time)
        # Invoking this from the main thread may result in significant slowdown.
        # Utilizing asynchronous execution (Futures) addresses this performance issue.
        Concurrent::Promises.future(time) do |timeout|
          queue.pop(timeout:).tap { queue.clear }
        end.value
      end

      def queue
        @queue ||= Queue.new
      end
  end
end
