# frozen_string_literal: true

module SolidQueue
  class Dispatcher < Processes::Base
    include Processes::Runnable, Processes::Poller

    attr_accessor :batch_size, :concurrency_maintenance, :recurring_tasks

    after_boot :start_concurrency_maintenance, :schedule_recurring_tasks
    before_shutdown :stop_concurrency_maintenance, :unschedule_recurring_tasks

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

      @batch_size = options[:batch_size]
      @polling_interval = options[:polling_interval]

      @concurrency_maintenance = ConcurrencyMaintenance.new(options[:concurrency_maintenance_interval], options[:batch_size]) if options[:concurrency_maintenance]
      @recurring_tasks = RecurringTasks.new(options[:recurring_tasks])
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

      def start_concurrency_maintenance
        concurrency_maintenance&.start
      end

      def schedule_recurring_tasks
        recurring_tasks.schedule
      end

      def stop_concurrency_maintenance
        concurrency_maintenance&.stop
      end

      def unschedule_recurring_tasks
        recurring_tasks.unschedule
      end

      def metadata
        super.merge(batch_size: batch_size, concurrency_maintenance_interval: concurrency_maintenance&.interval)
      end
  end
end
