require "solid_queue/version"
require "solid_queue/engine"

require "active_job/queue_adapters/solid_queue_adapter"
require "active_job/concurrency_controls"

require "solid_queue/app_executor"
require "solid_queue/interruptible"
require "solid_queue/pidfile"
require "solid_queue/procline"
require "solid_queue/signals"
require "solid_queue/configuration"
require "solid_queue/pool"
require "solid_queue/queue_selector"
require "solid_queue/runner"
require "solid_queue/process_registration"
require "solid_queue/worker"
require "solid_queue/scheduler"
require "solid_queue/supervisor"

module SolidQueue
  mattr_accessor :logger, default: ActiveSupport::Logger.new($stdout)
  mattr_accessor :app_executor
  mattr_accessor :on_thread_error

  mattr_accessor :process_heartbeat_interval, default: 60.seconds
  mattr_accessor :process_alive_threshold, default: 5.minutes

  mattr_accessor :shutdown_timeout, default: 5.seconds

  mattr_accessor :silence_polling, default: false

  mattr_accessor :supervisor_pidfile
  mattr_accessor :supervisor, default: false

  mattr_accessor :preserve_finished_jobs, default: true
  mattr_accessor :clear_finished_jobs_after, default: 1.day
  mattr_accessor :default_concurrency_control_period, default: 3.minutes

  def self.supervisor?
    supervisor
  end

  def self.silence_polling?
    silence_polling
  end
end
