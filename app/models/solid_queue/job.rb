class SolidQueue::Job < ActiveRecord::Base
  include Executable

  serialize :arguments, JSON

  class << self
    def enqueue_active_job(active_job, scheduled_at: Time.current)
      enqueue \
        queue_name: active_job.queue_name,
        priority: active_job.priority,
        scheduled_at: scheduled_at,
        arguments: active_job.serialize
    end

    def enqueue(**kwargs)
      create!(**kwargs.compact.with_defaults(defaults))
    end

    private
      DEFAULT_PRIORITY = 0
      DEFAULT_QUEUE_NAME = "default"

      def defaults
        { queue_name: DEFAULT_QUEUE_NAME, priority: DEFAULT_PRIORITY }
      end
  end
end
