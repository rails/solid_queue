# frozen_string_literal: true

module SolidQueue
  class Engine < ::Rails::Engine
    isolate_namespace SolidQueue

    rake_tasks do
      load "solid_queue/tasks.rb"
    end

    config.solid_queue = ActiveSupport::OrderedOptions.new

    initializer "solid_queue.config" do |app|
      app.paths.add "config/solid_queue", with: ENV["SOLID_QUEUE_CONFIG"] || "config/queue.yml" || "config/solid_queue.yml"

      options = {}
      if (config_path = Pathname.new(app.config.paths["config/solid_queue"].first)).exist?
        options = app.config_for(config_path).to_h.deep_symbolize_keys
      end

      options[:connects_to] = config.solid_queue.connects_to if config.solid_queue.connects_to

      SolidQueue.configuration = SolidQueue::Configuration.new(options)

      config.solid_queue.each do |name, value|
        SolidQueue.public_send("#{name}=", value)
      end
    end

    initializer "solid_queue.app_executor", before: :run_prepare_callbacks do |app|
      config.solid_queue.app_executor    ||= app.executor
      config.solid_queue.on_thread_error ||= ->(exception) { Rails.error.report(exception, handled: false) }

      SolidQueue.app_executor = config.solid_queue.app_executor
      SolidQueue.on_thread_error = config.solid_queue.on_thread_error
    end

    initializer "solid_queue.logger" do
      ActiveSupport.on_load(:solid_queue) do
        self.logger = ::Rails.logger if logger == SolidQueue::DEFAULT_LOGGER
      end

      SolidQueue::LogSubscriber.attach_to :solid_queue
    end

    initializer "solid_queue.active_job.extensions" do
      ActiveSupport.on_load :active_job do
        include ActiveJob::ConcurrencyControls
      end
    end
  end
end
