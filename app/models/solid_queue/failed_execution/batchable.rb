# frozen_string_literal: true

module SolidQueue
  class FailedExecution
    # A FailedExecution is created only after retries are exhausted, when the
    # job stops counting as pending in its batch.
    module Batchable
      extend ActiveSupport::Concern

      included do
        after_create :destroy_job_batch_execution, if: -> { Batch.migrated? && job.batch_id? }
      end

      private
        def destroy_job_batch_execution
          job.batch_execution&.destroy!
        rescue ActiveRecord::ActiveRecordError => e
          SolidQueue.instrument(:batch_progress_error, batch_id: job.batch_id, job_id: job.id, error: e)
        end
    end
  end
end
