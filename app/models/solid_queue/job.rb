class SolidQueue::Job < ActiveRecord::Base
  serialize :arguments, JSON

  scope :pending, -> { where(claimed_at: nil, finished_at: nil) }
  scope :in_queue, ->(queues) { where(queue_name: queues) }
  scope :by_priority, -> { order(priority: :asc) }

  scope :ready, ->(queues) { pending.in_queue(queues).by_priority }

  class << self
    def enqueue(queue_name:, priority: 0, enqueued_at: Time.current, arguments: {})
      create!(queue_name: queue_name || "default", priority: priority || 0, arguments: arguments, enqueued_at: enqueued_at || Time.current)
    end
  end

  def perform
    execute
    finished
  rescue Exception => e
    failed_with(e)
  end

  private
    def execute
      ActiveJob::Base.execute(arguments)
    end

    def finished
      update!(finished_at: Time.current)
    end

    def failed_with(error)
      transaction do
        SolidQueue::FailedJob.create_from(self, error)
        destroy!
      end
    end
end
