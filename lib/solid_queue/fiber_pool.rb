# frozen_string_literal: true

module SolidQueue
  class FiberPool < Pool
    def initialize(size, on_idle: nil)
      super

      @state_mutex = Mutex.new
      @shutdown = false
      @fatal_error = nil
      @boot_queue = Thread::Queue.new
      @pending_executions = Thread::Queue.new
      @reactor_thread = nil
    end

    def post(execution)
      raise_if_fatal_error!
      raise RuntimeError, "Execution pool is shutting down" if shutdown?

      super
    end

    def available_capacity
      raise_if_fatal_error!
      super
    end

    def shutdown
      state_mutex.synchronize do
        next false if @shutdown

        @shutdown = true
      end.tap do |shut_down|
        # Wake the reactor: already-queued executions are drained before the
        # blocked pop in +wait_for_executions+ returns nil
        pending_executions.close if shut_down
      end
    end

    def shutdown?
      state_mutex.synchronize { @shutdown }
    end

    def wait_for_termination(timeout)
      reactor_thread&.join(timeout)
    end

    private
      attr_reader :boot_queue, :pending_executions, :reactor_thread, :state_mutex

      def name
        @name ||= "solid_queue-fiber-pool-#{object_id}"
      end

      def schedule(execution)
        start_reactor_if_needed
        pending_executions << execution
      end

      # The reactor thread is started lazily, when the first execution is posted,
      # so that the pool can be safely built before forking: in the default fork
      # supervisor mode, workers are instantiated in the supervisor process, and
      # a thread started there wouldn't survive the fork. The async gem is also
      # required lazily here, so that setups without fiber workers never load it.
      def start_reactor_if_needed
        @reactor_thread ||= begin
          require "async"
          require "async/semaphore"

          start_reactor.tap do
            boot_result = boot_queue.pop
            raise boot_result if boot_result.is_a?(Exception)
          end
        end
      end

      def start_reactor
        create_thread do
          Async do |task|
            semaphore = Async::Semaphore.new(size, parent: task)
            boot_queue << :ready

            # The reactor exits when all in-flight execution fibers, children
            # of this task, have finished
            wait_for_executions(semaphore)
          end
        rescue Exception => error
          register_fatal_error(error)
          raise
        end
      end

      def wait_for_executions(semaphore)
        # Thread::Queue#pop is fiber-scheduler-aware: it suspends this fiber, letting
        # execution fibers run, and wakes the reactor when the poller thread pushes new
        # work or closes the queue on shutdown, after which it drains any remaining
        # executions and returns nil
        while execution = pending_executions.pop
          semaphore.async(execution) do |_execution_task, scheduled_execution|
            perform_execution(scheduled_execution)
          end
        end
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

      def register_fatal_error(error)
        state_mutex.synchronize do
          @fatal_error ||= error
        end

        boot_queue << error if boot_queue.empty?
        on_idle&.call
      end

      def raise_if_fatal_error!
        error = state_mutex.synchronize { @fatal_error }
        raise error if error
      end
  end
end
