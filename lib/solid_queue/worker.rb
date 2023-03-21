# frozen_string_literal: true

class SolidQueue::Worker
  include SolidQueue::Runner

  attr_accessor :queue, :pool_size, :polling_interval, :pool

  def initialize(**options)
    options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

    @queue = options[:queue_name].to_s
    @pool_size = options[:pool_size]
    @polling_interval = options[:polling_interval]

    @pool = Concurrent::FixedThreadPool.new(@pool_size)
  end

  private
    def run
      executions = SolidQueue::ReadyExecution.claim(queue, pool_size)

      if executions.size > 0
        executions.each do |execution|
          pool.post do
            wrap_in_app_executor do
              execution.perform(process)
            end
          end
        end
      else
        interruptible_sleep(polling_interval)
      end
    end

    def shutdown
      pool.shutdown
      pool.wait_for_termination(SolidQueue.shutdown_timeout)
    end

    def shutdown_completed?
      pool.shutdown?
    end

    def metadata
      super.merge(queue: queue, pool_size: pool_size, polling_interval: polling_interval)
    end
end
