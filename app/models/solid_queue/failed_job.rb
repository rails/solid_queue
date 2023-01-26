class SolidQueue::FailedJob < ActiveRecord::Base
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
      SolidQueue::Job.enqueue(queue_name: queue_name, priority: priority, arguments: arguments, enqueued_at: enqueued_at)
      destroy!
    end
  end
end
