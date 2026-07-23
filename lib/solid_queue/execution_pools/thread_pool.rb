# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class ThreadPool
      include AppExecutor

      attr_reader :size

      delegate :shutdown, :shutdown?, :wait_for_termination, to: :executor

      def type
        :thread
      end

      def initialize(size, on_idle: nil)
        @size = size
        @on_idle = on_idle
        @available_capacity = size
        @mutex = Mutex.new
      end

      def post(execution)
        reserved = false
        reserve_capacity!
        reserved = true

        Concurrent::Promises.future_on(executor, execution) do |thread_execution|
          wrap_in_app_executor { thread_execution.perform }
        rescue Exception => error
          handle_thread_error(error)
        ensure
          restore_capacity
        end
      rescue Exception
        restore_capacity if reserved
        raise
      end

      def available_capacity
        mutex.synchronize { @available_capacity }
      end

      def idle?
        available_capacity.positive?
      end

      private
        attr_reader :mutex, :on_idle

        DEFAULT_OPTIONS = {
          min_threads: 0,
          idletime: 60,
          fallback_policy: :abort
        }

        def executor
          @executor ||= Concurrent::ThreadPoolExecutor.new DEFAULT_OPTIONS.merge(max_threads: size, max_queue: size)
        end

        def reserve_capacity!
          mutex.synchronize do
            raise RuntimeError, "Execution pool is at capacity" if @available_capacity <= 0

            @available_capacity -= 1
          end
        end

        def restore_capacity
          should_notify = mutex.synchronize do
            @available_capacity += 1
            @available_capacity.positive?
          end

          on_idle&.call if should_notify
        end
    end
  end
end
