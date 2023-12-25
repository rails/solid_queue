# frozen_string_literal: true

module SolidQueue
  class Job < Record
    include Executable

    if Gem::Version.new(Rails.version) >= Gem::Version.new("7.1")
      serialize :arguments, coder: JSON
    else
      serialize :arguments, JSON
    end

    class << self
      def enqueue_all(active_jobs)
        scheduled_jobs, immediate_jobs = active_jobs.partition(&:scheduled_at)
        with_concurrency_limits, without_concurrency_limits = immediate_jobs.partition(&:concurrency_limited?)

        schedule_all_at_once(scheduled_jobs)
        enqueue_all_at_once(without_concurrency_limits)
        enqueue_one_by_one(with_concurrency_limits)
      end

      def schedule_all_at_once(active_jobs)
        transaction do
          inserted_jobs = create_all_from_active_jobs(active_jobs)
          schedule_all(inserted_jobs)
        end
      end

      def enqueue_all_at_once(active_jobs)
        transaction do
          inserted_jobs = create_all_from_active_jobs(active_jobs)
          dispatch_all_at_once(inserted_jobs)
        end
      end

      def enqueue_one_by_one(active_jobs)
        active_jobs.each { |active_job| enqueue(active_job) }
      end

      def enqueue(active_job, scheduled_at: Time.current)
        create!(**attributes_from_active_job(active_job).reverse_merge(scheduled_at: scheduled_at)).tap do |job|
          active_job.provider_job_id = job.id
        end
      end

      private
        DEFAULT_PRIORITY = 0
        DEFAULT_QUEUE_NAME = "default"

        def create_all_from_active_jobs(active_jobs)
          job_rows = active_jobs.map { |job| attributes_from_active_job(job) }
          insert_all(job_rows)
          where(active_job_id: active_jobs.map(&:job_id))
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
end
