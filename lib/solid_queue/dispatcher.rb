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

  def stop
    workers_pool.shutdown
    workers_pool.wait_for_termination
    release_claims
    super
  end

  def inspect
    "Dispatcher(queue=#{queue}, worker_count=#{worker_count}, polling_interval=#{polling_interval})"
  end
  alias to_s inspect

  private
    def run
      loop do
        break if stopping?

        jobs = SolidQueue::ReadyExecution.claim(queue, worker_count)

        if jobs.size > 0
          jobs.each do |job|
            workers_pool.post { job.perform }
          end
        else
          interruptable_sleep(polling_interval)
        end
      end
    end

    def release_claims
    end

    def identifier
      "host:#{Socket.gethostname} pid:#{Process.pid}"
    rescue StandardError
      "pid:#{Process.pid}"
    end
end
