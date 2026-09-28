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
        return unless maintenance

        maintenance.start
        launch_maintenance_watchdog
      end

      # A stalled maintenance run means semaphores are no longer expired and
      # blocked executions no longer unblocked, so concurrency-limited jobs
      # stall system-wide -- silently, because a run that never returns raises
      # nothing for the task's observer to report. The watchdog's check reads
      # nothing but memory, so it cannot block the same way, and stopping to
      # be replaced hands the work to a fresh dispatcher with a fresh
      # maintenance task.
      #
      # The watchdog ticks at the heartbeat interval, like the supervisor's
      # maintenance watchdog: not that heartbeats are involved, it is just the
      # liveness-checking cadence SolidQueue already has, short against any
      # sane stall threshold.
      def launch_maintenance_watchdog
        @maintenance_watchdog_task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) do
          stop_to_be_replaced if maintenance.stalled?
        end

        @maintenance_watchdog_task.add_observer do |_, _, error|
          handle_thread_error(error) if error
        end

        @maintenance_watchdog_task.execute
      end

      def stop_maintenance
        maintenance&.stop
        @maintenance_watchdog_task&.shutdown
      end

      def all_work_completed?
        SolidQueue::ScheduledExecution.none?
      end

      def set_procline
        procline "dispatching every #{polling_interval.seconds} seconds"
      end
  end
end
