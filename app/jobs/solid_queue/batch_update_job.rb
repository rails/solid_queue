# frozen_string_literal: true

module SolidQueue
  class BatchUpdateJob < ActiveJob::Base
    class UpdateFailure < RuntimeError; end

    queue_as :background

    discard_on ActiveRecord::RecordNotFound

    def perform(batch_id, job)
      batch = SolidQueue::BatchRecord.find_by!(batch_id: batch_id)

      return if job.batch_id != batch_id

      status = job.status
      return unless status.in?([ :finished, :failed ])

      batch.job_finished!(job)
    rescue => e
      Rails.logger.error "[SolidQueue] BatchUpdateJob failed for batch #{batch_id}, job #{job.id}: #{e.message}"
      raise
    end
  end
end
