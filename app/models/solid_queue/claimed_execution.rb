class SolidQueue::ClaimedExecution < SolidQueue::Execution
  def self.claim_batch(job_ids)
    rows = job_ids.map { |id| { job_id: id, created_at: Time.current } }
    insert_all(rows) if rows.any?
  end

  def perform
    execute
    finished
  rescue Exception => e
    failed_with(e)
  end

  private
    def execute
      ActiveJob::Base.execute(job.arguments)
    end

    def finished
      transaction do
        job.finished
        destroy!
      end
    end

    def failed_with(error)
      transaction do
        job.failed_with(error)
        destroy!
      end
    end
end
