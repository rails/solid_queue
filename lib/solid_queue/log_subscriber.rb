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
    attributes = event.payload.slice(:task, :active_job_id, :enqueue_error)
    attributes[:at] = event.payload[:at]&.iso8601

    if event.payload[:other_adapter]
      action = attributes[:active_job_id].present? ? "Enqueued recurring task outside Solid Queue" : "Error enqueuing recurring task"
      info formatted_event(event, action: action, **attributes)
    else
      action = case
      when event.payload[:skipped].present? then "Skipped recurring task – already dispatched"
      when attributes[:active_job_id].nil?  then "Error enqueuing recurring task"
      else                                       "Enqueued recurring task"
      end

      info formatted_event(event, action: action, **attributes)
    end
  end

  def start_process(event)
    process = event.payload[:process]

    attributes = {
      pid: process.pid,
      hostname: process.hostname
    }.merge(process.metadata)

    info formatted_event(event, action: "Started #{process.kind}", **attributes)
  end

  def shutdown_process(event)
    process = event.payload[:process]

    attributes = {
      pid: process.pid,
      hostname: process.hostname
    }.merge(process.metadata)

    info formatted_event(event, action: "Shut down #{process.kind}", **attributes)
  end

  def register_process(event)
    process_kind = event.payload[:kind]
    attributes = event.payload.slice(:pid, :hostname)

    if error = event.payload[:error]
      warn formatted_event(event, action: "Error registering #{process_kind}", **attributes.merge(error: formatted_error(error)))
    else
      info formatted_event(event, action: "Register #{process_kind}", **attributes)
    end
  end

  def deregister_process(event)
    process = event.payload[:process]

    attributes = {
      process_id: process.id,
      pid: process.pid,
      hostname: process.hostname,
      last_heartbeat_at: process.last_heartbeat_at.iso8601,
      claimed_size: process.claimed_executions.size,
      pruned: event.payload[:pruned]
    }

    if error = event.payload[:error]
      warn formatted_event(event, action: "Error deregistering #{process.kind}", **attributes.merge(error: formatted_error(error)))
    else
      info formatted_event(event, action: "Deregister #{process.kind}", **attributes)
    end
  end

  def prune_processes(event)
    debug formatted_event(event, action: "Prune dead processes", **event.payload.slice(:size))
  end

  def thread_error(event)
    error formatted_event(event, action: "Error in thread", error: formatted_error(event.payload[:error]))
  end

  def graceful_termination(event)
    attributes = event.payload.slice(:supervisor_pid, :supervised_pids)

    if event.payload[:shutdown_timeout_exceeded]
      warn formatted_event(event, action: "Supervisor wasn't terminated gracefully - shutdown timeout exceeded", **attributes)
    else
      info formatted_event(event, action: "Supervisor terminated gracefully", **attributes)
    end
  end

  def immediate_termination(event)
    info formatted_event(event, action: "Supervisor terminated immediately", **event.payload.slice(:supervisor_pid, :supervised_pids))
  end

  def unhandled_signal_error(event)
    error formatted_event(event, action: "Received unhandled signal", **event.payload.slice(:signal))
  end

  def replace_fork(event)
    status = event.payload[:status]
    attributes = event.payload.slice(:pid).merge \
      status: (status.exitstatus || "no exit status set"),
      pid_from_status: status.pid,
      signaled: status.signaled?,
      stopsig: status.stopsig,
      termsig: status.termsig

    if replaced_fork = event.payload[:fork]
      info formatted_event(event, action: "Replaced terminated #{replaced_fork.kind}", **attributes.merge(hostname: replaced_fork.hostname))
    else
      warn formatted_event(event, action: "Tried to replace forked process but it had already died", **attributes)
    end
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

    # Use the logger configured for SolidQueue
    def logger
      SolidQueue.logger
    end
end
