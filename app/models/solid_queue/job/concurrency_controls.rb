module SolidQueue
  class Job
    module ConcurrencyControls
      extend ActiveSupport::Concern

      included do
        has_one :blocked_execution, dependent: :destroy
      end

      def unblock_blocked_jobs
        if release_concurrency_lock
          release_next_blocked_job
        end
      end

      private
        def acquire_concurrency_lock
          return true unless concurrency_limited?

          Semaphore.wait_for(concurrency_key, concurrency_limit)
        end

        def release_concurrency_lock
          return false unless concurrency_limited?

          Semaphore.release(concurrency_key, concurrency_limit)
        end

        def block
          BlockedExecution.create_or_find_by!(job_id: id)
        end

        def release_next_blocked_job
          BlockedExecution.release(concurrency_key)
        end

        def concurrency_limited?
          concurrency_limit.to_i > 0 && concurrency_key.present?
        end
    end
  end
end
