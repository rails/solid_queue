class SolidQueue::BlockedExecution < SolidQueue::Execution
  assume_attributes_from_job :concurrency_limit, :concurrency_key
end
