# frozen_string_literal: true

module SolidQueue
  class Dispatcher < Processes::Base
    include Processes::Runnable, Processes::Poller

    attr_accessor :batch_size, :concurrency_clerk

    after_boot :launch_concurrency_maintenance, if: :concurrency_clerk?
    before_shutdown :stop_concurrency_maintenance, if: :concurrency_clerk?

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

      @batch_size = options[:batch_size]
      @polling_interval = options[:polling_interval]

      @concurrency_clerk = ConcurrencyClerk.new(options[:concurrency_maintenance_interval], options[:batch_size]) if options[:concurrency_clerk]
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

      def concurrency_clerk?
        concurrency_clerk.present?
      end

      def launch_concurrency_maintenance
        concurrency_clerk.start
      end

      def stop_concurrency_maintenance
        concurrency_clerk.stop
      end

      def metadata
        super.merge(batch_size: batch_size, concurrency_maintenance_interval: concurrency_clerk&.interval)
      end
  end
end
