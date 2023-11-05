class SolidQueue::BlockedExecution < SolidQueue::Execution
  assume_attributes_from_job :concurrency_limit, :concurrency_key

  def self.release(concurrency_key)
    where(concurrency_key: concurrency_key).order(:priority).first&.release
  end

  def release
    transaction do
      job.prepare_for_execution
      destroy!
    end
  end
end
