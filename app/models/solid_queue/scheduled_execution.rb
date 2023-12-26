# frozen_string_literal: true

module SolidQueue
  class ScheduledExecution < Execution
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

      private
        def dispatch_batch(job_ids)
          jobs = Job.where(id: job_ids)

          Job.dispatch_all(jobs).map(&:id).tap do |dispatched_job_ids|
            where(job_id: dispatched_job_ids).delete_all
            SolidQueue.logger.info("[SolidQueue] Dispatched scheduled batch with #{dispatched_job_ids.size} jobs")
          end
        end
    end
  end
end
