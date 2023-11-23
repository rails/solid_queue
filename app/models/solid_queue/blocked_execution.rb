module SolidQueue
  class BlockedExecution < SolidQueue::Execution
    assume_attributes_from_job :concurrency_key

    has_one :semaphore, foreign_key: :key, primary_key: :concurrency_key

    scope :releasable, -> { left_outer_joins(:semaphore).merge(Semaphore.available.or(Semaphore.where(id: nil))) }

    class << self
      def unblock(count)
        release_many releasable.select(:concurrency_key).distinct.limit(count).pluck(:concurrency_key)
      end

      def release_many(concurrency_keys)
        # We want to release exactly one blocked execution for each concurrency key, and we need to do it
        # one by one, locking each record and acquiring the semaphore individually for each of them:
        Array(concurrency_keys).each { |concurrency_key| release_one(concurrency_key) }
      end

      def release_one(concurrency_key)
        ordered.where(concurrency_key: concurrency_key).limit(1).lock("FOR UPDATE SKIP LOCKED").each(&:release)
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
      def acquire_concurrency_lock
        Semaphore.wait(job)
      end

      def promote_to_ready
        ReadyExecution.create!(ready_attributes)
      end
  end
end