class SolidQueue::Job < ActiveRecord::Base
  serialize :arguments, JSON

  scope :pending, -> { where(claimed_at: nil) }
  scope :in_queue, ->(queue) { where(queue_name: queue) }
  scope :by_priority, -> { order(priority: :asc) }

  before_save :set_default_priority

  class << self
    def enqueue(queue_name:, priority: 0, arguments: {})
      create!(queue_name: queue_name, priority: priority, arguments: arguments)
    end
  end

  def perform
    ActiveJob::Base.execute(arguments)
  end

  private
    DEFAULT_PRIORITY = 0

    def set_default_priority
      self.priority ||= DEFAULT_PRIORITY
    end
end
