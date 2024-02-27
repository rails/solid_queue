# frozen_string_literal: true

module SolidQueue
  class RecurringExecution < Execution
    scope :clearable, -> { where.missing(:job) }

    class << self
      def record(task_key, run_at, &block)
        transaction do
          if job_id = block.call
            create!(job_id: job_id, task_key: task_key, run_at: run_at)
          end
        end
      rescue ActiveRecord::RecordNotUnique
        SolidQueue.logger.info("[SolidQueue] Skipped recurring task #{task_key} at #{run_at} — already dispatched")
      end

      def clear_in_batches(batch_size: 500)
        loop do
          records_deleted = clearable.limit(batch_size).delete_all
          break if records_deleted == 0
        end
      end
    end
  end
end
