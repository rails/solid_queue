# frozen_string_literal: true

module SolidQueue
  class Job
    module Batchable
      extend ActiveSupport::Concern

      included do
        belongs_to :batch, foreign_key: :batch_id, primary_key: :batch_id, class_name: "SolidQueue::Batch", optional: true
        has_one :batch_execution, foreign_key: :job_id, dependent: :destroy

        after_update :update_batch_progress, if: :batch_id?
      end

      private
        def update_batch_progress
          return unless saved_change_to_finished_at? && finished_at.present?
          return unless batch_id.present?

          # Jobs marked as finished are considered completed
          # (even if they failed and are being retried - we don't know that here)
          BatchExecution.process_job_completion(self, "completed")
        rescue => e
          Rails.logger.error "[SolidQueue] Failed to update batch #{batch_id} progress for job #{id}: #{e.message}"
        end
    end
  end
end
