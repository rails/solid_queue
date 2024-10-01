# frozen_string_literal: true

module SolidQueue::Processes
  module Runnable
    include Supervised

    attr_writer :mode

    def start
      boot

      if running_async?
        @thread = create_thread { run }
      else
        run
      end
    end

    def stop
      super

      wake_up
      @thread&.join
    end

    private
      DEFAULT_MODE = :async

      def mode
        (@mode || DEFAULT_MODE).to_s.inquiry
      end

      def boot
        SolidQueue.instrument(:start_process, process: self) do
          run_callbacks(:boot) do
            if running_as_fork?
              register_signal_handlers
              set_procline
            end
          end
        end
      end

      def shutting_down?
        stopped? || (running_as_fork? && supervisor_went_away?) || finished? || !registered?
      end

      def run
        raise NotImplementedError
      end

      def finished?
        running_inline? && all_work_completed?
      end

      def all_work_completed?
        false
      end

      def shutdown
      end

      def set_procline
      end

      def running_inline?
        mode.inline?
      end

      def running_async?
        mode.async?
      end

      def running_as_fork?
        mode.fork?
      end


      def create_thread(&block)
        Thread.new do
          Thread.current.name = name
          block.call
        rescue Exception => exception
          handle_thread_error(exception)
          raise
        end
      end
  end
end
