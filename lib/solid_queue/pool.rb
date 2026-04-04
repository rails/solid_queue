# frozen_string_literal: true

module SolidQueue
  class Pool < Worker::ExecutionBackend
    alias size capacity

    delegate :shutdown, :shutdown?, :wait_for_termination, to: :executor

    def initialize(capacity, on_available: nil, on_idle: nil)
      super(capacity, on_available: on_available || on_idle)

      @available_threads = Concurrent::AtomicFixnum.new(capacity)
      @mutex = Mutex.new
    end

    def post(execution)
      available_threads.decrement

      Concurrent::Promises.future_on(executor, execution) do |thread_execution|
        perform(thread_execution)
      ensure
          available_threads.increment
          mutex.synchronize { notify_available }
      end.on_rejection! do |e|
        handle_thread_error(e)
      end
    end

    def available_capacity
      available_threads.value
    end

    alias idle_threads available_capacity
    alias idle? available?

    private
      attr_reader :available_threads, :mutex

      DEFAULT_OPTIONS = {
        min_threads: 0,
        idletime: 60,
        fallback_policy: :abort
      }

      def executor
        @executor ||= Concurrent::ThreadPoolExecutor.new DEFAULT_OPTIONS.merge(max_threads: capacity, max_queue: capacity)
      end
  end
end
