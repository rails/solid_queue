# frozen_string_literal: true

module SolidQueue
  class Job
    module Batchable
      extend ActiveSupport::Concern

      included do
        belongs_to :job_batch, foreign_key: :batch_id, optional: true

        after_update :update_batch_progress, if: :batch_id?
      end

      private
        def update_batch_progress
          return unless saved_change_to_finished_at? && finished_at.present?
          return unless batch_id.present?

          BatchUpdateJob.perform_later(batch_id, self)
        rescue => e
          Rails.logger.error "[SolidQueue] Failed to notify batch #{batch_id} about job #{id} completion: #{e.message}"
        end
    end
  end
end
