# frozen_string_literal: true

module SolidQueue
  class Dispatcher < Processes::Base
    include Processes::Runnable, Processes::Poller

    attr_accessor :batch_size, :concurrency_maintenance, :recurring_schedule

    after_boot :start_concurrency_maintenance, :load_recurring_schedule
    before_shutdown :stop_concurrency_maintenance, :unload_recurring_schedule

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

      @batch_size = options[:batch_size]
      @polling_interval = options[:polling_interval]

      @concurrency_maintenance = ConcurrencyMaintenance.new(options[:concurrency_maintenance_interval], options[:batch_size]) if options[:concurrency_maintenance]
      @recurring_schedule = RecurringSchedule.new(options[:recurring_tasks])
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
          ScheduledExecution.dispatch_next_batch(batch_size)
        end
      end

      def start_concurrency_maintenance
        concurrency_maintenance&.start
      end

      def load_recurring_schedule
        recurring_schedule.load_tasks
      end

      def stop_concurrency_maintenance
        concurrency_maintenance&.stop
      end

      def unload_recurring_schedule
        recurring_schedule.unload_tasks
      end

      def metadata
        super.merge(batch_size: batch_size, concurrency_maintenance_interval: concurrency_maintenance&.interval, recurring_schedule: recurring_schedule.tasks.presence)
      end
  end
end
