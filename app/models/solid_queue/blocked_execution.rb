module SolidQueue
  class BlockedExecution < SolidQueue::Execution
    assume_attributes_from_job :concurrency_limit, :concurrency_key

    has_one :semaphore, foreign_key: :identifier, primary_key: :concurrency_key

    scope :releasable, -> { joins(:semaphore).merge(Semaphore.available) }
    scope :ordered, -> { order(priority: :asc) }

    class << self
      def release(concurrency_key)
        ordered.where(concurrency_key: concurrency_key).limit(1).lock("FOR UPDATE SKIP LOCKED").each(&:release)
      end
    end

    def release
      transaction do
        if acquire_concurrency_lock
          promote_to_ready
          destroy!
        end
      end
    end

    private
      def acquire_concurrency_lock
        Semaphore.wait_for(concurrency_key, concurrency_limit)
      end

      def promote_to_ready
        ReadyExecution.create_or_find_by!(job_id: job_id)
      end
  end
end
