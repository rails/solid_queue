# frozen_string_literal: true

require "active_support/log_subscriber"

class SolidQueue::LogSubscriber < ActiveSupport::LogSubscriber
  def dispatch_scheduled(event)
    debug formatted_event(event, action: "Dispatch scheduled jobs", **event.payload.slice(:batch_size, :size))
  end

  def release_many_claimed(event)
    debug formatted_event(event, action: "Release claimed jobs", **event.payload.slice(:size))
  end

  def release_claimed(event)
    debug formatted_event(event, action: "Release claimed job", **event.payload.slice(:job_id, :process_id))
  end

  def retry_all(event)
    debug formatted_event(event, action: "Retry failed jobs", **event.payload.slice(:jobs_size, :size))
  end

  def retry(event)
    debug formatted_event(event, action: "Retry failed job", **event.payload.slice(:job_id))
  end

  def discard_all(event)
    debug formatted_event(event, action: "Discard jobs", **event.payload.slice(:jobs_size, :size, :status))
  end

  def discard(event)
    debug formatted_event(event, action: "Discard job", **event.payload.slice(:job_id, :status))
  end

  def release_many_blocked(event)
    debug formatted_event(event, action: "Unblock jobs", **event.payload.slice(:limit, :size))
  end

  def release_blocked(event)
    debug formatted_event(event, action: "Release blocked job", **event.payload.slice(:job_id, :concurrency_key, :released))
  end

  def enqueue_recurring_task(event)
    attributes = event.payload.slice(:task, :at, :active_job_id)

    if event.payload[:other_adapter]
      debug formatted_event(event, action: "Enqueued recurring task outside Solid Queue", **attributes)
    else
      action = attributes[:active_job_id].present? ? "Enqueued recurring task" : "Skipped recurring task – already dispatched"
      info formatted_event(event, action: action, **attributes)
    end
  end

  def register_process(event)
    attributes = event.payload.slice(:kind, :pid, :hostname)

    if error = event.payload[:error]
      warn formatted_event(event, action: "Error registering process", **attributes.merge(error: formatted_error(error)))
    else
      info formatted_event(event, action: "Register process", **attributes)
    end
  end

  def deregister_process(event)
    process = event.payload[:process]

    attributes = {
      process_id: process.id,
      pid: process.pid,
      kind: process.kind,
      hostname: process.hostname,
      last_heartbeat_at: process.last_heartbeat_at,
      claimed_size: process.claimed_executions.size,
      pruned: event.payload
    }

    if error = event.payload[:error]
      warn formatted_event(event, action: "Error deregistering process", **attributes.merge(formatted_error(error)))
    else
      info formatted_event(event, action: "Deregister process", **attributes)
    end
  end

  def prune_processes(event)
    debug formatted_event(event, action: "Prune dead processes", **event.payload.slice(:size))
  end

  private
    def formatted_event(event, action:, **attributes)
      "SolidQueue-#{SolidQueue::VERSION} #{action} (#{event.duration.round(1)}ms)  #{formatted_attributes(**attributes)}"
    end

    def formatted_attributes(**attributes)
      attributes.map { |attr, value| "#{attr}: #{value.inspect}" }.join(", ")
    end

    def formatted_error(error)
      [ error.class, error.message ].compact.join(" ")
    end
end
