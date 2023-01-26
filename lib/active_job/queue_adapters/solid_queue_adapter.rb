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
        SolidQueue::Job.enqueue(queue_name: active_job.queue_name, priority: active_job.priority, arguments: active_job.serialize).tap do |job|
          active_job.provider_job_id = job.id
        end
      end

      def enqueue_at(job, timestamp) # :nodoc:
        raise NotImplementedError, "Coming soon!"
      end
    end
  end
end
