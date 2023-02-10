# frozen_string_literal: true

module ActiveJob
  module QueueAdapters
    # == Active Job SolidQueue adapter
    #
    # To use it set the queue_adapter config to +:solid_queue+.
    #
    #   Rails.application.config.active_job.queue_adapter = :solid_queue
    class SolidQueueAdapter
      def enqueue(active_job) # :nodoc:
        SolidQueue::Job.enqueue_active_job(active_job).tap do |job|
          active_job.provider_job_id = job.id
        end
      end

      def enqueue_at(active_job, timestamp) # :nodoc:
        SolidQueue::Job.enqueue_active_job(active_job, scheduled_at: Time.at(timestamp)).tap do |job|
          active_job.provider_job_id = job.id
        end
      end
    end
  end
end
