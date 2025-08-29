# frozen_string_literal: true

class SolidQueue::ClaimedExecution < SolidQueue::Execution
  belongs_to :process

  scope :orphaned, -> { where.missing(:process) }

  class Result < Struct.new(:success, :error)
    def success?
      success
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
      SolidQueue.instrument(:fail_many_claimed) do |payload|
        includes(:job).tap do |executions|
          executions.each do |execution|
            execution.failed_with(error)
            execution.unblock_next_job
          end

          payload[:process_ids] = executions.map(&:process_id).uniq
          payload[:job_ids] = executions.map(&:job_id).uniq
          payload[:size] = executions.size
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
      finished
    else
      failed_with(result.error)
      raise result.error
    end
  ensure
    unblock_next_job
  end

  def release
    SolidQueue.instrument(:release_claimed, job_id: job.id, process_id: process_id) do
      transaction do
        job.dispatch_bypassing_concurrency_limits
        destroy!
      end
    end
  end

  def discard
    raise UndiscardableError, "Can't discard a job in progress"
  end

  def failed_with(error)
    transaction do
      job.failed_with(error)
      destroy!
    end
  end

  def unblock_next_job
    job.unblock_next_blocked_job
  end

  private
    def execute
      ActiveJob::Base.execute(job.arguments.merge("provider_job_id" => job.id))
      Result.new(true, nil)
    rescue Exception => e
      Result.new(false, e)
    end

    def finished
      transaction do
        job.finished!
        destroy!
      end
    end
end
