# frozen_string_literal: true

module SolidQueue
  class BatchExecution < Record
    belongs_to :job, optional: true
    belongs_to :batch, foreign_key: :batch_id, primary_key: :batch_id

    class << self
      def create_all_from_jobs(jobs)
        batch_jobs = jobs.select { |job| job.batch_id.present? }
        return if batch_jobs.empty?

        batch_jobs.group_by(&:batch_id).each do |batch_id, jobs|
          BatchExecution.insert_all!(jobs.map { |job|
            { batch_id:, job_id: job.respond_to?(:provider_job_id) ? job.provider_job_id : job.id }
          })

          total = jobs.size
          SolidQueue::Batch.upsert(
            { batch_id:, total_jobs: total, pending_jobs: total },
            on_duplicate: Arel.sql(
              "total_jobs = total_jobs + #{total}, pending_jobs = pending_jobs + #{total}"
            )
          )
        end
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
