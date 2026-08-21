# frozen_string_literal: true

module SolidQueue
  class Dispatcher::Maintenance
    include AppExecutor

    attr_reader :interval, :batch_size

    def initialize(interval, batch_size, concurrency:, batches:)
      @interval = interval
      @batch_size = batch_size
      @concurrency = concurrency
      @batches = batches
    end

    def concurrency?
      @concurrency
    end

    def batches?
      @batches
    end

    def metadata
      { concurrency_maintenance_interval: (interval if concurrency?), batch_maintenance: batches? }
    end

    def start
      @maintenance_task = Concurrent::TimerTask.new(run_now: true, execution_interval: interval) do
        if concurrency?
          expire_semaphores
          unblock_blocked_executions
        end

        sweep_stalled_batches if batches?
      end

      @maintenance_task.add_observer do |_, _, error|
        handle_thread_error(error) if error
      end

      @maintenance_task.execute
    end

    def stop
      @maintenance_task&.shutdown
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

      def sweep_stalled_batches
        wrap_in_app_executor do
          if Batch.migrated?
            Batch.sweep_stalled(batch_size: batch_size)
          else
            warn_once_about_pending_batch_migrations
          end
        end
      end

      def warn_once_about_pending_batch_migrations
        unless @warned_about_pending_migrations
          Batch.warn_about_pending_migrations
          @warned_about_pending_migrations = true
        end
      end
  end
end
