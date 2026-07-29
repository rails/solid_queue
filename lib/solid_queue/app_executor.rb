# frozen_string_literal: true

module SolidQueue
  module AppExecutor
    def wrap_in_app_executor(&block)
      if SolidQueue.app_executor
        SolidQueue.app_executor.wrap(source: "application.solid_queue") { connected_to_shard(&block) }
      else
        connected_to_shard(&block)
      end
    end

    # The queue database shard all database work is pinned to. Shard-aware
    # processes and pools override it; nil operates on the default shard.
    #
    # The shard needs re-establishing on every unit of work because it's
    # thread-local, and completing the app executor clears it even within
    # the same thread.
    def shard
      nil
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

    private
      def connected_to_shard(&block)
        if shard
          SolidQueue::Record.connected_to(shard: shard, &block)
        else
          block.call
        end
      end
  end
end
