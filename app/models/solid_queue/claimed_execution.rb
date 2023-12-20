# frozen_string_literal: true

class SolidQueue::ClaimedExecution < SolidQueue::Execution
  belongs_to :process

  class Result < Struct.new(:success, :error)
    def success?
      success
    end
  end

  class << self
    def claiming(job_ids, process_id, &block)
      job_data = Array(job_ids).collect { |job_id| { job_id: job_id, process_id: process_id } }

      insert_all!(job_data)
      where(job_id: job_ids, process_id: process_id).load.tap do |claimed|
        block.call(claimed)
        SolidQueue.logger.info("[SolidQueue] Claimed #{claimed.size} jobs")
      end
    end

    def release_all
      includes(:job).each(&:release)
    end
  end

  def perform
    result = execute

    if result.success?
      finished
    else
      failed_with(result.error)
    end
  ensure
    job.unblock_next_blocked_job
  end

  def release
    transaction do
      job.prepare_for_execution
      destroy!
    end
  end

  private
    def execute
      ActiveJob::Base.execute(job.arguments)
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

    def failed_with(error)
      transaction do
        job.failed_with(error)
        destroy!
      end
    end
end
