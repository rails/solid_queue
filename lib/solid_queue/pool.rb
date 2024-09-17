# frozen_string_literal: true

module SolidQueue
  class Pool
    include AppExecutor

    attr_reader :size

    delegate :shutdown, :shutdown?, :wait_for_termination, to: :executor

    def initialize(size, on_idle: nil)
      @size = size
      @on_idle = on_idle
      @available_threads = Concurrent::AtomicFixnum.new(size)
      @mutex = Mutex.new
    end

    def post(execution, worker)
      available_threads.decrement

      future = Concurrent::Future.new(args: [ execution, worker ], executor: executor) do |thread_execution, worker_execution|
        wrap_in_app_executor do
          thread_execution.perform
        ensure
          wrap_in_app_executor do
            execution.job.unblock_next_blocked_job
          end

          if worker_execution.oom?
            worker_execution.recycle(execution)
          else
            available_threads.increment
            mutex.synchronize { on_idle.try(:call) if idle? }
          end
        end
      end

      future.add_observer do |_, _, error|
        handle_thread_error(error) if error
      end

      future.execute
    end

    def idle_threads
      available_threads.value
    end

    def idle?
      idle_threads > 0
    end

    private
      attr_reader :available_threads, :on_idle, :mutex

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
