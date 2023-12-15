# frozen_string_literal: true

module SolidQueue
  class Job
    module ConcurrencyControls
      extend ActiveSupport::Concern

      included do
        has_one :blocked_execution, dependent: :destroy

        delegate :concurrency_limit, :concurrency_duration, to: :job_class
      end

      def unblock_next_blocked_job
        if release_concurrency_lock
          release_next_blocked_job
        end
      end

      def concurrency_limited?
        concurrency_key.present?
      end

      private
        def acquire_concurrency_lock
          return true unless concurrency_limited?

          Semaphore.wait(self)
        end

        def release_concurrency_lock
          return false unless concurrency_limited?

          Semaphore.signal(self)
        end

        def block
          BlockedExecution.create_or_find_by!(job_id: id)
        end

        def release_next_blocked_job
          BlockedExecution.release_one(concurrency_key)
        end

        def job_class
          @job_class ||= class_name.safe_constantize
        end
    end
  end
end
