# frozen_string_literal: true

module SolidQueue
  class Job < Record
    class EnqueueError < ActiveJob::EnqueueError; end

    include Executable, Clearable, Recurrable

    serialize :arguments, coder: JSON

    class << self
      def enqueue_all(active_jobs)
        enqueued_jobs_count = 0

        transaction do
          jobs = create_all_from_active_jobs(active_jobs)
          prepare_all_for_execution(jobs)
          jobs_by_active_job_id = jobs.index_by(&:active_job_id)

          active_jobs.each do |active_job|
            job = jobs_by_active_job_id[active_job.job_id]

            active_job.provider_job_id = job&.id
            active_job.enqueue_error = job&.enqueue_error
            active_job.successfully_enqueued = job.present? && job.enqueue_error.nil?
            enqueued_jobs_count += 1 if active_job.successfully_enqueued?
          end
        end

        enqueued_jobs_count
      end

      def enqueue(active_job, scheduled_at: Time.current)
        active_job.scheduled_at = scheduled_at

        create_from_active_job(active_job).tap do |enqueued_job|
          active_job.provider_job_id = enqueued_job.id
        end
      end

      private
        DEFAULT_PRIORITY = 0
        DEFAULT_QUEUE_NAME = "default"

        def create_from_active_job(active_job)
          create!(**attributes_from_active_job(active_job))
        rescue ActiveRecord::ActiveRecordError => e
          enqueue_error = EnqueueError.new("#{e.class.name}: #{e.message}").tap do |error|
            error.set_backtrace e.backtrace
          end
          raise enqueue_error
        end

        def create_all_from_active_jobs(active_jobs)
          job_rows = active_jobs.map { |job| attributes_from_active_job(job) }
          insert_all(job_rows)
          where(active_job_id: active_jobs.map(&:job_id)).order(id: :asc)
        end

        def attributes_from_active_job(active_job)
          {
            queue_name: active_job.queue_name || DEFAULT_QUEUE_NAME,
            active_job_id: active_job.job_id,
            priority: active_job.priority || DEFAULT_PRIORITY,
            scheduled_at: active_job.scheduled_at,
            class_name: active_job.class.name,
            arguments: active_job.serialize,
            concurrency_key: active_job.concurrency_key
          }
        end
    end
  end
end
