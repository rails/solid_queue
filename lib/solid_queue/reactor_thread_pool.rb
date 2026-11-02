# frozen_string_literal: true

module SolidQueue
  class ReactorThreadPool < Pool
    def initialize(size, on_idle: nil, on_unrecoverable_error: nil)
      super

      @state_mutex = Mutex.new
      @shutdown = false
      @fatal_error = nil
      @pending_executions = Thread::Queue.new
      @reactor_threads = []
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
        # Each thread drains the executions already queued, then its blocked
        # pop returns nil and its reactor exits
        pending_executions.close if shut_down
      end
    end

    def shutdown?
      state_mutex.synchronize { @shutdown }
    end

    def wait_for_termination(timeout)
      deadline = Timer.monotonic_time_now + timeout.to_f
      threads = state_mutex.synchronize { reactor_threads.dup }

      threads.all? { |thread| thread.join([ deadline - Timer.monotonic_time_now, 0 ].max) }
    end

    private
      attr_reader :pending_executions, :reactor_threads, :state_mutex

      def name
        @name ||= "solid_queue-reactor-thread-pool-#{object_id}"
      end

      def schedule(execution)
        start_reactor_threads_if_needed
        pending_executions << execution
      end

      # Threads are started lazily, like the fiber pool's reactor, so the pool
      # can be built in the supervisor before it forks.
      def start_reactor_threads_if_needed
        state_mutex.synchronize do
          next if reactor_threads.any?

          require "async"
          size.times { reactor_threads << start_reactor_thread }
        end
      end

      # Each thread runs its jobs one at a time on a reactor that lives as long
      # as the thread, so async clients keep their connections across jobs
      def start_reactor_thread
        create_thread do
          Sync do
            while execution = pending_executions.pop
              perform_execution(execution)
            end
          end
        rescue Exception => error
          register_fatal_error(error)
          raise
        end
      end

      def perform_execution(execution)
        wrap_in_app_executor { execution.perform }
      rescue Async::Stop => error
        handle_thread_error(error)
        register_fatal_error(error)
      rescue Exception => error
        handle_unrecoverable_error(error)
        handle_thread_error(error)
      ensure
        restore_capacity
      end

      def register_fatal_error(error)
        state_mutex.synchronize do
          @fatal_error ||= error
        end

        on_idle&.call
      end

      def raise_if_fatal_error!
        error = state_mutex.synchronize { @fatal_error }
        raise error if error
      end
  end
end
