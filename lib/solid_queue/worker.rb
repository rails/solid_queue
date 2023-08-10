# frozen_string_literal: true

module SolidQueue
  class Worker
    include Runner

    attr_accessor :queue, :polling_interval, :pool

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::WORKER_DEFAULTS)

      @queue = options[:queue_name].to_s
      @polling_interval = options[:polling_interval]

      @pool = Pool.new(options[:pool_size], on_idle: -> { wake_up })
    end

    private
      def run
        claimed_executions = SolidQueue::ReadyExecution.claim(queue, pool.idle_threads)

        if claimed_executions.size > 0
          procline "performing #{claimed_executions.count} jobs in #{queue}"

          claimed_executions.each do |execution|
            pool.post(execution, process)
          end
        else
          procline "waiting for jobs in #{queue}"
          interruptible_sleep(polling_interval)
        end
      end

      def shutdown
        super

        pool.shutdown
        pool.wait_for_termination(SolidQueue.shutdown_timeout)
      end

      def shutdown_completed?
        pool.shutdown?
      end

      def metadata
        super.merge(queue: queue, pool_size: pool.size, idle_threads: pool.idle_threads, polling_interval: polling_interval)
      end
  end
end
