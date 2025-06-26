# frozen_string_literal: true

module SolidQueue
  class BatchUpdateJob < ActiveJob::Base
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(batch_id, job_id)
      batch = Batch.find_by!(batch_id: batch_id)
      job = Job.find_by!(id: job_id)

      # Only process if the job is actually finished and belongs to this batch
      return unless job.finished? && job.batch_id == batch_id

      batch.job_finished!(job)
    rescue => e
      Rails.logger.error "[SolidQueue] BatchUpdateJob failed for batch #{batch_id}, job #{job_id}: #{e.message}"
      raise
    end
  end
end
