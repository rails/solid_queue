# frozen_string_literal: true

module SolidQueue
  class BlockedExecution < Execution
    assume_attributes_from_job :concurrency_key
    before_create :set_expires_at

    has_one :semaphore, foreign_key: :key, primary_key: :concurrency_key

    scope :expired, -> { where(expires_at: ...Time.current) }

    class << self
      def unblock(count)
        expired.distinct.limit(count).pluck(:concurrency_key).then do |concurrency_keys|
          release_many releasable(concurrency_keys)
        end
      end

      def release_many(concurrency_keys)
        # We want to release exactly one blocked execution for each concurrency key, and we need to do it
        # one by one, locking each record and acquiring the semaphore individually for each of them:
        Array(concurrency_keys).each { |concurrency_key| release_one(concurrency_key) }
      end

      def release_one(concurrency_key)
        transaction do
          ordered.where(concurrency_key: concurrency_key).limit(1).non_blocking_lock.each(&:release)
        end
      end

      private
        def releasable(concurrency_keys)
          semaphores = Semaphore.where(key: concurrency_keys).select(:key, :value).index_by(&:key)

          # Concurrency keys without semaphore + concurrency keys with open semaphore
          (concurrency_keys - semaphores.keys) | semaphores.select { |key, semaphore| semaphore.value > 0 }.map(&:first)
        end
    end

    def release
      transaction do
        if acquire_concurrency_lock
          promote_to_ready
          destroy!

          SolidQueue.logger.info("[SolidQueue] Unblocked job #{job.id} under #{concurrency_key}")
        end
      end
    end

    private
      def set_expires_at
        self.expires_at = job.concurrency_duration.from_now
      end

      def acquire_concurrency_lock
        Semaphore.wait(job)
      end

      def promote_to_ready
        ReadyExecution.create!(ready_attributes)
      end

      def ready_attributes
        attributes.slice("job_id", "queue_name", "priority")
      end
  end
end
