# frozen_string_literal: true

module ActiveJob
  module QueueAdapters
    # == Active Job SolidQueue adapter
    #
    # To use it set the queue_adapter config to +:solid_queue+.
    #
    #   Rails.application.config.active_job.queue_adapter = :solid_queue
    class SolidQueueAdapter
      def initialize(db_shard: nil)
        @db_shard = db_shard
      end

      def enqueue_after_transaction_commit?
        true
      end

      def enqueue(active_job) # :nodoc:
        select_shard { SolidQueue::Job.enqueue(active_job) }
      end

      def enqueue_at(active_job, timestamp) # :nodoc:
        select_shard do
          SolidQueue::Job.enqueue(active_job, scheduled_at: Time.at(timestamp))
        end
      end

      def enqueue_all(active_jobs) # :nodoc:
        select_shard { SolidQueue::Job.enqueue_all(active_jobs) }
      end

      private

      def select_shard
        if @db_shard
          ActiveRecord::Base.connected_to(shard: @db_shard) { yield }
        else
          yield
        end
      end
    end
  end
end
