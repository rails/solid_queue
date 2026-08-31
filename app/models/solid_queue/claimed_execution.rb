# frozen_string_literal: true

module SolidQueue
  class ClaimedExecution < Execution
    belongs_to :process

    scope :orphaned, -> { where.missing(:process) }

    class Result < Struct.new(:success, :error)
      def success?
        success
      end
    end

    # Raised when a job has already run (or failed) but we couldn't update its
    # claim/finished state because of a transient error. The claim is still held
    # by a living worker, so it won't be recovered as orphaned unless the worker
    # is stopped and replaced.
    class FinalizationError < Processes::UnrecoverableError
      def initialize(claimed_execution, cause:)
        super("Failed to finalize claimed execution #{claimed_execution.id} (job #{claimed_execution.job_id}): #{cause.class}: #{cause.message}")
        set_backtrace(cause.backtrace) if cause.backtrace
      end
    end

    class << self
      def claiming(job_ids, process_id, &block)
        job_data = Array(job_ids).collect { |job_id| { job_id: job_id, process_id: process_id } }

        SolidQueue.instrument(:claim, process_id: process_id, job_ids: job_ids) do |payload|
          insert_all!(job_data)
          where(job_id: job_ids, process_id: process_id).load.tap do |claimed|
            block.call(claimed)

            payload[:size] = claimed.size
            payload[:claimed_job_ids] = claimed.map(&:job_id)
          end
        end
      end

      def release_all
        SolidQueue.instrument(:release_many_claimed) do |payload|
          includes(:job).tap do |executions|
            executions.each(&:release)

            payload[:size] = executions.size
          end
        end
      end

      def fail_all_with(error)
        includes(:job).tap do |executions|
          return if executions.empty?

          SolidQueue.instrument(:fail_many_claimed) do |payload|
            executions.each do |execution|
              execution.failed_with(error)
            end

            payload[:process_ids] = executions.map(&:process_id).uniq
            payload[:job_ids] = executions.map(&:job_id).uniq
            payload[:size] = executions.size
            payload[:error] = error
          end
        end
      end

      def discard_all_in_batches(*)
        raise UndiscardableError, "Can't discard jobs in progress"
      end

      def discard_all_from_jobs(*)
        raise UndiscardableError, "Can't discard jobs in progress"
      end
    end

    def perform
      result = execute

      if result.success?
        finalizing { finished }
      else
        finalizing { failed_with(result.error) }
        raise result.error
      end
    end

    def release
      SolidQueue.instrument(:release_claimed, job_id: job.id, process_id: process_id) do
        unless_already_finalized do
          job.dispatch_bypassing_concurrency_limits
          destroy!
        end
      end
    end

    def discard
      raise UndiscardableError, "Can't discard a job in progress"
    end

    def failed_with(error)
      finalize { job.failed_with(error) }
    end

    private
      # A failure here means the job already ran but we couldn't record the
      # outcome, and the claim is still held by this living worker, where no
      # recovery can reach it: it's a process problem, not a job problem
      def finalizing
        yield
      rescue => error
        raise FinalizationError.new(self, cause: error) if still_claimed?

        raise
      end

      def execute
        raise Job::ClassMissingError.for(job) if job.job_class.nil?

        ActiveJob::Base.execute(job.arguments.merge("provider_job_id" => job.id))
        Result.new(true, nil)
      rescue Exception => e
        Result.new(false, e)
      end

      def finished
        finalize { job.finished! }
      end

      def finalize
        finalized = unless_already_finalized do
          yield
          destroy!
          true
        end

        # Unblock the next job outside the finalize transaction so a failure while
        # releasing the concurrency lock or dispatching the next job can't roll back
        # a job that already finished or failed. Only the actor that owned and
        # finalized the claim gets here, so the lock is released exactly once.
        job.unblock_next_blocked_job if finalized
      end

      def unless_already_finalized
        transaction do
          return false unless self.class.unscoped.lock.find_by(id: id)

          yield
        end
      end

      def still_claimed?
        self.class.exists?(id)
      rescue
        # If we can't check because the DB is unavailable, assume the claim is
        # still held so the worker can be stopped and replaced.
        true
      end
  end
end
