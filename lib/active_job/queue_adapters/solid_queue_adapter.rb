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
        SolidQueue::Job.enqueue(active_job)
      end

      def enqueue_at(active_job, timestamp) # :nodoc:
        SolidQueue::Job.enqueue(active_job, scheduled_at: Time.at(timestamp))
      end

      def enqueue_all(active_jobs) # :nodoc:
        SolidQueue::Job.enqueue_all(active_jobs)
      end
    end
  end
end
