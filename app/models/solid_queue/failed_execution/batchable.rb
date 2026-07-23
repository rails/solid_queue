# frozen_string_literal: true

module SolidQueue
  class FailedExecution
    # Failed executions are only created once a job is done retrying — when it stops counting as pending in its batch
    module Batchable
      extend ActiveSupport::Concern

      included do
        after_create :destroy_job_batch_execution, if: -> { job.batch_id? }
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
