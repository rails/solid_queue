module SolidQueue
  class Engine < ::Rails::Engine
    isolate_namespace SolidQueue

    rake_tasks do
      load "solid_queue/tasks.rb"
    end

    config.solid_queue = ActiveSupport::OrderedOptions.new

    initializer "solid_queue.config" do
      config.after_initialize do |app|
        SolidQueue.process_heartbeat_interval = app.config.solid_queue.process_heartbeat_interval || 60.seconds
        SolidQueue.process_alive_threshold    = app.config.solid_queue.process_alive_threshold || 5.minutes
        SolidQueue.shutdown_timeout           = app.config.solid_queue.shutdown_timeout || 5.seconds
        SolidQueue.supervisor_pidfile         = app.config.solid_queue.supervisor_pidfile || app.root.join("tmp", "pids", "solid_queue_supervisor.pid")
      end
    end

    initializer "solid_queue.app_executor", before: :run_prepare_callbacks do |app|
      config.solid_queue.app_executor ||= app.executor

      SolidQueue.app_executor = config.solid_queue.app_executor
    end

    initializer "solid_queue.logger" do |app|
      ActiveSupport.on_load(:solid_queue) do
        self.logger = app.logger
      end
    end
  end
end
