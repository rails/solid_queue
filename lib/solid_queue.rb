# frozen_string_literal: true

require "solid_queue/version"
require "solid_queue/engine"

require "active_job/queue_adapters/solid_queue_adapter"
require "active_job/concurrency_controls"

require "solid_queue/app_executor"
require "solid_queue/processes/supervised"
require "solid_queue/processes/registrable"
require "solid_queue/processes/interruptible"
require "solid_queue/processes/pidfile"
require "solid_queue/processes/procline"
require "solid_queue/processes/poller"
require "solid_queue/processes/base"
require "solid_queue/processes/runnable"
require "solid_queue/processes/signals"
require "solid_queue/configuration"
require "solid_queue/pool"
require "solid_queue/worker"
require "solid_queue/dispatcher"
require "solid_queue/supervisor"

module SolidQueue
  mattr_accessor :logger, default: ActiveSupport::Logger.new($stdout)
  mattr_accessor :app_executor, :on_thread_error, :connects_to

  mattr_accessor :use_skip_locked, default: true

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
