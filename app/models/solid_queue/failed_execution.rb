class SolidQueue::FailedExecution < SolidQueue::Execution
  serialize :arguments, JSON

  def self.create_from(job, error)
    create! \
      queue_name: job.queue_name,
      arguments: job.arguments,
      priority: job.priority,
      enqueued_at: job.enqueued_at,
      error: "#{error.message}\n#{error.backtrace.join("\n")}"
  end

  def retry
    transaction do
      job.prepare_for_execution
      destroy!
    end
  end
end
