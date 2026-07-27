# frozen_string_literal: true

module SolidQueue
  class Dispatcher::ConcurrencyMaintenance
    include AppExecutor

    attr_reader :interval, :batch_size

    class << self
      def perform(batch_size: SolidQueue::Configuration::DISPATCHER_DEFAULTS[:batch_size])
        new(nil, batch_size).perform
      end
    end

    def initialize(interval, batch_size)
      @interval = interval
      @batch_size = batch_size
    end

    def start
      # Run once inline so stale locks are cleared before workers forked alongside
      # this dispatcher can claim jobs (see #735). The timer then handles the
      # periodic follow-up without racing that first pass via run_now.
      perform

      @concurrency_maintenance_task = Concurrent::TimerTask.new(run_now: false, execution_interval: interval) do
        perform
      end

      @concurrency_maintenance_task.add_observer do |_, _, error|
        handle_thread_error(error) if error
      end

      @concurrency_maintenance_task.execute
    end

    def stop
      @concurrency_maintenance_task&.shutdown
    end

    def perform
      expire_semaphores
      unblock_blocked_executions
    end

    private
      def expire_semaphores
        wrap_in_app_executor do
          # Ready concurrency-limited jobs still own their slot after a claimed
          # execution is released back to the ready queue. Expiring that
          # semaphore would let unblock promote another job for the same key and
          # break limits_concurrency (#735).
          scope = Semaphore.expired
          ready_keys = concurrency_keys_held_by_ready_jobs
          scope = scope.where.not(key: ready_keys) if ready_keys.any?

          scope.in_batches(of: batch_size, &:delete_all)
        end
      end

      def concurrency_keys_held_by_ready_jobs
        Job.where(id: ReadyExecution.select(:job_id))
          .where.not(concurrency_key: [ nil, "" ])
          .distinct
          .pluck(:concurrency_key)
      end

      def unblock_blocked_executions
        wrap_in_app_executor do
          BlockedExecution.unblock(batch_size)
        end
      end
  end
end
