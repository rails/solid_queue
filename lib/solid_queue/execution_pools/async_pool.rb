# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class AsyncPool
      include AppExecutor

      IDLE_WAIT_INTERVAL = 0.01

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
          ensure_io_timeout_compatibility!

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

        def ensure_io_timeout_compatibility!(io_class = IO)
          unless io_class.method_defined?(:timeout) && io_class.method_defined?(:timeout=)
            # Async 2.24, which Ruby 3.1 resolves to, expects Ruby's newer IO
            # timeout API to exist on any socket it waits on. Older Rubies don't
            # provide it, so give async the minimal accessor interface it needs.
            io_class.class_eval do
              def timeout
                @timeout
              end

              def timeout=(value)
                @timeout = value
              end
            end
          end

          return if io_class.const_defined?(:TimeoutError, false)

          io_class.const_set(:TimeoutError, Class.new(StandardError))
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
        state_mutex.synchronize do
          next false if @shutdown

          @shutdown = true
        end
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
        attr_reader :boot_queue, :mutex, :on_state_change, :pending_executions, :reactor_thread, :state_mutex

        def name
          @name ||= "solid_queue-async-pool-#{object_id}"
        end

        def start_reactor
          create_thread do
            Async do |task|
              semaphore = Async::Semaphore.new(size, parent: task)
              boot_queue << :ready

              wait_for_executions(semaphore)
              wait_for_inflight_executions
            end
          rescue Exception => error
            register_fatal_error(error)
            raise
          end
        end

        def wait_for_executions(semaphore)
          loop do
            schedule_pending_executions(semaphore)

            break if shutdown? && pending_executions.empty?

            # Older async releases don't support waking the reactor from another
            # thread reliably, so we cooperatively poll for newly posted work.
            sleep(IDLE_WAIT_INTERVAL) if pending_executions.empty?
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

        def wait_for_inflight_executions
          sleep(IDLE_WAIT_INTERVAL) while executions_in_flight?
        end

        def executions_in_flight?
          mutex.synchronize { @available_capacity < size }
        end
    end
  end
end
