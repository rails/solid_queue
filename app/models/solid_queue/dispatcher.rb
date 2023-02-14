# frozen_string_literal: true

class SolidQueue::Dispatcher
  include SolidQueue::Runnable

  attr_accessor :queues, :worker_count, :workers_pool

  def initialize(**options)
    @queues = Array(options[:queues]).presence || [ "default" ]
    @worker_count = options[:worker_count] || 5
    @workers_pool = Concurrent::FixedThreadPool.new(@worker_count)
  end

  def stop
    workers_pool.shutdown
    clear_locks
    super
  end

  private
    def run
      loop do
        break if stopping?

        jobs = SolidQueue::ReadyExecution.claim(queues, worker_count)

        if jobs.size > 0
          jobs.each do |job|
            workers_pool.post { job.perform }
          end
        else
          sleep(1)
        end
      end
    end

    def clear_locks
    end

    def identifier
      "host:#{Socket.gethostname} pid:#{Process.pid}"
    rescue StandardError
      "pid:#{Process.pid}"
    end
end
