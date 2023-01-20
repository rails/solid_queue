# frozen_string_literal: true

module ActiveJob
  module QueueAdapters
    # == Active Job SolidQueue adapter
    #
    # To use it set the queue_adapter config to +:solid_queue+.
    #
    #   Rails.application.config.active_job.queue_adapter = :solid_queue
    class SolidQueueAdapter
      def enqueue(job) # :nodoc:
        SolidQueue::Job.create!(queue_name: job.queue_name, priority: job.priority, arguments: job.serialize)
      end

      def enqueue_at(job, timestamp) # :nodoc:
        raise NotImplementedError, "Coming soon!"
      end
    end
  end
end
