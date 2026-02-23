# frozen_string_literal: true

module SolidQueue
  module AppExecutor
    def wrap_in_app_executor(silence: true, &block)
      if silence && SolidQueue.silence_queries? && ActiveRecord::Base.logger
        original = block
        block = proc { ActiveRecord::Base.logger.silence(&original) }
      end

      if SolidQueue.app_executor
        SolidQueue.app_executor.wrap(source: "application.solid_queue", &block)
      else
        block.call
      end
    end

    def handle_thread_error(error)
      SolidQueue.instrument(:thread_error, error: error)

      if SolidQueue.on_thread_error
        SolidQueue.on_thread_error.call(error)
      end
    end

    def create_thread(&block)
      Thread.new do
        Thread.current.name = name
        block.call
      rescue Exception => exception
        handle_thread_error(exception)
        raise
      end
    end
  end
end
