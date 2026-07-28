# frozen_string_literal: true

module SolidQueue
  class Job < Record
    class EnqueueError < StandardError; end

    include Executable, Clearable, Recurrable, Batchable

    serialize :arguments, coder: JSON

    class << self
      def enqueue_all(active_jobs)
        # Bulk enqueues bypass ActiveJob#enqueue, so batch membership is captured here
        current_batch_id = Batch.current_batch_id

        active_jobs.each do |job|
          job.scheduled_at ||= Time.current
          job.batch_id = current_batch_id || job.batch_id
        end

        if SolidQueue.sharded?
          active_jobs.group_by { |active_job| shard_for(active_job) }.each do |shard, jobs_in_shard|
            Record.connected_to(shard: shard) { enqueue_all_together(jobs_in_shard) }
          end
        else
          enqueue_all_together(active_jobs)
        end

        active_jobs.count(&:successfully_enqueued?)
      end

      def enqueue(active_job, scheduled_at: Time.current)
        active_job.scheduled_at = scheduled_at

        connected_to_shard_for(active_job) do
          create_from_active_job(active_job).tap do |enqueued_job|
            active_job.provider_job_id = enqueued_job.id if enqueued_job.persisted?
            active_job.successfully_enqueued = enqueued_job.persisted?
          end
        end
      end

      # The shard a job is enqueued in, where it will remain for its whole life.
      # Jobs with concurrency controls are distributed by their concurrency key,
      # so that jobs sharing a key land on the same shard and the unique indexes
      # that enforce their limits apply to all of them. Other jobs are distributed
      # uniformly by their Active Job ID; retried and resumed jobs keep it, so
      # they return to their shard.
      def shard_for(active_job)
        shard_key = active_job.concurrency_key.presence || active_job.job_id
        SolidQueue.shards[Zlib.crc32(shard_key.to_s) % SolidQueue.shards.size]
      end

      private
        DEFAULT_PRIORITY = 0
        DEFAULT_QUEUE_NAME = "default"

        def connected_to_shard_for(active_job, &block)
          if SolidQueue.sharded?
            Record.connected_to(shard: shard_for(active_job), &block)
          else
            block.call
          end
        end

        def enqueue_all_together(active_jobs)
          active_jobs_by_job_id = active_jobs.index_by(&:job_id)

          transaction do
            jobs = create_all_from_active_jobs(active_jobs)
            prepare_all_for_execution(jobs).each do |enqueued_job|
              active_jobs_by_job_id[enqueued_job.active_job_id].provider_job_id = enqueued_job.id
              active_jobs_by_job_id[enqueued_job.active_job_id].successfully_enqueued = true
            end
          end
        end

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
          }.tap do |attributes|
            attributes[:batch_id] = active_job.batch_id if Batch.migrated?
          end
        end
    end
  end
end
