module SolidQueue
  class Engine < ::Rails::Engine
    isolate_namespace SolidQueue

    rake_tasks do
      load "solid_queue/tasks.rb"
    end

    initializer "solid_queue.logger" do |app|
      ActiveSupport.on_load(:solid_queue) do
        self.logger = ::Rails.logger
      end
    end
  end
end
