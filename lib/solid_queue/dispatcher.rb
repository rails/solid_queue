# frozen_string_literal: true

class SolidQueue::Dispatcher
  include SolidQueue::Processes, SolidQueue::Runner

  attr_accessor :queue, :worker_count, :polling_interval, :workers_pool

  def initialize(**options)
    options = options.dup.with_defaults(SolidQueue::Configuration::DISPATCHER_DEFAULTS)

    @queue = options[:queue_name].to_s
    @worker_count = options[:worker_count]
    @polling_interval = options[:polling_interval]

    @workers_pool = Concurrent::FixedThreadPool.new(@worker_count)
  end

  def inspect
    "Dispatcher(queue=#{queue}, worker_count=#{worker_count}, polling_interval=#{polling_interval})"
  end
  alias to_s inspect

  private
    def run
      executions = SolidQueue::ReadyExecution.claim(queue, worker_count)

      if executions.size > 0
        executions.each do |execution|
          workers_pool.post do
            wrap_in_app_executor do
              execution.perform(process)
            end
          end
        end
      else
        interruptable_sleep(polling_interval)
      end
    end

    def wait
      workers_pool.shutdown
      workers_pool.wait_for_termination
      super
    end
end
