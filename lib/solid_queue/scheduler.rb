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

      @concurrency_clerk = ConcurrencyClerk.new(options[:concurrency_maintenance_interval], options[:batch_size])
    end

    private
      def run
        batch = prepare_next_batch

        unless batch.size > 0
          procline "waiting"
          interruptible_sleep(polling_interval)
        end
      end

      def prepare_next_batch
        with_polling_volume do
          SolidQueue::ScheduledExecution.prepare_next_batch(batch_size)
        end
      end

      def launch_concurrency_maintenance
        @concurrency_clerk.start
      end

      def stop_concurrency_maintenance
        @concurrency_clerk.stop
      end

      def initial_jitter
        Kernel.rand(0...polling_interval)
      end

      def metadata
        super.merge(batch_size: batch_size, polling_interval: polling_interval)
      end
  end
end
