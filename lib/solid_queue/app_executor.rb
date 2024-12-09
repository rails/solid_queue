# frozen_string_literal: true

module SolidQueue
  module AppExecutor
    def wrap_in_app_executor(&block)
      if SolidQueue.app_executor
        SolidQueue.app_executor.wrap(source: "application.solid_queue", &block)
      else
        yield
      end
    end

    def handle_thread_error(error)
      SolidQueue.instrument(:thread_error, error: error)

      if SolidQueue.on_thread_error
        SolidQueue.on_thread_error.call(error)
      end
    end
  end
end
