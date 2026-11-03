# frozen_string_literal: true

module SolidQueue
  class Job
    module ConcurrencyControls
      extend ActiveSupport::Concern

      # Stored in the job's serialized Active Job data, which Active Job ignores when running the job
      CONCURRENCY_LOCK_KEY = "solid_queue_concurrency_lock"

      included do
        has_one :blocked_execution

        before_destroy :unblock_next_blocked_job, if: -> { concurrency_limited? && ready? }
      end

      class_methods do
        def unblock_next_blocked_jobs(jobs)
          jobs.find_each(&:unblock_next_blocked_job)
        end
      end

      def unblock_next_blocked_job
        if release_concurrency_lock
          release_next_blocked_job
        end
      end

      def acquire_concurrency_lock
        return true unless concurrency_limited?

        if job_class.nil?
          # A job whose class doesn't load skips its limits. Record that it holds no slot,
          # so it doesn't give one back if it runs somewhere its class does load.
          record_concurrency_lock(semaphore_id: nil)
        elsif semaphore_id = Semaphore.wait(self)
          record_concurrency_lock(semaphore_id:, limit: concurrency_limit)
        end
      end

      def concurrency_limited?
        concurrency_key.present?
      end

      # A job that kept its concurrency key after its class dropped limits_concurrency gets a limit of 1
      def concurrency_limit
        job_class.concurrency_limit || 1 if concurrency_limited?
      end

      def concurrency_duration
        job_class ? job_class.concurrency_duration : SolidQueue.default_concurrency_control_period
      end

      # The semaphore the job got its concurrency slot from
      def acquired_semaphore_id
        concurrency_lock&.dig("semaphore_id")
      end

      # The concurrency limit the job had when it got its slot
      def acquired_concurrency_limit
        concurrency_lock&.dig("limit")
      end

      def blocked?
        blocked_execution.present?
      end

      def job_class
        @job_class ||= class_name.safe_constantize
      end

      private
        def release_concurrency_lock
          holds_concurrency_slot? && Semaphore.signal(self)
        end

        def holds_concurrency_slot?
          if concurrency_lock_recorded?
            acquired_semaphore_id.present?
          else
            # Jobs dispatched before Solid Queue recorded their semaphore, which need their class to know their limit
            concurrency_limited? && job_class.present?
          end
        end

        def concurrency_lock_recorded?
          arguments.key?(CONCURRENCY_LOCK_KEY)
        end

        def release_next_blocked_job
          BlockedExecution.release_one(concurrency_key)
        end

        def record_concurrency_lock(semaphore_id:, limit: nil)
          arguments[CONCURRENCY_LOCK_KEY] = { "semaphore_id" => semaphore_id, "limit" => limit }
          update_column :arguments, arguments
          true
        end

        def concurrency_lock
          arguments[CONCURRENCY_LOCK_KEY]
        end

        def handle_concurrency_conflict
          if concurrency_on_conflict.discard?
            destroy
          else
            block
          end
        end

        def concurrency_on_conflict
          job_class.concurrency_on_conflict.to_s.inquiry
        end

        def block
          BlockedExecution.create_or_find_by!(job: self)
        end

        def execution
          super || blocked_execution
        end
    end
  end
end
