# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class AsyncPool
      include AppExecutor

      WAKEUP_SIGNAL = ".".b

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
        @pending_executions = Thread::Queue.new
        @wakeup_reader, @wakeup_writer = IO.pipe

        self.class.ensure_dependency!
        self.class.ensure_supported_isolation_level!

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
        pending_executions << execution
        signal_reactor
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
        should_shutdown = state_mutex.synchronize do
          next false if @shutdown

          @shutdown = true
        end

        signal_reactor if should_shutdown
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
        attr_reader :boot_queue, :mutex, :on_state_change, :pending_executions, :reactor_thread, :state_mutex, :wakeup_reader, :wakeup_writer

        def name
          @name ||= "solid_queue-async-pool-#{object_id}"
        end

        def start_reactor
          create_thread do
            Async do |task|
              semaphore = Async::Semaphore.new(size, parent: task)
              boot_queue << :ready

              wait_for_executions(semaphore)
              wait_for_child_tasks(task)
            end
          rescue Exception => error
            register_fatal_error(error)
            raise
          ensure
            close_wakeup_pipe
          end
        end

        def wait_for_executions(semaphore)
          loop do
            wakeup_reader.wait_readable
            clear_wakeup_signal
            schedule_pending_executions(semaphore)

            break if shutdown? && pending_executions.empty?
          end
        end

        def clear_wakeup_signal
          loop do
            wakeup_reader.read_nonblock(1024)
          rescue IO::WaitReadable, EOFError
            break
          end
        end

        def schedule_pending_executions(semaphore)
          while execution = next_pending_execution
            semaphore.async(execution) do |_execution_task, scheduled_execution|
              perform_execution(scheduled_execution)
            end
          end
        end

        def next_pending_execution
          pending_executions.pop(true)
        rescue ThreadError
          nil
        end

        def perform_execution(execution)
          wrap_in_app_executor { execution.perform }
        rescue Async::Stop => error
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

        def signal_reactor
          wakeup_writer.write_nonblock(WAKEUP_SIGNAL)
        rescue IO::WaitWritable, Errno::EPIPE, IOError
          nil
        end

        def wait_for_child_tasks(task)
          if task.respond_to?(:wait_all)
            task.wait_all
          else
            task.children&.each(&:wait)
          end
        end

        def close_wakeup_pipe
          wakeup_reader.close unless wakeup_reader.closed?
          wakeup_writer.close unless wakeup_writer.closed?
        rescue IOError
          nil
        end
    end
  end
end
