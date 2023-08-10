# frozen_string_literal: true

module SolidQueue
  class Pool
    include AppExecutor

    delegate :shutdown, :shutdown?, :wait_for_termination, to: :executor

    def initialize(size)
      @size = size
      @idle_threads = Concurrent::AtomicFixnum.new(size)
    end

    def post(execution, process)
      idle_threads.decrement

      future = Concurrent::Future.new(args: [ execution, process ], executor: executor) do |thread_execution, thread_process|
        wrap_in_app_executor do
          thread_execution.perform(thread_process)
        ensure
          idle_threads.increment
        end
      end

      future.add_observer do |_, _, error|
        handle_thread_error(error) if error
      end

      future.execute
    end

    def available_threads
      idle_threads.value
    end

    private
      attr_accessor :size, :idle_threads

      DEFAULT_OPTIONS = {
        min_threads: 0,
        idletime: 60,
        fallback_policy: :abort
      }

      def executor
        @executor ||= Concurrent::ThreadPoolExecutor.new DEFAULT_OPTIONS.merge(max_threads: size, max_queue: size)
      end
  end
end
