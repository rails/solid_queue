# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class << self
      def build(type:, size:, on_state_change: nil)
        case type
        when :thread
          ThreadPool.new(size, on_state_change: on_state_change)
        when :fiber
          FiberPool.new(size, on_state_change: on_state_change)
        else
          raise ArgumentError, "Unknown execution pool type #{type.inspect}. Expected one of: :thread, :fiber"
        end
      end
    end
  end
end
