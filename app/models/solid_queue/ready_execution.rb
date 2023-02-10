class SolidQueue::ReadyExecution < SolidQueue::Execution
  scope :queued_as, ->(queues) { where(queue_name: queues) }
  scope :ordered, -> { order(priority: :asc) }

  before_create :assume_attributes_from_job

  class << self
    def claim(queues, limit)
      candidate_job_ids = []

      transaction do
        candidate_job_ids = query_candidates(queues, limit)
        lock(candidate_job_ids)
      end

      claimed_executions_for(candidate_job_ids)
    end

    private
      def query_candidates(queues, limit)
        queued_as(queues).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:job_id)
      end

      def lock(job_ids)
        return nil if job_ids.none?

        SolidQueue::ClaimedExecution.claim_batch(job_ids)
        where(job_id: job_ids).delete_all
      end

      def claimed_executions_for(job_ids)
        return [] if job_ids.none?

        SolidQueue::ClaimedExecution.where(job_id: job_ids)
      end
  end
end
