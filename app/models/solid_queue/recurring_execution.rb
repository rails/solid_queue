# frozen_string_literal: true

module SolidQueue
  class RecurringExecution < Execution
    class AlreadyRecorded < StandardError; end

    scope :clearable, -> { where.missing(:job) }

    class << self
      def record(task_key, run_at, &block)
        transaction do
          block.call.tap do |active_job|
            if active_job
              create!(job_id: active_job.provider_job_id, task_key: task_key, run_at: run_at)
            end
          end
        end
      rescue ActiveRecord::RecordNotUnique => e
        raise AlreadyRecorded
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
