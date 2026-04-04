# frozen_string_literal: true

module SolidQueue
  module ExecutionPools
    class << self
      def build(mode:, size:, on_state_change: nil)
        case normalize_mode(mode)
        when :thread
          ThreadPool.new(size, on_state_change: on_state_change)
        when :async
          AsyncPool.new(size, on_state_change: on_state_change)
        end
      end

      def normalize_mode(mode)
        case mode.to_s
        when "", "thread"
          :thread
        when "async", "fiber"
          :async
        else
          raise ArgumentError, "Unknown execution mode #{mode.inspect}. Expected one of: :thread, :async, :fiber"
        end
      end
    end
  end
end
