# frozen_string_literal: true

module SolidQueue
  class Execution
    module Batchable
      extend ActiveSupport::Concern

      included do
        after_create :update_batch_progress, if: -> { job.batch_id? }
      end

      private
        def update_batch_progress
          # FailedExecutions are only created when the job is done retrying
          if is_a?(FailedExecution)
            BatchExecution.process_job_completion(job, "failed")
          end
        rescue => e
          Rails.logger.error "[SolidQueue] Failed to notify batch #{job.batch_id} about job #{job.id} failure: #{e.message}"
        end
    end
  end
end
