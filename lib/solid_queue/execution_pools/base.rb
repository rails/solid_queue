# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class Base
      include AppExecutor

      attr_reader :size

      def initialize(size, on_idle: nil)
        @size = size
        @on_idle = on_idle
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
        attr_reader :mutex, :on_idle

        def schedule(execution)
          raise NotImplementedError
        end

        def perform_execution(execution)
          wrap_in_app_executor { execution.perform }
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

          on_idle&.call if should_notify
        end
    end
  end
end
