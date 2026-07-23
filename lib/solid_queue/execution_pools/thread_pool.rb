# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class ThreadPool < Base
      delegate :shutdown, :shutdown?, :wait_for_termination, to: :executor

      private
        DEFAULT_OPTIONS = {
          min_threads: 0,
          idletime: 60,
          fallback_policy: :abort
        }

        def schedule(execution)
          Concurrent::Promises.future_on(executor, execution) do |thread_execution|
            perform_execution(thread_execution)
          end.on_rejection! do |error|
            # Backstop for errors raised outside perform_execution's own rescue,
            # such as when restoring capacity or waking up the worker
            handle_thread_error(error)
          end
        end

        def executor
          @executor ||= Concurrent::ThreadPoolExecutor.new DEFAULT_OPTIONS.merge(max_threads: size, max_queue: size)
        end
    end
  end
end
