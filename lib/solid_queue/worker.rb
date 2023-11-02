# frozen_string_literal: true

module SolidQueue
  class Worker
    include Runner

    attr_accessor :queues, :polling_interval, :pool

    def initialize(**options)
      options = options.dup.with_defaults(SolidQueue::Configuration::WORKER_DEFAULTS)

      @polling_interval = options[:polling_interval]
      @queues = options[:queues].to_s
      @pool = Pool.new(options[:pool_size], on_idle: -> { wake_up })
    end

    private
      def run
        claimed_executions = SolidQueue::ReadyExecution.claim(queues, pool.idle_threads, process.id)

        if claimed_executions.size > 0
          procline "performing #{claimed_executions.count} jobs in #{queues}"

          claimed_executions.each do |execution|
            pool.post(execution)
          end
        else
          procline "waiting for jobs in #{queues}"
          interruptible_sleep(polling_interval)
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
        super.merge(queues: queues, pool_size: pool.size, idle_threads: pool.idle_threads, polling_interval: polling_interval)
      end
  end
end
