class SolidQueue::Job < ActiveRecord::Base
  include Executable

  serialize :arguments, JSON

  class << self
    def enqueue_active_job(active_job, scheduled_at: Time.current)
      enqueue \
        queue_name: active_job.queue_name,
        active_job_id: active_job.job_id,
        priority: active_job.priority,
        scheduled_at: scheduled_at,
        arguments: active_job.serialize
    end

    def enqueue(**kwargs)
      create!(**kwargs.compact.with_defaults(defaults)).tap do
        SolidQueue.logger.info "[SolidQueue] Enqueued job #{kwargs}"
      end
    end

    private
      def defaults
        SolidQueue::Configuration::QUEUE_DEFAULTS.slice(:queue_name, :priority)
      end
  end
end
