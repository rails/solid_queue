# frozen_string_literal: true

require "solid_queue/version"
require "solid_queue/engine"

require "active_job"
require "active_job/queue_adapters"

require "active_support"
require "active_support/core_ext/numeric/time"

require "zeitwerk"

loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.ignore("#{__dir__}/solid_queue/tasks.rb")
loader.ignore("#{__dir__}/generators")
loader.ignore("#{__dir__}/puma")
loader.setup

module SolidQueue
  extend self

  DEFAULT_LOGGER = ActiveSupport::Logger.new($stdout)

  mattr_accessor :logger, default: DEFAULT_LOGGER
  mattr_accessor :app_executor, :on_thread_error, :connects_to

  mattr_accessor :use_skip_locked, default: true

  mattr_accessor :process_heartbeat_interval, default: 60.seconds
  mattr_accessor :process_alive_threshold, default: 5.minutes

  mattr_accessor :shutdown_timeout, default: 5.seconds

  mattr_accessor :silence_polling, default: true

  mattr_accessor :supervisor_pidfile
  mattr_accessor :supervisor, default: false

  mattr_accessor :preserve_finished_jobs, default: true
  mattr_accessor :clear_finished_jobs_after, default: 1.day
  mattr_accessor :default_concurrency_control_period, default: 3.minutes

  delegate :on_start, :on_stop, :on_exit, to: Supervisor

  [ Dispatcher, Scheduler, Worker ].each do |process|
    define_singleton_method(:"on_#{process.name.demodulize.downcase}_start") do |&block|
      process.on_start(&block)
    end

    define_singleton_method(:"on_#{process.name.demodulize.downcase}_stop") do |&block|
      process.on_stop(&block)
    end

    define_singleton_method(:"on_#{process.name.demodulize.downcase}_exit") do |&block|
      process.on_exit(&block)
    end
  end

  def supervisor?
    supervisor
  end

  def silence_polling?
    silence_polling
  end

  def preserve_finished_jobs?
    preserve_finished_jobs
  end

  def instrument(channel, **options, &block)
    ActiveSupport::Notifications.instrument("#{channel}.solid_queue", **options, &block)
  end

  ActiveSupport.run_load_hooks(:solid_queue, self)
end
