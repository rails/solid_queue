# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class << self
      def build(type:, size:, on_idle: nil)
        case type
        when :thread
          ThreadPool.new(size, on_idle: on_idle)
        when :fiber
          FiberPool.new(size, on_idle: on_idle)
        else
          raise ArgumentError, "Unknown execution pool type #{type.inspect}. Expected one of: :thread, :fiber"
        end
      end
    end
  end
end
