# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Base
    include Processes::Runnable, Processes::Poller

    attr_accessor :queues, :pool

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::WORKER_DEFAULTS)

      @polling_interval = options[:polling_interval]
      @queues = Array(options[:queues])
      @pool = Pool.new(options[:threads], on_idle: -> { wake_up })
    end

    private
      def run
        polled_executions = poll

        if polled_executions.size > 0
          procline "performing #{polled_executions.count} jobs"

          polled_executions.each do |execution|
            pool.post(execution)
          end
        else
          procline "waiting for jobs in #{queues.join(",")}"
          interruptible_sleep(polling_interval)
        end
      end

      def poll
        with_polling_volume do
          SolidQueue::ReadyExecution.claim(queues, pool.idle_threads, process.id)
        end
      end

      def shutdown
        super

        pool.shutdown
        pool.wait_for_termination(SolidQueue.shutdown_timeout)
      end

      def all_work_completed?
        SolidQueue::ReadyExecution.queued_as(queues).empty?
      end

      def metadata
        super.merge(queues: queues.join(","), thread_pool_size: pool.size)
      end
  end
end
