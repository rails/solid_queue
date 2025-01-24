# frozen_string_literal: true

module SolidQueue::Processes
  module Interruptible
    include SolidQueue::AppExecutor

    def wake_up
      interrupt
    end

    private

      def interrupt
        queue << true
      end

      # Sleeps for 'time'.  Can be interrupted asynchronously and return early via wake_up.
      # @param time [Numeric, Duration] the time to sleep. 0 returns immediately.
      def interruptible_sleep(time)
        # Invoking this from the main thread may result in significant slowdown.
        # Utilizing asynchronous execution (Futures) addresses this performance issue.
        Concurrent::Promises.future(time) do |timeout|
          queue.clear unless queue.pop(timeout:).nil?
        end.on_rejection! do |e|
          wrapped_exception = RuntimeError.new("Interruptible#interruptible_sleep - #{e.class}: #{e.message}")
          wrapped_exception.set_backtrace(e.backtrace)
          handle_thread_error(wrapped_exception)
        end.value

        nil
      end

      def queue
        @queue ||= Queue.new
      end
  end
end
