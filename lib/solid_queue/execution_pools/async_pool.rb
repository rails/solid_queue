# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class AsyncPool
      include AppExecutor

      class MissingDependencyError < LoadError
        def initialize(error)
          super(
            "Async execution mode requires the `async` gem. " \
            "Add `gem \"async\"` to your Gemfile to use `execution_mode: async`. " \
            "Original error: #{error.message}"
          )
        end
      end

      class UnsupportedIsolationLevelError < ArgumentError
        def initialize(level)
          super(
            "Async execution mode requires fiber-scoped isolated execution state. " \
            "Set `ActiveSupport::IsolatedExecutionState.isolation_level = :fiber` " \
            "(or `config.active_support.isolation_level = :fiber` in Rails). " \
            "Current isolation level: #{level.inspect}"
          )
        end
      end

      class << self
        def ensure_dependency!
          require "async"
          require "async/queue"
          require "async/semaphore"
        rescue LoadError => error
          raise MissingDependencyError.new(error)
        end

        def ensure_supported_isolation_level!
          return if supported_isolation_level?

          raise UnsupportedIsolationLevelError.new(ActiveSupport::IsolatedExecutionState.isolation_level)
        end

        def supported_isolation_level?
          ActiveSupport::IsolatedExecutionState.isolation_level == :fiber
        end
      end

      attr_reader :size

      def initialize(size, on_state_change: nil)
        @size = size
        @on_state_change = on_state_change
        @available_capacity = size
        @mutex = Mutex.new
        @state_mutex = Mutex.new
        @shutdown = false
        @fatal_error = nil
        @boot_queue = Thread::Queue.new

        self.class.ensure_dependency!
        self.class.ensure_supported_isolation_level!

        @queue = Async::Queue.new
        @reactor_thread = start_reactor

        boot_result = @boot_queue.pop
        raise boot_result if boot_result.is_a?(Exception)
      end

      def post(execution)
        reserved = false
        raise_if_fatal_error!
        raise RuntimeError, "Execution pool is shutting down" if shutdown?

        reserve_capacity!
        reserved = true
        queue.enqueue(execution)
      rescue Exception
        restore_capacity if reserved
        raise
      end

      def available_capacity
        raise_if_fatal_error!
        mutex.synchronize { @available_capacity }
      end

      def idle?
        available_capacity.positive?
      end

      def shutdown
        should_close = state_mutex.synchronize do
          next false if @shutdown

          @shutdown = true
        end

        queue.close if should_close
      end

      def shutdown?
        state_mutex.synchronize { @shutdown }
      end

      def wait_for_termination(timeout)
        reactor_thread.join(timeout)
      end

      def metadata
        {
          execution_mode: "async",
          capacity: size,
          inflight: size - available_capacity
        }
      end

      private
        attr_reader :boot_queue, :mutex, :on_state_change, :queue, :reactor_thread, :state_mutex

        def name
          @name ||= "solid_queue-async-pool-#{object_id}"
        end

        def start_reactor
          create_thread do
            Async do |task|
              semaphore = Async::Semaphore.new(size, parent: task)
              boot_queue << :ready

              drain_queue(task, semaphore)
              task.wait_all
            end
          rescue Exception => error
            register_fatal_error(error)
            raise
          end
        end

        def drain_queue(task, semaphore)
          task.async do
            while execution = queue.dequeue
              semaphore.async(execution) do |_execution_task, scheduled_execution|
                perform_execution(scheduled_execution)
              end
            end
          end.wait
        end

        def perform_execution(execution)
          wrap_in_app_executor { execution.perform }
        rescue Async::Cancel => error
          handle_thread_error(error)
          register_fatal_error(error)
        rescue Exception => error
          handle_thread_error(error)
        ensure
          restore_capacity
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

          on_state_change&.call if should_notify
        end

        def register_fatal_error(error)
          state_mutex.synchronize do
            @fatal_error ||= error
          end

          boot_queue << error if boot_queue.empty?
          on_state_change&.call
        end

        def raise_if_fatal_error!
          error = state_mutex.synchronize { @fatal_error }
          raise error if error
        end
    end
  end
end
