module SolidQueue
  class Scheduler::ConcurrencyClerk
    include AppExecutor

    attr_accessor :interval, :batch_size

    def initialize(interval, batch_size)
      @interval = interval
      @batch_size = batch_size
    end

    def start
      @task = Concurrent::TimerTask.new(run_now: true, execution_interval: interval) do
        expire_semaphores
        unblock_blocked_executions
      end

      @task.add_observer do |_, _, error|
        handle_thread_error(error) if error
      end

      @task.execute
    end

    def stop
      @task.shutdown
    end

    private
      def expire_semaphores
        wrap_in_app_executor do
          Semaphore.expired.in_batches(of: batch_size, &:delete_all)
        end
      end

      def unblock_blocked_executions
        wrap_in_app_executor do
          BlockedExecution.unblock(batch_size)
        end
      end
  end
end
