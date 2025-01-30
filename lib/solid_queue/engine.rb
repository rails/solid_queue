# frozen_string_literal: true

module SolidQueue
  class Engine < ::Rails::Engine
    isolate_namespace SolidQueue

    rake_tasks do
      load "solid_queue/tasks.rb"
    end

    config.solid_queue = ActiveSupport::OrderedOptions.new

    initializer "solid_queue.config" do
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

    initializer "solid_queue.include_interruptible_concern" do
      if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2")
        SolidQueue::Processes::Base.include SolidQueue::Processes::Interruptible
      else
        SolidQueue::Processes::Base.include SolidQueue::Processes::OgInterruptible
      end
    end

    initializer "solid_queue.shard_configuration" do
      ActiveSupport.on_load(:solid_queue) do
        # Record the name of the primary shard, which should be used for
        # adapter less jobs
        if SolidQueue.connects_to.key?(:shards) && SolidQueue.primary_shard.nil?
          SolidQueue.primary_shard = SolidQueue.connects_to[:shards].keys.first
        end
      end
    end
  end
end
