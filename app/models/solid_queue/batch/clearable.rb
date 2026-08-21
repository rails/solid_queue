# frozen_string_literal: true

module SolidQueue
  class Batch
    module Clearable
      extend ActiveSupport::Concern

      included do
        scope :clearable, ->(finished_before: SolidQueue.clear_finished_jobs_after.ago) { where.not(finished_at: nil).where(finished_at: ...finished_before).where(failed_at: nil) }
      end

      class_methods do
        def clear_finished_in_batches(batch_size: 500, finished_before: SolidQueue.clear_finished_jobs_after.ago, sleep_between_batches: 0)
          loop do
            records_deleted = clearable(finished_before: finished_before).limit(batch_size).delete_all
            sleep(sleep_between_batches) if sleep_between_batches > 0
            break if records_deleted == 0
          end
        end
      end
    end
  end
end
