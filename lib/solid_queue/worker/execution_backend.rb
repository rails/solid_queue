# frozen_string_literal: true

module SolidQueue
  class Worker < Processes::Poller
    class ExecutionBackend
      include AppExecutor

      attr_reader :capacity

      def initialize(capacity, on_available: nil)
        @capacity = capacity
        @on_available = on_available
      end

      def post(_execution)
        raise NotImplementedError
      end

      def available_capacity
        raise NotImplementedError
      end

      def available?
        available_capacity.positive?
      end

      def shutdown
        raise NotImplementedError
      end

      def shutdown?
        raise NotImplementedError
      end

      def wait_for_termination(_timeout)
        raise NotImplementedError
      end

      private
        attr_reader :on_available

        def perform(execution)
          wrap_in_app_executor do
            execution.perform
          end
        end

        def notify_available
          on_available.try(:call) if available?
        end
    end
  end
end
