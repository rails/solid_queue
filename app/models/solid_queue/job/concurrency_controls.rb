module SolidQueue
  class Job
    module ConcurrencyControls
      extend ActiveSupport::Concern

      included do
        has_one :blocked_execution, dependent: :destroy

        delegate :concurrency_limit, :concurrency_limit_duration, to: :job_class
      end

      def unblock_blocked_jobs
        if release_concurrency_lock
          release_next_blocked_job
        end
      end

      private
        def acquire_concurrency_lock
          return true unless concurrency_limited?

          Semaphore.wait_for(concurrency_key, concurrency_limit, concurrency_limit_duration)
        end

        def release_concurrency_lock
          return false unless concurrency_limited?

          Semaphore.release(concurrency_key, concurrency_limit, concurrency_limit_duration)
        end

        def block
          BlockedExecution.create_or_find_by!(job_id: id)
        end

        def release_next_blocked_job
          BlockedExecution.release_one(concurrency_key)
        end

        def concurrency_limited?
          concurrency_key.present? && concurrency_limit.to_i > 0
        end

        def job_class
          @job_class ||= class_name.safe_constantize
        end
    end
  end
end
