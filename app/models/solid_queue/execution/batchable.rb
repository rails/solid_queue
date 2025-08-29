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
          BatchUpdateJob.perform_later(job.batch_id, job)
        rescue => e
          Rails.logger.error "[SolidQueue] Failed to notify batch #{batch_id} about job #{id} completion: #{e.message}"
        end
    end
  end
end
