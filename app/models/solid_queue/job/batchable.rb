# frozen_string_literal: true

module SolidQueue
  class Job
    module Batchable
      extend ActiveSupport::Concern

      included do
        belongs_to :batch, optional: true
        has_one :batch_execution, foreign_key: :job_id, dependent: :destroy

        after_create :create_batch_execution, if: :batch_id?
        after_update :update_batch_progress, if: :batch_id?
      end

      class_methods do
        def batch_all(jobs)
          BatchExecution.create_all_from_jobs(jobs)
        end
      end

      private
        def create_batch_execution
          BatchExecution.create_all_from_jobs([ self ])
        end

        def update_batch_progress
          return unless saved_change_to_finished_at? && finished_at.present?
          return unless batch_id.present?

          batch_execution&.destroy!
        rescue ActiveRecord::ActiveRecordError => e
          SolidQueue.instrument(:batch_progress_error, batch_id: batch_id, job_id: id, error: e)
        end
    end
  end
end
