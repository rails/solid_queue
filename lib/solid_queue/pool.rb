# frozen_string_literal: true

module SolidQueue
  class Pool
    include AppExecutor

    attr_accessor :size, :executor

    delegate :shutdown, :shutdown?, :wait_for_termination, to: :executor

    def initialize(size)
      @size = size
      @executor = Concurrent::FixedThreadPool.new(size)
    end

    def post(execution, process)
      future = Concurrent::Future.new(args: [ execution, process ], executor: executor) do |thread_execution, thread_process|
        wrap_in_app_executor do
          thread_execution.perform(thread_process)
        end
      end

      future.add_observer do |_, _, error|
        handle_thread_error(error) if error
      end

      future.execute
    end
  end
end
