class SolidQueue::ClaimedExecution < SolidQueue::Execution
  def self.claim_batch(job_ids)
    claimed_at = Time.current
    rows = job_ids.map { |id| { job_id: id, created_at: claimed_at } }
    insert_all(rows) if rows.any?

    SolidQueue.logger.info("[SolidQueue] Claimed #{rows.size} jobs at #{claimed_at}")
  end

  def perform
    execute
    finished
  rescue Exception => e
    failed_with(e)
  end

  private
    def execute
      SolidQueue.logger.info("[SolidQueue] Performing job #{job.id} - #{job.active_job_id}")

      ActiveJob::Base.execute(job.arguments)
    end

    def finished
      transaction do
        job.finished
        destroy!
      end

      SolidQueue.logger.info("[SolidQueue] Performed job #{job.id} - #{job.active_job_id}")
    end

    def failed_with(error)
      transaction do
        job.failed_with(error)
        destroy!
      end

      SolidQueue.logger.info("[SolidQueue] Failed job #{job.id} - #{job.active_job_id}")
    end
end
