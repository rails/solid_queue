# frozen_string_literal: true

module SolidQueue
  class Job
    module ConcurrencyControls
      extend ActiveSupport::Concern

      included do
        has_one :blocked_execution

        delegate :concurrency_limit, :concurrency_duration, to: :job_class

        before_destroy :unblock_next_blocked_job, if: -> { concurrency_limited? && ready? }
      end

      class_methods do
        def release_all_concurrency_locks(jobs)
          Semaphore.signal_all(jobs.select(&:concurrency_limited?))
        end
      end

      def unblock_next_blocked_job
        if release_concurrency_lock
          release_next_blocked_job
        end
      end

      def concurrency_limited?
        concurrency_key.present?
      end

      def blocked?
        blocked_execution.present?
      end

      private
        def concurrency_on_conflict
          job_class.concurrency_on_conflict.to_s.inquiry
        end

        def acquire_concurrency_lock
          return true unless concurrency_limited?

          Semaphore.wait(self)
        end

        def release_concurrency_lock
          return false unless concurrency_limited?

          Semaphore.signal(self)
        end

        def handle_concurrency_conflict
          if concurrency_on_conflict.discard?
            destroy
          else
            block
          end
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

        def execution
          super || blocked_execution
        end
    end
  end
end
