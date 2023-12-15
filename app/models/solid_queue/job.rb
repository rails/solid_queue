# frozen_string_literal: true

class SolidQueue::Job < SolidQueue::Record
  include Executable

  if Gem::Version.new(Rails.version) >= Gem::Version.new("7.1")
    serialize :arguments, coder: JSON
  else
    serialize :arguments, JSON
  end

  DEFAULT_PRIORITY = 0
  DEFAULT_QUEUE_NAME = "default"

  class << self
    def enqueue_active_job(active_job, scheduled_at: Time.current)
      enqueue \
        queue_name: active_job.queue_name,
        active_job_id: active_job.job_id,
        priority: active_job.priority,
        scheduled_at: scheduled_at,
        class_name: active_job.class.name,
        arguments: active_job.serialize,
        concurrency_key: active_job.try(:concurrency_key)
    end

    def enqueue(**kwargs)
      create!(**kwargs.compact.with_defaults(defaults)).tap do
        SolidQueue.logger.debug "[SolidQueue] Enqueued job #{kwargs}"
      end
    end

    private
      def defaults
        { queue_name: DEFAULT_QUEUE_NAME, priority: DEFAULT_PRIORITY }
      end
  end
end
