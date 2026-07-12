# frozen_string_literal: true

require "async"
require "async/barrier"
require "async/queue"
require "async/semaphore"

module SolidQueue
  class FiberPool < Worker::ExecutionBackend
    ISOLATION_MUTEX = Mutex.new

    class Runner
      def initialize(index, fibers, name:, on_execution:)
        @queue = Async::Queue.new
        @booted = Thread::Queue.new

        @thread = Thread.new do
          Thread.current.name = "#{name}-fiber-#{index}"

          Sync do |task|
            begin
              barrier = Async::Barrier.new(parent: task)
              semaphore = Async::Semaphore.new(fibers, parent: task)
              execution_state = ActiveSupport::IsolatedExecutionState.context

              @booted << true

              while (execution = queue.dequeue)
                barrier.async(parent: semaphore) do
                  ActiveSupport::IsolatedExecutionState.share_with(execution_state)
                  on_execution.call(execution)
                end
              end

              barrier.wait
            ensure
              barrier&.cancel
            end
          end
        end

        @booted.pop
      end

      def enqueue(execution)
        queue.enqueue(execution)
      end

      def shutdown
        queue.close
      end

      def wait(timeout)
        thread.join(timeout)
      end

      private
        attr_reader :queue, :thread
    end

    attr_reader :threads, :fibers

    def initialize(threads, fibers, on_available: nil, on_idle: nil, name: "worker")
      ensure_fiber_isolation!

      @threads = threads
      @fibers = fibers

      super(threads * fibers, on_available: on_available || on_idle)

      @available_slots = Concurrent::AtomicFixnum.new(capacity)
      @next_runner = Concurrent::AtomicFixnum.new(0)
      @mutex = Mutex.new
      @shutdown = false

      @runners = Array.new(threads) do |index|
        Runner.new(index, fibers, name: name, on_execution: method(:run_execution))
      end
    end

    def post(execution)
      raise Concurrent::RejectedExecutionError, "fiber pool is shut down" if shutdown?

      available_slots.decrement
      next_runner.enqueue(execution)
    rescue Exception
      available_slots.increment if available_slots.value < capacity
      raise
    end

    def available_capacity
      available_slots.value
    end

    def shutdown
      mutex.synchronize do
        return if @shutdown

        @shutdown = true
        runners.each(&:shutdown)
      end
    end

    def shutdown?
      @shutdown
    end

    def wait_for_termination(timeout)
      deadline = Concurrent.monotonic_time + timeout.to_f

      runners.all? do |runner|
        remaining = deadline - Concurrent.monotonic_time
        break false if remaining <= 0

        runner.wait(remaining)
      end
    end

    private
      attr_reader :available_slots, :mutex, :runners

      def ensure_fiber_isolation!
        ISOLATION_MUTEX.synchronize do
          return if ActiveSupport::IsolatedExecutionState.isolation_level == :fiber

          ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
        end
      end

      def next_runner
        runners[(next_runner_index.increment - 1) % runners.size]
      end

      def next_runner_index
        @next_runner
      end

      def run_execution(execution)
        perform(execution)
      rescue Exception => error
        handle_thread_error(error)
      ensure
        available_slots.increment
        mutex.synchronize { notify_available }
      end
  end
end
