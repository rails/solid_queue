# frozen_string_literal: true

module SolidQueue
  module AppExecutor
    extend ActiveSupport::Concern

    included do
      delegate :wrap_in_app_executor, :handle_thread_error, to: :class
    end

    class_methods do
      def wrap_in_app_executor(&block)
        if SolidQueue.app_executor
          SolidQueue.app_executor.wrap(&block)
        else
          yield
        end
      end

      def handle_thread_error(error)
        SolidQueue.logger.error("[SolidQueue] #{error}")

        if SolidQueue.on_thread_error
          SolidQueue.on_thread_error.call(error)
        end
      end
    end
  end
end
