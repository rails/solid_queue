# frozen_string_literal: true

module SolidQueue
  module AppExecutor
    def wrap_in_app_executor(&block)
      if SolidQueue.app_executor
        SolidQueue.app_executor.wrap(&block)
      else
        yield
      end
    end
  end
end
