# frozen_string_literal: true

module SolidQueue::Processes
  module Poller
    extend ActiveSupport::Concern

    include Runnable

    included do
      attr_accessor :polling_interval
    end

    def metadata
      super.merge(polling_interval: polling_interval)
    end

    private
      def run
        if mode.async?
          @thread = Thread.new { start_loop }
        else
          start_loop
        end
      end

      def start_loop
        loop do
          break if shutting_down?

          wrap_in_app_executor do
            unless poll > 0
              interruptible_sleep(polling_interval)
            end
          end
        end
      ensure
        SolidQueue.instrument(:shutdown_process, process: self) do
          run_callbacks(:shutdown) { shutdown }
        end
      end

      def poll
        raise NotImplementedError
      end

      def with_polling_volume
        if SolidQueue.silence_polling?
          ActiveRecord::Base.logger.silence { yield }
        else
          yield
        end
      end
  end
end
