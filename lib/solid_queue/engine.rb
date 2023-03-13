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
