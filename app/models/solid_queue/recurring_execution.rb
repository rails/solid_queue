# frozen_string_literal: true

module SolidQueue
  class RecurringExecution < Execution
    def self.record(task_key, run_at, &block)
      transaction do
        if job_id = block.call
          create!(job_id: job_id, task_key: task_key, run_at: run_at)
        end
      end
    rescue ActiveRecord::RecordNotUnique
      SolidQueue.logger.info("[SolidQueue] Skipped recurring task #{task_key} at #{run_at} — already dispatched")
    end
  end
end
