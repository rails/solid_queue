class SolidQueue::Dispatcher
  attr_accessor :queues, :worker_count, :workers_pool

  def initialize(**options)
    @queues = Array(options[:queues]).presence || [ "default" ]
    @worker_count = options[:worker_count] || 5
    @workers_pool = Concurrent::FixedThreadPool.new(@worker_count)
  end

  def start
    @stopping = false

    @thread = Thread.new { dispatch }
  end

  def dispatch
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

  def stop
    @stopping = true
    workers_pool.shutdown
    clear_locks
    wait
  end

  def stopping?
    @stopping
  end

  private
    def wait
      @thread&.join
    end

    def clear_locks
    end

    def identifier
      Process.pid
    end
end
