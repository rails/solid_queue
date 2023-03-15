# frozen_string_literal: true

class SolidQueue::Dispatcher
  include SolidQueue::Runner

  attr_accessor :queue, :worker_count, :polling_interval, :workers_pool, :performed_executions

  def initialize(**options)
    options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

    @queue = options[:queue].to_s
    @worker_count = options[:worker_count]
    @polling_interval = options[:polling_interval]

    @workers_pool = Concurrent::FixedThreadPool.new(@worker_count)

    @performed_executions = 0
  end

  def inspect
    "Dispatcher(queue=#{queue}, worker_count=#{worker_count}, polling_interval=#{polling_interval})"
  end
  alias to_s inspect

  private
    def run
      if over_executions_limit?
        stop
      else
        executions = SolidQueue::ReadyExecution.claim(queue, claim_size_limit)

        if executions.size > 0
          executions.each { |execution| post_to_pool(execution) }
          self.performed_executions += executions.size
        else
          interruptable_sleep(polling_interval)
        end
      end
    end

    def over_executions_limit?
      return false unless executions_per_run_limited?

      performed_executions >= SolidQueue.execution_limit_per_dispatch_run
    end

    def claim_size_limit
      if executions_per_run_limited?
        [ SolidQueue.execution_limit_per_dispatch_run - performed_executions, worker_count ].min
      else
        worker_count
      end
    end

    def executions_per_run_limited?
      SolidQueue.execution_limit_per_dispatch_run > 0
    end

    def post_to_pool(execution)
      workers_pool.post do
        wrap_in_app_executor { execution.perform(process) }
      end
    end

    def wait
      workers_pool.shutdown
      workers_pool.wait_for_termination
      super
    end

    def metadata
      super.merge(queue: queue)
    end
end
