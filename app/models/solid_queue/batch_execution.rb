# frozen_string_literal: true

module SolidQueue
  class BatchExecution < Record
    belongs_to :job, optional: true
    belongs_to :batch, foreign_key: :batch_id, primary_key: :batch_id

    class << self
      def track_job_creation(active_jobs, batch_id)
        execution_data = Array.wrap(active_jobs).map do |active_job|
          {
            job_id: active_job.provider_job_id,
            batch_id: batch_id
          }
        end

        SolidQueue::BatchExecution.insert_all(execution_data)
      end

      def process_job_completion(job, status)
        batch_id = job.batch_id
        batch_execution = job.batch_execution

        return if batch_execution.blank?

        transaction do
          batch_execution.destroy!

          if status == "failed"
            Batch.where(batch_id: batch_id).update_all(
              "pending_jobs = pending_jobs - 1, failed_jobs = failed_jobs + 1"
            )
          else
            Batch.where(batch_id: batch_id).update_all(
              "pending_jobs = pending_jobs - 1, completed_jobs = completed_jobs + 1"
            )
          end
        end

        batch = Batch.find_by(batch_id: batch_id)
        batch&.check_completion!
      end
    end
  end
end
