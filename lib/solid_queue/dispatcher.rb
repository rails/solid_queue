# frozen_string_literal: true

class SolidQueue::Dispatcher
  include SolidQueue::Runnable

  attr_accessor :queue, :worker_count, :polling_interval, :workers_pool

  def initialize(**options)
    options = options.dup.with_defaults(SolidQueue::Configuration::QUEUE_DEFAULTS)

    @queue = options[:queue_name].to_s
    @worker_count = options[:worker_count]
    @polling_interval = options[:polling_interval]

    @workers_pool = Concurrent::FixedThreadPool.new(@worker_count)
  end

  def inspect
    "Dispatcher(identifier=#{identifier}, queue=#{queue}, worker_count=#{worker_count}, polling_interval=#{polling_interval})"
  end
  alias to_s inspect

  private
    def run
      executions = SolidQueue::ReadyExecution.claim(queue, worker_count)

      if executions.size > 0
        executions.each do |execution|
          workers_pool.post { execution.perform(identifier) }
        end
      else
        interruptable_sleep(polling_interval)
      end
    end

    def wait
      workers_pool.shutdown
      workers_pool.wait_for_termination
      release_claims
      super
    end

    def clean_up
      release_claims
    end

    def release_claims
      SolidQueue::ClaimedExecution.release_all_from(identifier)
    end

    def identifier
      @identifier ||= "#{hostname}:#{pid}:#{queue}"
    end
end
