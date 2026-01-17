# frozen_string_literal: true

module SolidQueue
  class BatchExecution < Record
    belongs_to :job, optional: true
    belongs_to :batch

    after_commit :check_completion, on: :destroy

    private
      def check_completion
        batch = Batch.find_by(id: batch_id)
        batch.check_completion if batch.present?
      end

    class << self
      def create_all_from_jobs(jobs)
        batch_jobs = jobs.select { |job| job.batch_id.present? }
        return if batch_jobs.empty?

        batch_jobs.group_by(&:batch_id).each do |batch_id, jobs|
          BatchExecution.insert_all!(jobs.map { |job|
            { batch_id:, job_id: job.respond_to?(:provider_job_id) ? job.provider_job_id : job.id }
          })

          total = jobs.size
          SolidQueue::Batch.where(id: batch_id).update_all([ "total_jobs = total_jobs + ?", total ])
        end
      end
    end
  end
end
