module SolidQueue
  class Engine < ::Rails::Engine
    isolate_namespace SolidQueue

    rake_tasks do
      load "solid_queue/tasks.rb"
    end

    config.solid_queue = ActiveSupport::OrderedOptions.new

    initializer "solid_queue.config", before: :run_prepare_callbacks do |app|
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
