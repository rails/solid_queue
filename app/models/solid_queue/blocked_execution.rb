# frozen_string_literal: true

module SolidQueue
  class BlockedExecution < Execution
    assumes_attributes_from_job :concurrency_key
    before_create :set_expires_at

    has_one :semaphore, foreign_key: :key, primary_key: :concurrency_key

    scope :expired, -> { where(expires_at: ...Time.current) }

    class << self
      def unblock(limit)
        SolidQueue.instrument(:release_many_blocked, limit: limit) do |payload|
          expired.distinct.limit(limit).pluck(:concurrency_key).then do |concurrency_keys|
            payload[:size] = release_many releasable(concurrency_keys)
          end
        end
      end

      def release_many(concurrency_keys)
        # We want to release exactly one blocked execution for each concurrency key, and we need to do it
        # one by one, locking each record and acquiring the semaphore individually for each of them:
        Array(concurrency_keys).count { |concurrency_key| release_one(concurrency_key) }
      end

      def release_one(concurrency_key)
        transaction do
          if execution = ordered.where(concurrency_key: concurrency_key).limit(1).non_blocking_lock.first
            execution.release
          end
        end
      end

      private
        def releasable(concurrency_keys)
          semaphores = Semaphore.where(key: concurrency_keys).pluck(:key, :value).to_h

          # Concurrency keys without semaphore + concurrency keys with open semaphore
          (concurrency_keys - semaphores.keys) | semaphores.select { |_key, value| value > 0 }.keys
        end
    end

    def release
      SolidQueue.instrument(:release_blocked, job_id: job.id, concurrency_key: concurrency_key, released: false) do |payload|
        transaction do
          if acquire_concurrency_lock
            promote_to_ready
            destroy!

            payload[:released] = true
          end
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
