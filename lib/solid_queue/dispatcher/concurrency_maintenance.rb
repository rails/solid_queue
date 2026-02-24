# frozen_string_literal: true

module SolidQueue
  class Dispatcher::ConcurrencyMaintenance
    include AppExecutor

    attr_reader :interval, :batch_size

    def initialize(interval, batch_size)
      @interval = interval
      @batch_size = batch_size
    end

    def start
      @concurrency_maintenance_task = Concurrent::TimerTask.new(run_now: true, execution_interval: interval) do
        wrap_in_app_executor do
          silencing_sql_logs do
            expire_semaphores
            unblock_blocked_executions
          end
        end
      end

      @concurrency_maintenance_task.add_observer do |_, _, error|
        handle_thread_error(error) if error
      end

      @concurrency_maintenance_task.execute
    end

    def stop
      @concurrency_maintenance_task&.shutdown
    end

    private
      def expire_semaphores
        Semaphore.expired.in_batches(of: batch_size, &:delete_all)
      end

      def unblock_blocked_executions
        BlockedExecution.unblock(batch_size)
      end
  end
end
