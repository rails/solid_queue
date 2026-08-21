# frozen_string_literal: true

module SolidQueue
  class Dispatcher < Processes::Poller
    include LifecycleHooks

    attr_reader :batch_size

    after_boot :run_start_hooks
    after_boot :start_maintenance
    before_shutdown :stop_maintenance
    before_shutdown :run_stop_hooks
    after_shutdown :run_exit_hooks

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

      @batch_size = options[:batch_size]

      # Run both maintenance routines on one timer instead of another thread.
      if options[:concurrency_maintenance] || options[:batch_maintenance]
        @maintenance = Maintenance.new(options[:concurrency_maintenance_interval], options[:batch_size],
          concurrency: options[:concurrency_maintenance], batches: options[:batch_maintenance])
      end

      super(**options)
    end

    def metadata
      super.merge(batch_size: batch_size).merge(maintenance&.metadata || {})
    end

    private
      attr_reader :maintenance

      def poll
        batch = dispatch_next_batch

        batch.zero? ? polling_interval : 0.seconds
      end

      def dispatch_next_batch
        with_polling_volume do
          ScheduledExecution.dispatch_next_batch(batch_size)
        end
      end

      def start_maintenance
        maintenance&.start
      end

      def stop_maintenance
        maintenance&.stop
      end

      def all_work_completed?
        SolidQueue::ScheduledExecution.none?
      end

      def set_procline
        procline "dispatching every #{polling_interval.seconds} seconds"
      end
  end
end
