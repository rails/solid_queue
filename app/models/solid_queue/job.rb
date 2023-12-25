# frozen_string_literal: true

class SolidQueue::Job < SolidQueue::Record
  include Executable

  if Gem::Version.new(Rails.version) >= Gem::Version.new("7.1")
    serialize :arguments, coder: JSON
  else
    serialize :arguments, JSON
  end

  DEFAULT_PRIORITY = 0
  DEFAULT_QUEUE_NAME = "default"

  class << self
    def enqueue_all_active_jobs(active_jobs)
      scheduled_jobs, immediate_jobs = active_jobs.partition(&:scheduled_at)
      with_concurrency_limits, without_concurrency_limits = immediate_jobs.partition(&:concurrency_limited?)

      with_concurrency_limits.each do |active_job|
        enqueue_active_job(active_job)
      end

      transaction do
        job_rows = scheduled_jobs.map { |job| attributes_from_active_job(job) }
        insert_all(job_rows)
        inserted_jobs = where(active_job_id: scheduled_jobs.map(&:job_id))
        SolidQueue::ScheduledExecution.create_all_from_jobs(inserted_jobs)
      end

      transaction do
        job_rows = without_concurrency_limits.map { |job| attributes_from_active_job(job) }
        insert_all(job_rows)
        inserted_jobs = where(active_job_id: without_concurrency_limits.map(&:job_id))
        SolidQueue::ReadyExecution.create_all_from_jobs(inserted_jobs)
      end
    end

    def enqueue_active_job(active_job, scheduled_at: Time.current)
      enqueue **attributes_from_active_job(active_job).reverse_merge(scheduled_at: scheduled_at)
    end

    private
      def enqueue(**kwargs)
        create!(**kwargs).tap do
          SolidQueue.logger.debug "[SolidQueue] Enqueued job #{kwargs}"
        end
      end

      def attributes_from_active_job(active_job)
        {
          queue_name: active_job.queue_name,
          active_job_id: active_job.job_id,
          priority: active_job.priority,
          scheduled_at: active_job.scheduled_at,
          class_name: active_job.class.name,
          arguments: active_job.serialize,
          concurrency_key: active_job.concurrency_key
        }.compact.with_defaults(defaults)
      end

      def defaults
        { queue_name: DEFAULT_QUEUE_NAME, priority: DEFAULT_PRIORITY }
      end
  end
end
