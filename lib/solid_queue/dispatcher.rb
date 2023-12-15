# frozen_string_literal: true

module SolidQueue
  class Dispatcher < Processes::Base
    include Processes::Runnable, Processes::Poller

    attr_accessor :batch_size, :concurrency_maintenance_interval

    set_callback :boot, :after, :launch_concurrency_maintenance
    set_callback :shutdown, :before, :stop_concurrency_maintenance

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

      @batch_size = options[:batch_size]
      @polling_interval = options[:polling_interval]
      @concurrency_maintenance_interval = options[:concurrency_maintenance_interval]
    end

    private
      def run
        batch = dispatch_next_batch

        unless batch.size > 0
          procline "waiting"
          interruptible_sleep(polling_interval)
        end
      end

      def dispatch_next_batch
        with_polling_volume do
          SolidQueue::ScheduledExecution.dispatch_next_batch(batch_size)
        end
      end

      def launch_concurrency_maintenance
        @concurrency_maintenance_task = Concurrent::TimerTask.new(run_now: true, execution_interval: concurrency_maintenance_interval) do
          expire_semaphores
          unblock_blocked_executions
        end

        @concurrency_maintenance_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @concurrency_maintenance_task.execute
      end

      def stop_concurrency_maintenance
        @concurrency_maintenance_task.shutdown
      end

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

      def initial_jitter
        Kernel.rand(0...polling_interval)
      end

      def metadata
        super.merge(batch_size: batch_size)
      end
  end
end
