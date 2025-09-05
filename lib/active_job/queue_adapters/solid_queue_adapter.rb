# frozen_string_literal: true

module ActiveJob
  module QueueAdapters
    # == Active Job SolidQueue adapter
    #
    # To use it set the queue_adapter config to +:solid_queue+.
    #
    #   Rails.application.config.active_job.queue_adapter = :solid_queue
    class SolidQueueAdapter < (Rails::VERSION::MAJOR == 7 && Rails::VERSION::MINOR == 1 ? Object : AbstractAdapter)
      class_attribute :stopping, default: false, instance_writer: false
      SolidQueue.on_worker_stop { self.stopping = true }

      def enqueue_after_transaction_commit?
        true
      end

      def enqueue(active_job) # :nodoc:
        return if in_batch?(active_job)

        SolidQueue::Job.enqueue(active_job).tap do |enqueued_job|
          increment_job_count(active_job, enqueued_job)
        end
      end

      def enqueue_at(active_job, timestamp) # :nodoc:
        return if in_batch?(active_job)

        SolidQueue::Job.enqueue(active_job, scheduled_at: Time.at(timestamp)).tap do |enqueued_job|
          increment_job_count(active_job, enqueued_job)
        end
      end

      def enqueue_all(active_jobs) # :nodoc:
        SolidQueue::Job.enqueue_all(active_jobs)
      end

      private

        def in_batch?(active_job)
          active_job.batch_id.present? && active_job.executions <= 0
        end

        def in_batch_retry?(active_job)
          active_job.batch_id.present? && active_job.executions > 0
        end

        def increment_job_count(active_job, enqueued_job)
          if enqueued_job.persisted? && in_batch_retry?(active_job)
            SolidQueue::BatchExecution.track_job_creation(active_job, active_job.batch_id)
            SolidQueue::Batch.update_job_count(active_job.batch_id, 1)
          end
        end
    end
  end
end
