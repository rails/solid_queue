# frozen_string_literal: true

module SolidQueue
  class Pool
    include AppExecutor

    def self.build(type:, size:, shard: nil, on_idle: nil, on_unrecoverable_error: nil)
      SolidQueue.const_get("#{type.to_s.camelize}Pool").new(
        size,
        shard: shard,
        on_idle: on_idle,
        on_unrecoverable_error: on_unrecoverable_error
      )
    end

    # The queue database shard this pool's executions are pinned to; nil
    # operates on the default shard
    attr_reader :size, :shard

    def initialize(size, shard: nil, on_idle: nil, on_unrecoverable_error: nil)
      @size = size
      @shard = shard
      @on_idle = on_idle
      @on_unrecoverable_error = on_unrecoverable_error
      @available_capacity = size
      @mutex = Mutex.new
    end

    def type
      self.class.name.demodulize.delete_suffix("Pool").underscore.to_sym
    end

    def post(execution)
      reserve_capacity!

      begin
        schedule(execution)
      rescue Exception
        restore_capacity
        raise
      end
    end

    def available_capacity
      mutex.synchronize { @available_capacity }
    end

    def idle?
      available_capacity.positive?
    end

    private
      attr_reader :mutex, :on_idle, :on_unrecoverable_error

      def schedule(execution)
        raise NotImplementedError
      end

      def perform_execution(execution)
        wrap_in_app_executor { execution.perform }
      rescue Exception => error
        handle_unrecoverable_error(error)
        handle_thread_error(error)
      ensure
        restore_capacity
      end

      def handle_unrecoverable_error(error)
        return unless error.is_a?(Processes::UnrecoverableError)

        # Only signal shutdown — do not join the worker from this pool thread,
        # or wait_for_termination during worker shutdown would deadlock.
        on_unrecoverable_error&.call
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
