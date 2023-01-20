class SolidQueue::Dispatcher
  attr_accessor :queues, :worker_count

  def self.start
    new("background").dispatch
  end

  def initialize(queues)
    @queues = Array(queues)
    @worker_count = 10
  end

  def dispatch
    loop do
      jobs = next_batch
      if jobs.any?
        jobs.each(&:perform)
      else
        sleep(5)
      end
    end
  end

  private
    def next_batch
      transaction do
        claim_jobs
        claimed_jobs
      end
    end

    def claim_jobs
      lock candidate_ids
    end

    def claimed_jobs
      SolidQueue::Job.where(claimed_by: identifier)
    end

    def lock(job_ids)
      SolidQueue::Job.where(id: job_ids).update_all(claimed_by: identifier, claimed_at: Time.current)
    end

    def candidate_ids
      SolidQueue::Job.pending.in_queue(queues).by_priority.limit(worker_count).lock("FOR UPDATE SKIP LOCKED").select(:id).to_a
    end

    def identifier
      Process.pid
    end

    def transaction(&block)
      SolidQueue::Job.transaction(&block)
    end
end
