class SolidQueue::Dispatcher
  attr_accessor :queues, :worker_count, :workers_pool

  def initialize(**options)
    @queues = Array(options[:queues]).presence || [ "default" ]
    @worker_count = options[:worker_count] || 10
    @workers_pool = Concurrent::FixedThreadPool.new(@worker_count)
  end

  def start
    @stopping = false

    @thread = Thread.new { dispatch }
  end

  def dispatch
    count = Concurrent::AtomicFixnum.new(0)

    loop do
      break if stopping?

      jobs = claim_jobs

      if jobs.size > 0
        jobs.each do |job|
          puts "Posting #{job.id} to workers pool"
          workers_pool.post { job.perform; count.increment }
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

    def claim_jobs
      candidate_ids = []

      transaction do
        candidate_ids = query_candidates
        lock candidate_ids
      end

      claimed_jobs_among candidate_ids
    end

    def claimed_jobs_among(job_ids)
      SolidQueue::Job.where(id: job_ids, claimed_by: identifier).limit(worker_count)
    end

    def lock(job_ids)
      SolidQueue::Job.ready(queues).where(id: job_ids).update_all(claimed_by: identifier, claimed_at: Time.current)
    end

    def clear_locks
      SolidQueue::Job.where(claimed_by: identifier).update_all(claimed_by: nil, claimed_at: nil)
    end

    def query_candidates
      SolidQueue::Job.ready(queues).limit(worker_count).lock("FOR UPDATE SKIP LOCKED").select(:id).to_a
    end

    def identifier
      Process.pid
    end

    def transaction(&block)
      SolidQueue::Job.transaction(&block)
    end
end
