# frozen_string_literal: true

module SolidQueue
  class Dispatcher < Processes::Poller
    include LifecycleHooks
    attr_accessor :batch_size, :concurrency_maintenance

    after_boot :run_start_hooks
    after_boot :start_concurrency_maintenance
    before_shutdown :stop_concurrency_maintenance
    after_shutdown :run_stop_hooks

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

      @batch_size = options[:batch_size]

      @concurrency_maintenance = ConcurrencyMaintenance.new(options[:concurrency_maintenance_interval], options[:batch_size]) if options[:concurrency_maintenance]

      super(**options)
    end

    def metadata
      super.merge(batch_size: batch_size, concurrency_maintenance_interval: concurrency_maintenance&.interval)
    end

    private
      def poll
        batch = dispatch_next_batch

        batch.zero? ? polling_interval : 0.seconds
      end

      def dispatch_next_batch
        with_polling_volume do
          ScheduledExecution.dispatch_next_batch(batch_size)
        end
      end

      def start_concurrency_maintenance
        concurrency_maintenance&.start
      end

      def stop_concurrency_maintenance
        concurrency_maintenance&.stop
      end

      def all_work_completed?
        SolidQueue::ScheduledExecution.none?
      end

      def set_procline
        procline "dispatching every #{polling_interval.seconds} seconds"
      end
  end
end
