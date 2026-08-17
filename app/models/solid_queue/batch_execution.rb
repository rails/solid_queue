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
          rows = jobs.map { |job| row_from_job(batch_id, job) }

          # Increment first: inserting tracking rows takes a shared FK lock on
          # the batch row, then incrementing can deadlock concurrent MySQL adders.
          total = count_of_new_jobs(batch_id, rows)
          updated = SolidQueue::Batch.where(id: batch_id).unfinished.update_all([ "total_jobs = total_jobs + ?", total ])
          raise Batch::AlreadyFinished if updated.zero?

          BatchExecution.insert_all!(rows.map { |row| row.slice(:batch_id, :job_id) })
        end
      end

      private
        def row_from_job(batch_id, job)
          if job.respond_to?(:provider_job_id)
            { batch_id: batch_id, job_id: job.provider_job_id, active_job_id: job.job_id, retried: job.executions.positive? }
          else
            { batch_id: batch_id, job_id: job.id, active_job_id: job.active_job_id, retried: job.arguments["executions"].to_i.positive? }
          end
        end

        # total_jobs counts logical jobs while every attempt gets its own
        # tracking row: a retry re-enqueued via retry_on keeps its
        # active_job_id, so its previous attempt has already counted it. Only
        # jobs that have executed before pay the lookup; a first execution
        # can't have been counted yet.
        def count_of_new_jobs(batch_id, rows)
          active_job_ids = rows.map { |row| row[:active_job_id] }.uniq

          counted = if (retried = rows.select { |row| row[:retried] }).any?
            SolidQueue::Job.where(batch_id: batch_id, active_job_id: retried.map { |row| row[:active_job_id] })
              .where.not(id: rows.map { |row| row[:job_id] })
              .distinct.pluck(:active_job_id)
          else
            []
          end

          (active_job_ids - counted).size
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
