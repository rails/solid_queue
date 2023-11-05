class SolidQueue::BlockedExecution < SolidQueue::Execution
  before_create :assume_attributes_from_job

  private
    def assume_attributes_from_job
      super
      self.concurrency_limit ||= job.concurrency_limit
      self.concurrency_key   ||= job.concurrency_key
    end
end
