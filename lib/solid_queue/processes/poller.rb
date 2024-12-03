# frozen_string_literal: true

module SolidQueue::Processes
  class Poller < Base
    include Runnable

    attr_accessor :polling_interval

    def initialize(polling_interval:, **options)
      @polling_interval = polling_interval

      super(**options)
    end

    def metadata
      super.merge(polling_interval: polling_interval)
    end

    private
      def run
        start_loop
      end

      def start_loop
        loop do
          break if shutting_down?

          delay = wrap_in_app_executor do
            poll
          end

          interruptible_sleep(delay)
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
        SolidQueue.instrument(:polling) do
          if SolidQueue.silence_polling? && ActiveRecord::Base.logger
            ActiveRecord::Base.logger.silence { yield }
          else
            yield
          end
        end
      end
  end
end
