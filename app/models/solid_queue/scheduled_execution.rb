# frozen_string_literal: true

module SolidQueue
  class ScheduledExecution < Execution
    include Dispatching

    scope :due, -> { where(scheduled_at: ..Time.current) }
    scope :ordered, -> { order(scheduled_at: :asc, priority: :asc) }
    scope :next_batch, ->(batch_size) { due.ordered.limit(batch_size) }

    assumes_attributes_from_job :scheduled_at

    class << self
      def dispatch_next_batch(batch_size)
        transaction do
          job_ids = next_batch(batch_size).non_blocking_lock.pluck(:job_id)
          if job_ids.empty? then []
          else
            dispatch_batch(job_ids)
          end
        end
      end
    end
  end
end
