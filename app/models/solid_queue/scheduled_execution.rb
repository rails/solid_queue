# frozen_string_literal: true

module SolidQueue
  class ScheduledExecution < Execution
    scope :due, -> { where(scheduled_at: ..Time.current) }
    scope :ordered, -> { order(scheduled_at: :asc, priority: :asc) }
    scope :next_batch, ->(batch_size) { due.ordered.limit(batch_size) }

    assume_attributes_from_job :scheduled_at

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
          with_concurrency_limits, without_concurrency_limits = jobs.partition(&:concurrency_limited?)

          dispatch_at_once(without_concurrency_limits)
          dispatch_one_by_one(with_concurrency_limits)

          successfully_dispatched(job_ids).tap do |dispatched_job_ids|
            where(job_id: dispatched_job_ids).delete_all
            SolidQueue.logger.info("[SolidQueue] Dispatched scheduled batch with #{dispatched_job_ids.size} jobs")
          end
        end

        def dispatch_at_once(jobs)
          ReadyExecution.insert_all ready_rows_from_batch(jobs)
        end

        def dispatch_one_by_one(jobs)
          jobs.each(&:dispatch)
        end

        def ready_rows_from_batch(jobs)
          prepared_at = Time.current

          jobs.map do |job|
            { job_id: job.id, queue_name: job.queue_name, priority: job.priority, created_at: prepared_at }
          end
        end

        def successfully_dispatched(job_ids)
          dispatched_and_ready(job_ids) + dispatched_and_blocked(job_ids)
        end

        def dispatched_and_ready(job_ids)
          ReadyExecution.where(job_id: job_ids).pluck(:job_id)
        end

        def dispatched_and_blocked(job_ids)
          BlockedExecution.where(job_id: job_ids).pluck(:job_id)
        end
    end
  end
end
