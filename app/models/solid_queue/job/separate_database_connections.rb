module SolidQueue
  module Job::SeparateDatabaseConnections
    extend ActiveSupport::Concern

    included do
      include SolidQueue::AppExecutor
    end

    class_methods do
      def with_separate_database_connection(&block)
        if !SolidQueue.use_active_db_connection_to_enqueue_jobs && requires_new_connection?
          with_new_connection(&block)
        else
          block.call
        end
      end

      def requires_new_connection?
        connection_pool.active_connection? && connection.open_transactions > 0
      end

      def with_new_connection(&block)
        Thread.new do
          wrap_in_app_executor do
            connection_pool.with_connection(&block)
          end
        end.value
      end
    end
  end
end
