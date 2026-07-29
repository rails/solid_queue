# frozen_string_literal: true

module SolidQueue
  class BatchExecution < Record
    belongs_to :job, optional: true
    belongs_to :batch

    scope :for_finished_jobs, -> { joins(:job).merge(SolidQueue::Job.finished) }
    scope :for_failed_jobs, -> { joins(job: :failed_execution) }

    after_commit :check_completion, on: :destroy

    class << self
      def create_all_from_jobs(jobs)
        batch_jobs = jobs.select { |job| job.batch_id.present? }
        return if batch_jobs.empty?

        batch_jobs.group_by(&:batch_id).each do |batch_id, jobs|
          # Increment first: inserting tracking rows takes a shared FK lock on
          # the batch row, then incrementing can deadlock concurrent MySQL adders.
          total = jobs.size
          updated = SolidQueue::Batch.where(id: batch_id).unfinished.update_all([ "total_jobs = total_jobs + ?", total ])
          raise Batch::AlreadyFinished if updated.zero?

          BatchExecution.insert_all!(jobs.map { |job|
            { batch_id:, job_id: job.respond_to?(:provider_job_id) ? job.provider_job_id : job.id }
          })
        end
      end
    end

    private
      def check_completion
        # Skip the serialized callback and metadata columns on this hot path
        batch = Batch.select(:id, :finished_at, :enqueued_at).find_by(id: batch_id)
        batch.check_completion if batch.present?
      end
  end
end
