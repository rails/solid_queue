# frozen_string_literal: true

module SolidQueue
  class Scheduler
    include Runner

    attr_accessor :batch_size, :polling_interval

    set_callback :start, :before, :launch_concurrency_maintenance
    set_callback :shutdown, :before, :stop_concurrency_maintenance

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::SCHEDULER_DEFAULTS)

      @batch_size = options[:batch_size]
      @polling_interval = options[:polling_interval]
    end

    private
      def run
        with_polling_volume do
          batch = SolidQueue::ScheduledExecution.next_batch(batch_size).tap(&:load)

          if batch.size > 0
            procline "preparing #{batch.size} jobs for execution"

            SolidQueue::ScheduledExecution.prepare_batch(batch)
          else
            procline "waiting"
            interruptible_sleep(polling_interval)
          end
        end
      end

      def launch_concurrency_maintenance
        @concurrency_maintenance_task = Concurrent::TimerTask.new(run_now: true, execution_interval: polling_interval) do
          expire_semaphores
          unblock_blocked_executions
        end

        @concurrency_maintenance_task.execute
      end

      def stop_concurrency_maintenance
        @concurrency_maintenance_task.shutdown
      end

      def expire_semaphores
        Semaphore.expired.in_batches(of: batch_size, &:delete_all)
      end

      def unblock_blocked_executions
        BlockedExecution.unblock(batch_size)
      end

      def metadata
        super.merge(batch_size: batch_size, polling_interval: polling_interval)
      end
  end
end
