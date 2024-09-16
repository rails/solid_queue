# frozen_string_literal: true

require "active_support/concern"

module SolidQueue::Processes
  module Recyclable
    extend ActiveSupport::Concern

    included do
      attr_reader :max_memory, :calc_memory_usage
    end

    def recyclable_setup(**options)
      return unless configured?(options)

      set_max_memory(options[:recycle_on_oom])
      set_calc_memory_usage if max_memory
      SolidQueue.logger.error { "Recycle on OOM is disabled for worker #{pid}" } unless oom_configured?
    end

    def recycle(execution = nil)
      return false if !oom_configured? || stopped?

      memory_used = calc_memory_usage.call(pid)
      return false unless memory_exceeded?(memory_used)

      SolidQueue.instrument(:recycle_worker, process: self, memory_used: memory_used, class_name: execution&.job&.class_name) do
        pool.shutdown
        stop
      end

      true
    end

    def oom?
      oom_configured? && calc_memory_usage.call(pid) > max_memory
    end

    private

      def configured?(options)
        options.key?(:recycle_on_oom)
      end

      def oom_configured?
        @oom_configured ||= max_memory.present? && calc_memory_usage.present?
      end

      def memory_exceeded?(memory_used)
        memory_used > max_memory
      end

      def set_max_memory(max_memory)
        if max_memory > 0
          @max_memory = max_memory
        else
          SolidQueue.logger.error { "Invalid value for recycle_on_oom: #{max_memory}." }
        end
      end

      def set_calc_memory_usage
        if SolidQueue.calc_memory_usage.respond_to?(:call)
          @calc_memory_usage = SolidQueue.calc_memory_usage
        else
          SolidQueue.logger.error { "SolidQueue.calc_memory_usage provider not configured." }
        end
      end
  end
end
